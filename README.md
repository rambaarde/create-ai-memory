# ai-mem

**A persistent memory layer for AI coding agents. One Markdown vault, any CLI.**

Give Claude Code, Codex, Gemini, and Cursor a shared second brain that survives
across sessions: durable profile, per-project context, and last-session
carryover, injected at launch. The vault is the source of truth; the chat is
disposable.

---

## The problem

Every AI coding session starts from zero.

Claude Code, Codex, Gemini CLI. The moment a session ends, the agent forgets what
was built, the decisions that were made, the PRD, every architectural and
codebase choice. The context that mattered most evaporates with the chat thread,
and the next run begins blind.

You pay the same tax on every run:

- **Agent amnesia.** Accumulated project knowledge vanishes when the thread closes.
- **Lost decisions.** Why a choice was made is nowhere; the next run re-litigates it.
- **Reload overhead.** You re-explain the stack, constraints, and conventions from scratch.
- **No continuity.** Nothing carries "where I left off" into the next session.

Switching agents makes it worse. Each CLI is its own island with its own memory,
or none. Knowledge earned in Claude doesn't reach Codex.

## The approach

Keep the memory outside the chat, in plain Markdown on disk, and inject it into
whichever agent you launch. Because it's just files, the vault works as an
[Obsidian](https://obsidian.md) folder with graph view, backlinks, and search;
nothing here requires Obsidian.

Memory is organized in three layers, each injected at the right scope:

| Layer | Lives in | Injected | Holds |
|---|---|---|---|
| **Global** | `_Global_Profile.md`, `_Standards.md` | every session, every project | who you are, your rules, coding standards, commit policy |
| **Project** | `_projects/<repo>.md` | sessions in that repo | purpose, architecture, constraints, active decisions |
| **Session** | `_session_logs/<repo>/<timestamp>.md` | next session as carryover | what changed, blockers, next steps |

## How it works

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

---

## Install (zsh)

```sh
git clone https://github.com/rambaarde/ai-memory.git ~/ai-memory
~/ai-memory/install.sh                 # scaffolds the vault, prints the next step
```

Add the two printed lines to `~/.zshrc`:

```zsh
export AI_MEM_ROOT="$HOME/.ai-memory/_Ai_Memory"   # or point at an Obsidian vault
source "$HOME/ai-memory/shell/ai-mem.zsh"
```

Reload, then run from inside any git repo:

```sh
exec zsh
claude-start        # or codex-start / gemini-start / cursor-start
```

The first launch scaffolds the project note and a session log for you.

> **zsh only.** The module uses `print -r`, `${(s:|:)}`, and `select`. A bash
> port is welcome as a PR; see [Roadmap](#roadmap).

## First run, step by step

1. `cd` into a git repo and run `claude-start`.
2. ai-mem resolves the project from the repo's directory name.
3. It creates `_projects/<repo>.md` from the template if it doesn't exist yet.
4. It creates a fresh session log and finds your latest prior log for carryover.
5. It asks, y/n, which optional session skills to enable (see below).
6. The agent launches with the assembled context as its opening prompt, so it
   reads your standards, the project note, and where you left off before you type.
7. When the session ends, the Stop hook stamps an auto summary into the log, so
   tomorrow's run starts where today's ended.

## Commands

| Command | What it does |
|---|---|
| `claude-start` · `codex-start` · `gemini-start` · `cursor-start` | Launch an agent with full vault context and the session-mode picker |
| `ai-start [project]` | Prepare the session (project note and fresh log) without launching an agent |
| `ai-context [project]` | Print the vault context block for the current repo, and arm the git commit guard |
| `ai-note <text>` | Append a timestamped note to today's session log while you work |

Project is auto-resolved from the current git repo; pass a name to override.

## Session skills (optional)

You define your own per-session skills; ai-mem ships none. At launch, ai-mem asks
y/n for each skill you registered, then injects the chosen instruction blocks into
the agent (and for Cursor, writes them as a managed always-apply rule). Nothing
registered means a plain session with no extra prompt.

Register skills in `~/.zshrc` before sourcing the module. Each entry is
`key` mapped to `prompt::instruction block`, and `AI_MEM_SKILL_ORDER` sets the
ask order:

```zsh
typeset -gA AI_MEM_SKILLS
AI_MEM_SKILLS[terse]='Use terse output this session?::Respond tersely; drop filler and hedging.'
AI_MEM_SKILLS[design]='Use strict UI design discipline?::Apply careful frontend/UI design review to any design work.'
AI_MEM_SKILL_ORDER=(terse design)

source "$HOME/ai-memory/shell/ai-mem.zsh"
```

The injected block applies for the whole run, so a session's chosen skills persist
as instructions across every mutation the agent makes.

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

Notes are created from templates on first use and never overwritten by the
installer. Edit `_Global_Profile.md` and `_Standards.md` to make them yours; the
shipped versions are sanitized placeholders.

## Adding a new agent

The launchers aren't hardcoded. Each agent is one small adapter, and the
`<name>-start` function is generated for you. To add `opencode`, or aider, etc.:

1. Define the adapter in `shell/adapters.zsh`. It receives `$1` memory prompt,
   `$2` mode block, and `$3` onward extra args:
   ```zsh
   _ai_adapter_opencode() {
       local memory_prompt="$1"
       opencode --prompt "$memory_prompt"
   }
   ```
2. Register it in `~/.zshrc` before sourcing, or edit the default:
   ```zsh
   export AI_MEM_AGENTS="claude codex gemini cursor opencode"
   ```
3. `opencode-start` now exists. No core edits.

## Optional integrations

### Claude Code hooks
The files live in `hooks/claude/`. Record repo `HEAD` at session start, then on exit write an auto block to the log
with the branch, commits made this session, and uncommitted changes, so the next
session has real carryover instead of an empty template. Merge
`settings.snippet.json` into `~/.claude/settings.json`, replacing `<AI_MEM_HOME>`
with an absolute path. Both hooks no-op for plain `claude` runs; they gate on
`$AI_MEM_ACTIVE_SESSION_LOG`.

### Git commit guard — `hooks/git/`
Guardrails that enforce the workflow:

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
| `AI_MEM_AGENTS` | `claude codex gemini cursor` | Space-separated agents to generate `-start` functions for |

## Design notes

- **Path-guarded writes.** Every file operation is checked to stay inside
  `$AI_MEM_ROOT`, so an agent can't write outside the memory boundary.
- **Project = git repo.** Resolution prefers the repo you're standing in, so
  `cd`-ing between projects in one shell never pins the wrong project.
- **Additive by default.** Templates fill in; notes are never clobbered.

## Roadmap

- Bash port of the shell module.
- More agent adapters shipped by default: opencode, aider.
- Optional cross-project index and search over session logs.

PRs welcome. Persistent AI memory shouldn't be a personal hack; it should be
something the whole community can install.

## License

MIT © Ram Christopher Baarde
