#!/usr/bin/env node
/**
 * create-ai-memory: set up ai-memory with no git clone.
 *
 * The tool's files are bundled inside this npm package, so this script just
 * copies them into place and hands off to the shell installer, which owns the
 * interactive setup (banner, prompts, vault scaffold, ~/.zshrc lines). No git,
 * no network beyond the npm download itself.
 *
 * Usage:
 *   npm create ai-memory@latest              # into ~/ai-memory
 *   npx create-ai-memory ~/code/ai-memory    # into a directory you choose
 */
'use strict';

const { spawnSync } = require('node:child_process');
const { cpSync, existsSync, mkdirSync } = require('node:fs');
const { join, resolve } = require('node:path');
const { homedir } = require('node:os');

const pkgRoot = resolve(__dirname, '..');                       // bundled tool
const dest = resolve(process.argv[2] || join(homedir(), 'ai-memory'));

// Files that make up the tool; copied verbatim from the package into dest.
const ITEMS = ['shell', 'hooks', 'vault-template', 'install.sh', 'ai-memory.plugin.zsh', 'LICENSE'];

console.log(`create-ai-memory: installing into ${dest}`);
mkdirSync(dest, { recursive: true });
for (const item of ITEMS) {
  const src = join(pkgRoot, item);
  if (existsSync(src)) cpSync(src, join(dest, item), { recursive: true });
}

// Hand off to the shell installer for the interactive setup.
const r = spawnSync('sh', [join(dest, 'install.sh')], { stdio: 'inherit' });
if (r.error) {
  console.error(`create-ai-memory: could not run install.sh: ${r.error.message}`);
  console.error(`Files are in ${dest}; run  sh ${join(dest, 'install.sh')}  yourself.`);
  process.exit(1);
}
process.exit(r.status ?? 0);
