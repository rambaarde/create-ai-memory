#!/usr/bin/env node
/**
 * create-ai-memory: a thin bootstrapper for ai-memory.
 *
 * It holds no install logic of its own. It clones (or updates) the ai-memory
 * repo, then hands off to the repo's `install.sh`, which owns the entire
 * interactive setup (banner, prompts, vault scaffold, ~/.zshrc lines). Keeping
 * all logic in the shell installer means the npm and clone-and-run paths can
 * never drift apart.
 *
 * Usage:
 *   npm create ai-memory@latest            # or: npx create-ai-memory
 *   npm create ai-memory@latest -- ~/code/ai-memory   # custom checkout dir
 */
'use strict';

const { spawnSync } = require('node:child_process');
const { existsSync } = require('node:fs');
const { join } = require('node:path');
const { homedir } = require('node:os');

const REPO = 'https://github.com/rambaarde/ai-memory.git';
const dest = process.argv[2] || join(homedir(), 'ai-memory');

/** Run a command inheriting stdio; exit the process if it fails. */
function run(cmd, args, opts = {}) {
  const r = spawnSync(cmd, args, { stdio: 'inherit', ...opts });
  if (r.error) {
    console.error(`create-ai-memory: failed to run ${cmd}: ${r.error.message}`);
    process.exit(1);
  }
  if (typeof r.status === 'number' && r.status !== 0) process.exit(r.status);
}

if (spawnSync('git', ['--version'], { stdio: 'ignore' }).status !== 0) {
  console.error('create-ai-memory: git is required and was not found on PATH.');
  process.exit(1);
}

if (existsSync(join(dest, '.git'))) {
  console.log(`create-ai-memory: updating existing checkout at ${dest}`);
  run('git', ['-C', dest, 'pull', '--ff-only']);
} else {
  console.log(`create-ai-memory: cloning ai-memory into ${dest}`);
  run('git', ['clone', '--depth', '1', REPO, dest]);
}

// Hand off to the shell installer, which does all the real work.
run('sh', [join(dest, 'install.sh')]);
