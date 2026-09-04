#!/usr/bin/env node
/**
 * ai-mem-serve: browse the vault as a graph in a browser.
 *
 * `ai-mem-search` answers a question you already knew to ask. This is for the
 * other case -- seeing what is in there at all, and which notes turned out to
 * be connected. The vault is an OKF bundle: markdown files with a `type` in
 * frontmatter and wikilinks between them, which is already a graph. This only
 * draws it.
 *
 * Serves three routes and nothing else:
 *   /            the viewer
 *   /api/graph   nodes and edges, built by scanning the vault
 *   /api/note    one note's raw markdown
 *
 * Binds to 127.0.0.1 only. The vault holds private project history and
 * production detail; a viewer for it has no business being reachable from the
 * network.
 *
 * Zero dependencies, like the rest of the package.
 *
 * Usage:  ai-mem-serve [port] [--no-open]
 *
 * Opens a browser at the URL by default, and is idempotent: asked twice, the
 * second call finds the first still listening and just opens the tab. The
 * usual caller is an agent acting on "open my memory", which should not have
 * to check whether it is already running, nor report a port collision as a
 * failure.
 */
'use strict';

const http = require('node:http');
const { spawn } = require('node:child_process');
const { readFileSync, readdirSync, statSync, existsSync, realpathSync } = require('node:fs');
const { join, resolve, relative, basename, extname } = require('node:path');
const { homedir } = require('node:os');

const VAULT = process.env.AI_MEM_ROOT || join(homedir(), '.ai-memory', '_Ai_Memory');
const ARGS = process.argv.slice(2);
const NO_OPEN = ARGS.includes('--no-open');
const PORT = Number(ARGS.find((a) => /^\d+$/.test(a)) || process.env.AI_MEM_PORT || 7777);
const VIEWER = join(__dirname, '..', 'web', 'viewer.html');

/** Recursively collect every .md file in the vault, skipping dotfiles and templates. */
function walk(dir, out = []) {
  let entries;
  try {
    entries = readdirSync(dir, { withFileTypes: true });
  } catch {
    return out;
  }
  for (const e of entries) {
    if (e.name.startsWith('.')) continue;
    const p = join(dir, e.name);
    if (e.isDirectory()) walk(p, out);
    else if (extname(e.name) === '.md' && !e.name.endsWith('_template.md')) out.push(p);
  }
  return out;
}

/**
 * Pull the frontmatter block into a flat object.
 *
 * Hand-rolled rather than pulled in as a dependency: the vault's frontmatter
 * is flat key/value plus the occasional inline list, which is a few lines of
 * parsing, and a YAML library would be this package's only dependency.
 */
function frontmatter(text) {
  if (!text.startsWith('---')) return {};
  const end = text.indexOf('\n---', 3);
  if (end === -1) return {};
  const out = {};
  for (const line of text.slice(4, end).split('\n')) {
    const m = line.match(/^([A-Za-z_][\w-]*):\s*(.*)$/);
    if (!m) continue;
    let v = m[2].trim().replace(/^["']|["']$/g, '');
    if (v.startsWith('[') && v.endsWith(']')) {
      v = v.slice(1, -1).split(',').map((x) => x.trim().replace(/^["']|["']$/g, '')).filter(Boolean);
    }
    out[m[1]] = v;
  }
  return out;
}

/** The note's first H1, or null. */
function h1Of(text) {
  const m = text.match(/^#\s+(.+)$/m);
  return m ? m[1].trim() : null;
}

/**
 * What to call a note on the graph.
 *
 * The obvious answer -- its first H1 -- is wrong here, because notes are
 * created from templates and inherit the template's heading. On a real vault
 * that made 354 notes read "Session Outcome" and 34 read "Project Snapshot":
 * every project and every log sharing two labels between them, which is worse
 * than no labels at all.
 *
 * So an H1 is only a title if it is *this note's* H1. One shared by several
 * notes is boilerplate by definition, and the rule needs no list of known
 * template headings to maintain -- it corrects itself for any template,
 * including ones a user writes.
 *
 * @param {string} text      the note
 * @param {string} path      its path
 * @param {object} fm        parsed frontmatter
 * @param {Map} h1Counts     how many notes share each H1
 */
function titleOf(text, path, fm, h1Counts) {
  if (fm.title) return fm.title;
  if (fm.project_name) return fm.project_name;

  const h1 = h1Of(text);
  if (h1 && h1Counts.get(h1) === 1) return h1;

  // Fall back to the filename, which is always specific. A session log's name
  // is <project>-<date>_<time>, and the project is already obvious from the
  // node it is attached to -- so show the moment, which is the part that
  // distinguishes it from its forty siblings.
  const name = basename(path, '.md');
  const stamp = name.match(/(\d{4}-\d{2}-\d{2})_(\d{2})-(\d{2})-\d{2}$/);
  return stamp ? stamp[1] + ' ' + stamp[2] + ':' + stamp[3] : name;
}

const LINK_RE = /\[\[([^\]|#]+)/g;

/**
 * Build the graph.
 *
 * Edges come from wikilinks, resolved by basename because that is how
 * Obsidian resolves them and how the vault is actually written. A link with
 * no matching note is dropped rather than drawn to a phantom -- OKF requires
 * consumers to tolerate links that do not resolve.
 */
function buildGraph() {
  const files = walk(VAULT);
  const nodes = [];
  const byBasename = new Map();

  // Read once, keep the text: the vault is a few megabytes of markdown, and
  // reading every file twice to count headings first would double the work
  // for no reason.
  const read = [];
  const h1Counts = new Map();
  for (const f of files) {
    let text;
    try {
      text = readFileSync(f, 'utf8');
    } catch {
      continue;
    }
    read.push([f, text]);
    const h = h1Of(text);
    if (h) h1Counts.set(h, (h1Counts.get(h) || 0) + 1);
  }

  for (const [f, text] of read) {
    const fm = frontmatter(text);
    const node = {
      id: relative(VAULT, f),
      title: titleOf(text, f, fm, h1Counts),
      type: fm.type || 'untyped',
      tags: Array.isArray(fm.tags) ? fm.tags : fm.tags ? [fm.tags] : [],
      description: fm.description || '',
      resource: fm.resource || '',
      mtime: (() => {
        try {
          return statSync(f).mtimeMs;
        } catch {
          return 0;
        }
      })(),
      links: [...text.matchAll(LINK_RE)].map((m) => m[1].trim()),
    };
    nodes.push(node);
    // First writer wins: a duplicate basename is ambiguous in Obsidian too.
    if (!byBasename.has(basename(f, '.md'))) byBasename.set(basename(f, '.md'), node.id);
  }

  const seen = new Set();
  const edges = [];
  for (const n of nodes) {
    // A wikilink whose basename matches no note is a dead edge. It is still not
    // drawn to a phantom node -- OKF asks consumers to tolerate links that do
    // not resolve -- but the COUNT is kept on the source node, so the graph can
    // mark which notes carry a broken link without inventing targets for them.
    const danglingSeen = new Set();
    for (const link of n.links) {
      const target = byBasename.get(link);
      if (!target) {
        if (link && link !== basename(n.id, '.md')) danglingSeen.add(link);
        continue;
      }
      if (target === n.id) continue;
      const key = n.id + ' -> ' + target;
      if (seen.has(key)) continue;
      seen.add(key);
      edges.push({ source: n.id, target });
    }
    if (danglingSeen.size) n.dangling = danglingSeen.size;
    delete n.links;
  }
  return { vault: VAULT, nodes, edges };
}

/** Resolve a note path, refusing anything that escapes the vault. */
function insideVault(p) {
  try {
    const root = realpathSync(VAULT);
    const target = realpathSync(resolve(join(VAULT, p)));
    return target === root || target.startsWith(root + '/') ? target : null;
  } catch {
    return null;
  }
}

const json = (res, code, body) => {
  res.writeHead(code, { 'content-type': 'application/json; charset=utf-8' });
  res.end(JSON.stringify(body));
};

const server = http.createServer((req, res) => {
  const url = new URL(req.url, 'http://localhost');

  if (url.pathname === '/') {
    if (!existsSync(VIEWER)) return json(res, 500, { error: 'viewer.html is missing from the package' });
    res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' });
    return res.end(readFileSync(VIEWER));
  }
  if (url.pathname === '/api/graph') return json(res, 200, buildGraph());
  if (url.pathname === '/api/note') {
    const rel = url.searchParams.get('path') || '';
    const p = insideVault(rel);
    if (!p) return json(res, 403, { error: 'path is not inside the vault' });
    if (!existsSync(p)) return json(res, 404, { error: 'not found' });
    return json(res, 200, { path: rel, text: readFileSync(p, 'utf8') });
  }
  json(res, 404, { error: 'not found' });
});

if (!existsSync(VAULT)) {
  console.error('ai-mem-serve: no vault at ' + VAULT + '. Set AI_MEM_ROOT.');
  process.exit(1);
}

/**
 * Hand the URL to the desktop. Failure is ignored on purpose: a headless box
 * or a locked-down desktop has no opener, and that is not a reason for the
 * server itself to fail -- the URL is printed either way.
 */
function openBrowser(url) {
  if (NO_OPEN) return;
  const cmd = process.platform === 'darwin' ? 'open' : process.platform === 'win32' ? 'start' : 'xdg-open';
  try {
    spawn(cmd, [url], { stdio: 'ignore', detached: true, shell: process.platform === 'win32' }).unref();
  } catch {
    /* no opener; the printed URL is the fallback */
  }
}

// Loopback only, deliberately. See the header note.
server.listen(PORT, '127.0.0.1', () => {
  const g = buildGraph();
  const url = 'http://127.0.0.1:' + server.address().port;
  console.log('ai-mem-serve: ' + g.nodes.length + ' notes, ' + g.edges.length + ' links');
  console.log('  ' + url);
  openBrowser(url);
});

/**
 * A port already in use is the expected case, not an error: it almost always
 * means a previous "open my memory" is still serving. Confirm it is this
 * server rather than something unrelated, then open the tab and exit clean.
 * Reporting EADDRINUSE would make an agent believe the request failed.
 */
server.on('error', (err) => {
  if (err.code !== 'EADDRINUSE') {
    console.error('ai-mem-serve: ' + err.message);
    process.exit(1);
  }
  const url = 'http://127.0.0.1:' + PORT;
  http.get(url + '/api/graph', (res) => {
    if (res.statusCode !== 200) return bail('something else');
    let body = '';
    res.setEncoding('utf8');
    res.on('data', (c) => { body += c; });
    res.on('end', () => {
      // Being an ai-mem-serve is not enough -- it has to be serving THIS
      // vault. A leftover server from a test run or another vault answers
      // /api/graph perfectly well, and attaching to it silently shows the
      // wrong notes while reporting success. That is the failure this whole
      // tool exists to avoid, so compare the vault it names.
      let serving;
      try {
        serving = JSON.parse(body).vault;
      } catch {
        return bail('something else');
      }
      if (serving !== VAULT) {
        console.error('ai-mem-serve: port ' + PORT + ' is already serving a different vault:');
        console.error('  running: ' + serving);
        console.error('  wanted:  ' + VAULT);
        console.error('Stop that server, or pass another port: ai-mem-serve ' + (PORT + 1));
        process.exit(1);
      }
      console.log('ai-mem-serve: already running');
      console.log('  ' + url);
      openBrowser(url);
      process.exit(0);
    });
  }).on('error', () => bail('something else'));

  function bail(what) {
    console.error('ai-mem-serve: port ' + PORT + ' is in use by ' + what + '. Pass a different port.');
    process.exit(1);
  }
});
