<div align="center">

# ai-memory

**Persistent, agent-agnostic session memory for AI coding CLIs. One Markdown vault, any agent.**

Give Claude Code, Codex, Gemini, Cursor, and opencode a shared second brain that
survives across sessions: durable profile, per-project context, and last-session carryover,
injected at launch. The vault is the source of truth; the chat is disposable.

No daemon, no database, no API key. Just zsh and Markdown files you can read.

![zsh](https://img.shields.io/badge/shell-zsh-89e051)
![tests](https://img.shields.io/badge/tests-35%20passing-brightgreen)
![license](https://img.shields.io/badge/license-MIT-blue)
![PRs](https://img.shields.io/badge/PRs-welcome-orange)

</div>

---

## The problem

Every AI coding session starts from zero.

Claude Code, Codex, Gemini CLI. The moment a session ends, the agent forgets what
was built, the decisions that were made, the PRD, every architectural and codebase
choice. The context that mattered most evaporates with the chat thread, and the
next run begins blind.

You pay the same tax on every run:

- **Agent amnesia.** Accumulated project knowledge vanishes when the thread closes.
- **Lost decisions.** Why a choice was made is nowhere; the next run re-litigates it.
- **Reload overhead.** You re-explain the stack, constraints, and conventions from scratch.
- **No continuity.** Nothing carries "where I left off" into the next session.

Switching agents makes it worse. Each CLI is its own island with its own memory,
or none. Knowledge earned in Claude doesn't reach Codex.

## How it works

Keep the memory outside the chat, in plain Markdown on disk, and inject it into
whichever agent you launch. Because it's just files, the vault doubles as an
[Obsidian](https://obsidian.md) folder with graph view, backlinks, and search;
nothing here requires Obsidian.

Memory sits in three layers, each injected at the right scope:

| Layer | Lives in | Injected | Holds |
|---|---|---|---|
| **Global** | `_Global_Profile.md`, `_Standards.md` | every session, every project | who you are, your rules, coding standards, commit policy |
| **Project** | `_projects/<repo>.md` | sessions in that repo | purpose, architecture, constraints, active decisions |
| **Session** | `_session_logs/<repo>/<timestamp>.md` | next session as carryover | what changed, blockers, next steps |

```
  $ claude-start
        │
        ├─ resolve project from the current git repo
        ├─ create a fresh session log from the template
        ├─ gather:  Global Profile + Standards         (who you are)
        │           Project note                        (this repo)
        │           latest prior session log            (where you left off)
        ├─ ask which session skills to enable           (optional)
        └─ launch the agent with all of it as the first prompt
              │
              ▼
        …you work…
              │
              ▼
        on exit, a hook writes an auto session log
        (branch, commits made, uncommitted changes)
        → the NEXT session inherits it as carryover
```

One environment variable, `AI_MEM_ROOT`, points at the vault, so the system moves
between machines by pointing at the same folder.

## A session, start to finish

```console
$ cd ~/code/checkout-api
$ claude-start
  Use terse output this session? [y/N] n

  # Claude launches pre-loaded with:
  #   • your profile + coding standards + commit policy   (global)
  #   • checkout-api: purpose, architecture, decisions    (project)
  #   • "Next: wire the refund webhook"                   (last session's carryover)

… you build the refund webhook, make a few commits …

$ ai-note "refund webhook live; still need idempotency keys"   # jot mid-session

# On exit, a hook stamps the session log with the branch, the commits you made,
# and anything uncommitted. Tomorrow's claude-start picks up exactly there.
```

No copy-pasting context. No re-explaining the stack. No "where were we."

## Quickstart

```sh
npm create ai-memory@latest     # copies the tool in and runs the setup, no git clone
exec zsh
```

Then, from inside any git repo:

```sh
claude-start                    # or codex-start / gemini-start / cursor-start / opencode-start
```

The agent opens already knowing your standards, this project, and where you left
off last time.

## Table of contents

<table>
<tr>
<td valign="top" width="33%">

**Overview**

- [The problem](#the-problem)
- [How it works](#how-it-works)
- [A session, start to finish](#a-session-start-to-finish)

**Getting started**

- [Quickstart](#quickstart)
- [Install](#install)
- [Commands](#commands)

</td>
<td valign="top" width="33%">

**Reference**

- [Session skills](#session-skills-optional)
- [Vault layout](#vault-layout)
- [Adding a new agent](#adding-a-new-agent)
- [Optional integrations](#optional-integrations)
- [Configuration](#configuration)

</td>
<td valign="top" width="33%">

**Project**

- [Tests](#tests)
- [Design notes](#design-notes)
- [Roadmap](#roadmap)
- [License](#license)

</td>
</tr>
</table>

## Install

Pick whichever fits how you manage your shell. All paths end at the same place.

**npm** (no git clone; the tool is bundled in the package):

```sh
npm create ai-memory@latest         # into ~/ai-memory, then runs the setup
npx create-ai-memory ~/code/ai-memory   # or a directory you choose
```

**zsh plugin manager:**

```zsh
# zinit
zinit light rambaarde/create-ai-memory

# antidote (in your plugins file)
rambaarde/create-ai-memory

# oh-my-zsh: clone into custom/plugins, then add create-ai-memory to plugins=(...)
```

Plugin-manager installs only source the module. That's fine: the vault
auto-scaffolds from the shipped templates on first use, so `install.sh` is
optional. Set `AI_MEM_ROOT` in `~/.zshrc` first if you don't want the default
`~/.ai-memory/_Ai_Memory`.

**Clone and run** (the source of truth all paths reuse):

```sh
git clone https://github.com/rambaarde/create-ai-memory.git ~/ai-memory
~/ai-memory/install.sh
```

> **zsh only.** The module uses `print -r`, `${(s:|:)}`, and `select`. A bash
> port is welcome as a PR; see [Roadmap](#roadmap).

## Commands

| Command | What it does |
|---|---|
| `claude-start` · `codex-start` · `gemini-start` · `cursor-start` · `opencode-start` | Launch an agent with full vault context and the session-skill picker |
| `ai-start [project]` | Prepare the session (project note and fresh log) without launching an agent |
| `ai-context [project]` | Print the vault context block for the current repo, and arm the git commit guard |
| `ai-note <text>` | Append a timestamped note to today's session log while you work |

Project is auto-resolved from the current git repo; pass a name to override.

## Session skills (optional)

You define your own per-session skills; ai-memory ships none. At launch it asks
y/n for each skill you registered, then injects the chosen instruction blocks into
the agent (and for Cursor, writes them as a managed always-apply rule). Register
nothing and every session is plain.

Add skills in `~/.zshrc` before sourcing the module. Each entry maps a `key` to
`prompt::instruction block`, and `AI_MEM_SKILL_ORDER` sets the ask order:

```zsh
typeset -gA AI_MEM_SKILLS
AI_MEM_SKILLS[terse]='Use terse output this session?::Respond tersely; drop filler and hedging.'
AI_MEM_SKILLS[design]='Use strict UI design discipline?::Apply careful frontend/UI design review to any design work.'
AI_MEM_SKILL_ORDER=(terse design)

source "$HOME/ai-memory/shell/ai-mem.zsh"
```

The injected block applies for the whole run, so a session's chosen skills persist
as instructions across every change the agent makes.

## Vault layout

```
$AI_MEM_ROOT/
  _Global_Profile.md          your cross-project rules      (injected every session)
  _Standards.md               extra shared standards        (injected every session)
  _projects/
    _project_template.md       scaffold for new project notes
    <repo>.md                  per-project durable context
  _session_logs/
    _session_template.md       scaffold for new session logs
    <repo>/
      <repo>-<timestamp>.md    one file per session
```

Notes are created from templates on first use and never overwritten. Edit
`_Global_Profile.md` and `_Standards.md` to make them yours; the shipped versions
are sanitized placeholders.

## Adding a new agent

Launchers aren't hardcoded. Each agent is one small adapter, and the
`<name>-start` function is generated for you. `claude`, `codex`, `gemini`,
`cursor`, and `opencode` ship built in. To add another, say `aider`:

1. Define the adapter in `shell/adapters.zsh`. It receives `$1` memory prompt,
   `$2` mode block, and `$3` onward extra args:
   ```zsh
   _ai_adapter_aider() {
       local memory_prompt="$1"
       aider --message "$memory_prompt"
   }
   ```
2. Register it in `~/.zshrc` before sourcing, or edit the default:
   ```zsh
   export AI_MEM_AGENTS="claude codex gemini cursor opencode aider"
   ```
3. `aider-start` now exists. No core edits.

## Optional integrations

### Claude Code hooks
The files live in `hooks/claude/`. Record repo `HEAD` at session start, then on
exit write an auto block to the log with the branch, commits made this session, and
uncommitted changes, so the next session has real carryover instead of an empty
template. Merge `settings.snippet.json` into `~/.claude/settings.json`, replacing
`<AI_MEM_HOME>` with an absolute path. Both hooks no-op for plain `claude` runs;
they gate on `$AI_MEM_ACTIVE_SESSION_LOG`.

### Git commit guard
The files live in `hooks/git/`:

- **`commit-msg`** requires Conventional Commits and a structured body, and that
  `ai-context` was loaded in the committing shell, matching a per-repo token. An
  agent can't commit without the vault context loaded.
- **`pre-push`** blocks direct pushes to `main` unless `ALLOW_PUSH_TO_MAIN=1`.

Enable per repo:

```sh
cp ~/ai-memory/hooks/git/* <repo>/.githooks/
git -C <repo> config core.hooksPath .githooks
```

## Configuration

| Env var | Default | Purpose |
|---|---|---|
| `AI_MEM_ROOT` | `$HOME/.ai-memory/_Ai_Memory` | Vault root. Point at any folder, including an existing Obsidian vault |
| `AI_MEM_AGENTS` | `claude codex gemini cursor opencode` | Space-separated agents to generate `-start` functions for |
| `AI_MEM_SKILLS` / `AI_MEM_SKILL_ORDER` | empty | Your per-session skills (see above) |

## Tests

Offline unit suite (throwaway vault + git repo, no network): path guarding,
project resolution, session prep, context prompt, skill picker, launcher
generation, adapter dispatch, the commit token, and `ai-note`.

```sh
zsh tests/run.sh     # offline unit tests
zsh tests/smoke.sh   # live: launches each agent headlessly, checks it responds
```

`smoke.sh` makes real API calls, so each CLI must be installed and authed
(opencode defaults to DeepSeek; set it up or pass
`AIMEM_SMOKE_OPENCODE_MODEL=provider/model`).

## Design notes

- **The vault is the source of truth; the chat is disposable.** Durable state lives
  in Markdown, not in any agent's memory.
- **Path-guarded writes.** Every file operation is checked to stay inside
  `$AI_MEM_ROOT`, so an agent can't write outside the memory boundary.
- **Project = git repo.** Resolution prefers the repo you're standing in, so
  `cd`-ing between projects in one shell never pins the wrong project.
- **Additive by default.** Templates fill in; notes are never clobbered.

## Roadmap

- Bash port of the shell module.
- Publish `create-ai-memory` to npm.
- More agent adapters shipped by default: opencode, aider.
- Optional cross-project index and search over session logs.

PRs welcome. Persistent AI memory shouldn't be a personal hack; it should be
something the whole community can install.

## License

MIT © Ram Christopher Baarde
