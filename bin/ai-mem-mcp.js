#!/usr/bin/env node
/**
 * ai-mem-mcp: expose the vault to agents that have no shell.
 *
 * The `*-start` launchers reach an agent by injecting the vault context into
 * its opening prompt. A GUI opened from the Dock never runs one, so Claude
 * Desktop and the Cursor GUI see nothing -- there is no daemon, and the link
 * is the prompt rather than a service.
 *
 * MCP is the only channel those clients have. This deliberately does NOT
 * apply to anything with Bash: an agent with a shell should call
 * `ai-mem-search` directly rather than through a wrapper that can only get
 * out of date.
 *
 * Every tool shells out to the same zsh functions the CLI uses, so the search
 * and context rules have exactly one implementation. Re-implementing them
 * here in JavaScript would create a second copy to drift.
 *
 * Speaks JSON-RPC 2.0 over stdio, newline-delimited, with no dependencies --
 * the package ships zero and CI refuses to publish if one appears.
 *
 * Register it with a client, e.g. Claude Desktop's config:
 *   { "mcpServers": { "ai-memory": { "command": "ai-mem-mcp" } } }
 */
'use strict';

const { spawnSync, spawn } = require('node:child_process');
const { realpathSync, existsSync, readFileSync } = require('node:fs');
const { join, resolve } = require('node:path');
const { homedir } = require('node:os');
const readline = require('node:readline');

const MODULE = join(__dirname, '..', 'shell', 'ai-mem.zsh');
const VAULT = process.env.AI_MEM_ROOT || join(homedir(), '.ai-memory', '_Ai_Memory');
const VERSION = (() => {
  try {
    return JSON.parse(readFileSync(join(__dirname, '..', 'package.json'), 'utf8')).version;
  } catch {
    return '0.0.0';
  }
})();

/**
 * Run a zsh snippet with the module sourced, and return its output.
 *
 * stderr is kept separate and only surfaced when the call fails: sourcing the
 * module prints nothing on success, but a broken vault path should reach the
 * client as an error rather than be silently mixed into a result.
 *
 * @param {string} snippet zsh to run after the module is sourced
 * @returns {{ok: boolean, text: string}}
 */
function zsh(snippet) {
  const r = spawnSync('zsh', ['-c', `source ${JSON.stringify(MODULE)} >/dev/null 2>&1\n${snippet}`], {
    encoding: 'utf8',
    env: { ...process.env, AI_MEM_ROOT: VAULT },
    maxBuffer: 8 * 1024 * 1024,
  });
  if (r.error) return { ok: false, text: `failed to run zsh: ${r.error.message}` };
  const out = (r.stdout || '').trim();
  // ai-mem-search exits non-zero for "no matches", which is a real answer and
  // not an error -- the client needs to see it, so only treat an empty result
  // as a failure.
  if (out) return { ok: true, text: out };
  return { ok: false, text: (r.stderr || '').trim() || 'no output' };
}

/** Shell-quote a value for safe interpolation into the zsh snippet. */
const q = (s) => `'${String(s).replace(/'/g, `'\\''`)}'`;

/**
 * Resolve a note path and refuse anything outside the vault.
 *
 * Compares resolved real paths with a separator-terminated prefix, not a
 * string prefix: a plain `startsWith` would accept both `<vault>/../etc` and a
 * sibling directory whose name merely begins with the vault's.
 *
 * @param {string} p caller-supplied path, absolute or vault-relative
 * @returns {string|null} the real path, or null if it escapes the vault
 */
function insideVault(p) {
  try {
    const root = realpathSync(VAULT);
    const target = realpathSync(resolve(p.startsWith('/') ? p : join(VAULT, p)));
    return target === root || target.startsWith(root + '/') ? target : null;
  } catch {
    return null;
  }
}

/**
 * Ambient guidance, returned from `initialize` and surfaced by the client
 * before the first turn.
 *
 * This is what makes a GUI behave like a launcher. In a terminal the vault is
 * pushed into the agent's opening prompt; over MCP nothing is pushed, and a
 * model with no reason to suspect a memory exists will simply never call a
 * tool. Saying so once, up front, is the whole difference.
 *
 * Kept deliberately short and free of bulk. The obvious move is to inline the
 * profile, standards and lesson list here so a GUI gets everything the
 * launcher injects -- but instructions are paid on every connection whether
 * used or not, and clients are free to truncate or ignore the field. A cheap
 * nudge plus one get_context call is both smaller and more robust than a
 * large block that may be silently dropped.
 */
const INSTRUCTIONS = [
  "This is the user's persistent memory across every AI tool they use: past sessions, project decisions, and lessons learned the hard way.",
  '',
  'Before answering anything about their work, call get_context. It returns their profile, standards, the current project note, and what the last session concluded.',
  'Before solving a problem, call search_memory -- they may have solved it already, and repeating a solved mistake is the failure this vault exists to prevent. Search broadly first; too specific a first query is the usual way to miss something.',
  'When you hit a blocker -- an error you do not understand, an unclear failure, or a second failed attempt at the same thing -- search again before guessing. Lessons rank above session logs, so a hit under _lessons/ is the recorded fix.',
  'Search ONE distinctive word, not a sentence. Matching is literal substring: a whole error line finds nothing, and a bare tool name returns hundreds of irrelevant lines. Pick the most unusual word in the symptom and try two or three separately.',
  '',
  'Write back. A session that only reads leaves nothing behind, and the next one starts cold:',
  '- add_note for what happened, decided, or broke during this session.',
  '- add_lesson for something worth recalling in a DIFFERENT project later. Not project trivia -- the transferable part.',
  '',
  'If they ask to see, open or browse their memory rather than search it, call open_graph.',
].join('\n');

// Descriptions stay terse on purpose. Every schema below is re-sent on each
// turn, so prose here is a recurring cost: measured at ~380 tokens for four
// verbosely-described tools. Behavior guidance belongs in INSTRUCTIONS, said
// once, rather than restated inside each tool.
const TOOLS = [
  {
    name: 'search_memory',
    description: 'Search all past sessions, project notes and lessons. Literal, case-insensitive, newest first.',
    inputSchema: {
      type: 'object',
      properties: {
        term: { type: 'string', description: 'Text to find. Not a regex.' },
        project: { type: 'string', description: 'Optional: one project only.' },
      },
      required: ['term'],
    },
  },
  {
    name: 'get_context',
    description: 'The user\'s profile, standards, current project note, last session digest, and known lesson topics.',
    inputSchema: {
      type: 'object',
      properties: { project: { type: 'string', description: 'Defaults to the active project.' } },
    },
  },
  {
    name: 'read_note',
    description: 'Read one vault note by path.',
    inputSchema: {
      type: 'object',
      properties: { path: { type: 'string', description: 'Absolute, or relative to the vault root.' } },
      required: ['path'],
    },
  },
  {
    name: 'add_note',
    description: 'Append a timestamped note to today\'s session log. Use for what happened or was decided.',
    inputSchema: {
      type: 'object',
      properties: { text: { type: 'string', description: 'What to record.' } },
      required: ['text'],
    },
  },
  {
    name: 'open_graph',
    description: 'Open the vault as a browsable graph in the user\'s browser. Use when they ask to see, open or browse their memory.',
    inputSchema: { type: 'object', properties: {} },
  },
  {
    name: 'add_lesson',
    description: 'Record a problem and its solution as a cross-project lesson. Use only for something that will matter in a different project.',
    inputSchema: {
      type: 'object',
      properties: {
        topic: { type: 'string', description: 'Short slug, e.g. rate-limiting.' },
        problem: { type: 'string', description: 'What went wrong.' },
        solution: { type: 'string', description: 'What fixed it.' },
      },
      required: ['topic', 'problem', 'solution'],
    },
  },
];

/** Dispatch a tool call to the zsh function that owns its behavior. */
function callTool(name, args = {}) {
  switch (name) {
    case 'search_memory':
      return zsh(`ai-mem-search ${q(args.term)} ${args.project ? q(args.project) : ''}`);
    case 'get_context':
      return zsh(`ai-context ${args.project ? q(args.project) : ''}`);
    // ai-note and ai-lesson both push the vault themselves, so a GUI write is
    // committed and backed up exactly like a terminal one -- no separate step
    // for the model to forget.
    case 'add_note':
      if (!args.text) return { ok: false, text: 'text is required' };
      return zsh(`ai-note ${q(args.text)}`);
    case 'add_lesson':
      if (!args.topic || !args.problem || !args.solution) {
        return { ok: false, text: 'topic, problem and solution are all required' };
      }
      return zsh(`ai-lesson ${q(args.topic)} ${q(args.problem)} ${q(args.solution)}`);
    // Detached and unref'd: the viewer has to outlive this call, and an MCP
    // tool that blocks until a server exits would hang the client forever.
    case 'open_graph': {
      const bin = join(__dirname, 'ai-mem-serve.js');
      const port = process.env.AI_MEM_PORT || '7777';
      try {
        spawn(process.execPath, [bin, port], {
          stdio: 'ignore', detached: true, env: { ...process.env, AI_MEM_ROOT: VAULT },
        }).unref();
      } catch (e) {
        return { ok: false, text: 'could not start the viewer: ' + e.message };
      }
      return { ok: true, text: 'Opened the memory graph at http://127.0.0.1:' + port + ' (a browser tab should be opening).' };
    }
    case 'read_note': {
      const p = insideVault(args.path || '');
      if (!p) return { ok: false, text: `refused: ${args.path} is not inside the vault` };
      if (!existsSync(p)) return { ok: false, text: `not found: ${args.path}` };
      return { ok: true, text: readFileSync(p, 'utf8') };
    }
    default:
      return { ok: false, text: `unknown tool: ${name}` };
  }
}

/** Write one JSON-RPC message. stdout carries protocol only; logs go to stderr. */
const send = (msg) => process.stdout.write(JSON.stringify(msg) + '\n');

function handle(req) {
  const { id, method, params } = req;
  // Notifications have no id and must never be answered.
  if (id === undefined) return;

  if (method === 'initialize') {
    return send({
      jsonrpc: '2.0',
      id,
      result: {
        // Echo the client's protocol version when it sends one: a server that
        // hardcodes its own is rejected outright by clients on a different one.
        protocolVersion: params?.protocolVersion || '2025-06-18',
        capabilities: { tools: {} },
        serverInfo: { name: 'ai-memory', version: VERSION },
        instructions: INSTRUCTIONS,
      },
    });
  }
  if (method === 'tools/list') return send({ jsonrpc: '2.0', id, result: { tools: TOOLS } });
  if (method === 'tools/call') {
    const { ok, text } = callTool(params?.name, params?.arguments || {});
    // A failed tool call is reported as tool content with isError, not as a
    // JSON-RPC error: the model should see "no matches" and adapt, rather than
    // the client treating a normal empty result as a transport fault.
    return send({ jsonrpc: '2.0', id, result: { content: [{ type: 'text', text }], isError: !ok } });
  }
  send({ jsonrpc: '2.0', id, error: { code: -32601, message: `method not found: ${method}` } });
}

readline.createInterface({ input: process.stdin }).on('line', (line) => {
  if (!line.trim()) return;
  let req;
  try {
    req = JSON.parse(line);
  } catch {
    return send({ jsonrpc: '2.0', id: null, error: { code: -32700, message: 'parse error' } });
  }
  try {
    handle(req);
  } catch (e) {
    if (req.id !== undefined) {
      send({ jsonrpc: '2.0', id: req.id, error: { code: -32603, message: String(e && e.message) } });
    }
  }
});
