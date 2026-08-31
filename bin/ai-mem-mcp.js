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

const { spawnSync } = require('node:child_process');
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

const TOOLS = [
  {
    name: 'search_memory',
    description:
      'Full-text search across the AI memory vault: past sessions, project notes, and cross-project lessons. ' +
      'Case-insensitive, matches literally, newest result first, output capped. ' +
      'Start broad and narrow down -- too specific a first query is the usual way to miss something.',
    inputSchema: {
      type: 'object',
      properties: {
        term: { type: 'string', description: 'Text to find. Matched literally, not as a regex.' },
        project: { type: 'string', description: 'Optional: restrict to one project\'s session logs.' },
      },
      required: ['term'],
    },
  },
  {
    name: 'get_context',
    description:
      'The vault context block for a project: global profile, standards, project note path, ' +
      'a digest of the previous session, and the list of recorded lesson topics. ' +
      'This is what the shell launchers inject at startup. Read it before acting.',
    inputSchema: {
      type: 'object',
      properties: {
        project: { type: 'string', description: 'Project name. Defaults to the vault\'s active project.' },
      },
    },
  },
  {
    name: 'read_note',
    description: 'Read one note from the vault by path. Paths outside the vault are refused.',
    inputSchema: {
      type: 'object',
      properties: { path: { type: 'string', description: 'Absolute path, or one relative to the vault root.' } },
      required: ['path'],
    },
  },
  {
    name: 'list_lessons',
    description:
      'List every recorded cross-project lesson by topic slug, newest first. Names only, no bodies -- ' +
      'read one with read_note or search_memory. Use this to find out what is already known.',
    inputSchema: { type: 'object', properties: {} },
  },
];

/** Dispatch a tool call to the zsh function that owns its behavior. */
function callTool(name, args = {}) {
  switch (name) {
    case 'search_memory':
      return zsh(`ai-mem-search ${q(args.term)} ${args.project ? q(args.project) : ''}`);
    case 'get_context':
      return zsh(`ai-context ${args.project ? q(args.project) : ''}`);
    case 'list_lessons':
      return zsh('__ai_mem_lesson_index');
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
