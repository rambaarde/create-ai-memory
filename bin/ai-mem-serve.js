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
 * Usage:  ai-mem-serve [port]
 */
'use strict';

const http = require('node:http');
const { readFileSync, readdirSync, statSync, existsSync, realpathSync } = require('node:fs');
const { join, resolve, relative, basename, extname } = require('node:path');
const { homedir } = require('node:os');

const VAULT = process.env.AI_MEM_ROOT || join(homedir(), '.ai-memory', '_Ai_Memory');
const PORT = Number(process.argv[2] || process.env.AI_MEM_PORT || 7777);
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

/** First H1, else the filename -- what a human would call this note. */
function titleOf(text, path) {
  const h1 = text.match(/^#\s+(.+)$/m);
  return (h1 && h1[1].trim()) || basename(path, '.md');
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

  for (const f of files) {
    let text;
    try {
      text = readFileSync(f, 'utf8');
    } catch {
      continue;
    }
    const fm = frontmatter(text);
    const node = {
      id: relative(VAULT, f),
      title: fm.title || titleOf(text, f),
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
    for (const link of n.links) {
      const target = byBasename.get(link);
      if (!target || target === n.id) continue;
      const key = n.id + ' -> ' + target;
      if (seen.has(key)) continue;
      seen.add(key);
      edges.push({ source: n.id, target });
    }
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

// Loopback only, deliberately. See the header note.
server.listen(PORT, '127.0.0.1', () => {
  const g = buildGraph();
  console.log('ai-mem-serve: ' + g.nodes.length + ' notes, ' + g.edges.length + ' links');
  console.log('  http://127.0.0.1:' + server.address().port);
});
