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
 *   npx create-ai-memory --version | --help
 */
'use strict';

const { spawnSync } = require('node:child_process');
const { cpSync, existsSync, mkdirSync } = require('node:fs');
const { join, resolve } = require('node:path');
const { homedir } = require('node:os');

const pkgRoot = resolve(__dirname, '..');                       // bundled tool
const USAGE = 'Usage: create-ai-memory [install-dir]   (default: ~/ai-memory)\n' +
              '       create-ai-memory --version | --help';

// Flags are handled before anything touches the disk. The first argument used
// to be taken as the install directory unconditionally, so `--version` created
// ./--version and ran the interactive installer inside it. Any other leading
// dash is rejected rather than guessed at: a directory name starting with `-`
// can still be passed as ./-name.
const arg = process.argv[2];
if (arg === '--version' || arg === '-v') {
  console.log(require(join(pkgRoot, 'package.json')).version);
  process.exit(0);
}
if (arg === '--help' || arg === '-h') {
  console.log(USAGE);
  process.exit(0);
}
if (arg && arg.startsWith('-')) {
  console.error(`create-ai-memory: unknown option ${arg}\n${USAGE}`);
  process.exit(2);
}

const dest = resolve(arg || join(homedir(), 'ai-memory'));

// Files that make up the tool; copied verbatim from the package into dest.
//
// `bin` and `web` are as load-bearing as `shell`: ai-mem-serve is the graph
// viewer and ai-mem-mcp is how GUI clients reach the vault at all. Both were
// added to package.json's `files` when they were written, so they shipped in
// the tarball -- and stopped there, because this list was never updated. A
// user who installed the documented way got neither, while the README told
// them to run both.
//
// package.json comes along because ai-mem-mcp reports its own version from it;
// without it the server introduced itself to every client as 0.0.0.
const ITEMS = ['shell', 'bin', 'web', 'hooks', 'vault-template', 'install.sh', 'create-ai-memory.plugin.zsh', 'package.json', 'LICENSE'];

console.log(`create-ai-memory: installing into ${dest}`);
mkdirSync(dest, { recursive: true });
for (const item of ITEMS) {
  const src = join(pkgRoot, item);
  if (existsSync(src)) cpSync(src, join(dest, item), { recursive: true });
}

// Hand off to the shell installer for the interactive setup. Run it with bash,
// not sh: install.sh is a bash script (arrays, printf -v, ${!var}) and would
// fail under a POSIX sh such as dash, which is /bin/sh on Debian and Ubuntu.
const installer = join(dest, 'install.sh');
const r = spawnSync('bash', [installer], { stdio: 'inherit' });
if (r.error) {
  console.error(`create-ai-memory: could not run the installer with bash: ${r.error.message}`);
  console.error(`Files are in ${dest}; run  bash ${installer}  yourself.`);
  process.exit(1);
}
process.exit(r.status ?? 0);
