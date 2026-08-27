# PRD: inline session digest (replace path-pointer for the previous log)

- Status: implemented (see "Second correction" — the shipped design differs from the first draft below it)
- Target version: `0.2.0` (feat, minor bump — repo has no release-please config, so the PR title carries the `vX.Y.Z` prefix per policy)
- Scope: v1 only (see Out of scope). Fast-follows are listed but not built here.

## Second correction — what actually shipped

The design below (sections 1–4) originally called for a new machine-managed file, `_session_logs/<project>/.digest.md`, written by `session-summary.sh` on every Stop. That was rejected: **no new files in the vault, period** — only the structure that already exists.

**What shipped instead:** `_ai_mem_context_prompt()` extracts the four `# Session Outcome` bullets directly from the previous session log **at read time**, on every launch, instead of pre-generating and persisting them. No write-side change at all — `hooks/claude/session-summary.sh` is untouched, back to its original form.

This is simpler than the file-based version, not just more restrictive: no idempotent-rewrite logic to maintain, no "is the digest stale relative to the log" question, no second file to keep in sync. Extraction is a couple of `grep`/`sed` calls against a small file — cheap enough to redo on every launch rather than caching the result anywhere.

One real bug surfaced by building it this way: a brand-new, never-edited session log already matches the bullet regex — its bracket placeholders (`[What changed or was decided]`, etc.) would otherwise get inlined as if they were real content. `_ai_mem_session_field()` filters out any value that's entirely wrapped in `[...]` before returning it, so an untouched template correctly falls back to the old path-pointer behavior instead of surfacing placeholder text.

Everything below — the problem statement, goals, fallback chain, escape hatch — still describes the shipped behavior accurately. Only "1. Digest file" and "2. Write path" in the Proposed design section describe something that was built, then reverted; kept here for the record rather than deleted.

## First correction

An earlier draft of this PRD assumed `ai-mem.zsh` inlines the full text of the latest session log into `memory_prompt` on every launch, and framed this as a token-cost problem. That's wrong — read the actual source before writing this version. See "Current behavior" below for what really happens.

## Problem

`_ai_mem_context_prompt()` (`shell/ai-mem.zsh:185`) already keeps `memory_prompt` lean: it inlines full text only for `_Global_Profile.md` and `_Standards.md`. The previous session log is passed as a **path**, with an instruction: *"Latest prior session log: `<path>` ... Read the latest prior session log for continuity before acting. Do not load the full session history unless the user asks for it."*

This is correct in spirit (small prompt, on-demand deep read) but has a real gap: nothing guarantees the agent actually calls `Read()` on that path. It's an instruction sitting in a wall of text, not a forced action. If the model doesn't act on it, "continuity" silently doesn't happen — which matches the "sometimes it forgets" complaint that motivated this: not a cost problem, a **compliance** problem. A path the agent might read is weaker than content the agent has already seen.

## Goals

- Guarantee the agent has actually seen "what happened last session" — inline it, don't ask the agent to go fetch it.
- Zero new infrastructure: no database, no embedded index (SQLite included), no server process, **and no new files in the vault at all** — extraction reads only structure that already exists. Confirmed hard constraint — evaluated and rejected Letta/Zep (need standing infra) and claude-mem (still SQLite, still a DB).
- Stay adapter-agnostic: the fix lives in `ai-mem.zsh`, upstream of `adapters.zsh`'s fan-out, so claude/codex/gemini/cursor/opencode all get it identically.
- Ship as an additive change: existing installs must keep working with zero manual migration, and today's already-working path-pointer behavior is the fallback, not something being removed.

## Non-goals (this doc, v1)

- Full stateful "remembers everything forever" memory (Letta/Zep-class). Explicitly out of reach without a database — documented tradeoff, not being pursued.
- Cross-project / cross-session semantic search (vector RAG). Wrong tool for a deterministic "read the latest log" lookup.
- Cutting `_Global_Profile.md` / `_Standards.md` token cost. They're small (~24KB combined across the whole vault) and inlining them fully, every launch, is already the right call — nothing to change here.
- Any new adapter (e.g. Copilot). Tracked separately.

## Current behavior (for reference)

- `hooks/claude/session-start.sh`: SessionStart hook, records `git rev-parse HEAD` into `<log>.startsha` when launched via `claude-start` (i.e. `AI_MEM_ACTIVE_SESSION_LOG` is set).
- `hooks/claude/session-summary.sh`: Stop hook, idempotently rewrites a `## Auto Session Log` block (branch, commits since `startsha`, uncommitted changes) into the active session log on every Stop. Unchanged by this PRD.
- `vault-template/_session_logs/_session_template.md`: every session log has a fixed `# Session Outcome` section with five bolded bullets — High-Level Summary, Important Decisions, Constraints / Blockers, Next Step, Notes for Future AI — followed by the auto-appended git block.
- `shell/ai-mem.zsh` (`_ai_mem_context_prompt`, line 185): inlines full text of Global_Profile + Standards. Project note and previous session log are injected as **paths only** — `Latest prior session log: <path>` — plus an instruction to read the log before acting.
- `shell/adapters.zsh`: `memory_prompt` is passed as the **first user message** to claude/codex/gemini/opencode (positional prompt), or seeded into a rules file for cursor. Not a system prompt — the agent sees it as the first thing said to it.

## Proposed design (see "Second correction" above — 1 and 2 were reverted)

### 1. Digest file (reverted — not built)

~~New machine-managed file per project: `_session_logs/<project>/.digest.md`.~~ Rejected: no new files in the vault.

### 2. Write path (reverted — not built)

~~Extend `hooks/claude/session-summary.sh` to also regenerate `.digest.md`.~~ Reverted; the hook is untouched.

### 3. Read path (shipped, adjusted)

`_ai_mem_context_prompt()` extracts four bullets — Summary, Decisions, Blockers, Next — directly from `$previous_session_note` on every call, via `_ai_mem_session_field()`:
1. If at least one bullet is present and non-placeholder → inline all four (missing ones shown as `—`) in place of today's `Latest prior session log: <path>` line.
2. Else (no bullets found, or the log is an untouched template) → today's exact current behavior: the path line + read-before-acting instruction. Unchanged, not removed.
3. No prior session at all → `previous_session_label` stays `(none yet)`. Already handled, nothing to build.

Each inlined value is passed through `_ai_mem_cap_field()` — a defensive 500-char cap with an explicit truncation marker, guarding against one unusually long freeform bullet.

Every branch here either inlines guaranteed-seen content or falls back to the exact behavior that ships today — there is no new "silent" state to introduce.

### 4. Escape hatch (shipped)

`AI_MEM_NO_DIGEST=1` forces branch 2 (today's path-pointer behavior) unconditionally, regardless of whether the previous log has fillable bullets. Safety valve for a live daily-driver tool in case the extraction misbehaves.

## Rollout / backward compatibility

- No file changes anywhere in the vault, ever — this only changes what `ai-mem.zsh` reads and how it's presented in `memory_prompt`. Every existing session log, filled or unfilled, already works with the new read path (see the placeholder-filtering fix above for the unfilled case).
- `install.sh` / `vault-template` need no changes.

## Out of scope for v1 (fast-follow candidates)

- **Running ledger / durable vs ephemeral split**: still theoretically possible without new files (e.g. reading further back than just the latest log), but not built here.
- **Two-tier query**: ripgrep (always available, no dependency) for on-demand deep history search; optionally wire the `obsidian-local-rest-api` MCP server for tag/backlink/frontmatter-aware search when Obsidian happens to be running — never a dependency for the automatic injection path itself, since the index lives in the running app, not the MCP server.
- **Copilot adapter** (`shell/adapters.zsh` doesn't have one yet — separate, unrelated task).

## Test plan

- `tests/run.sh` (offline, stubs the agents): covers bullets inlining directly from the previous log, `AI_MEM_NO_DIGEST` forcing the path-pointer fallback even when bullets exist, and an untouched template's bracket placeholders correctly falling back (and never being inlined as real content).
- `tests/smoke.sh` (live, opt-in): no changes needed — it exercises the adapters end-to-end and doesn't assert on memory_prompt content.

## Decisions carried from review

- Digest generation: template/deterministic extraction from the fixed `# Session Outcome` shape, not an LLM summarization call — the format is already structured, no need to pay for a model call.
- Memory Bank pattern (Cline/Roo Code/Cursor/Cascade) confirmed as validating prior art for this shape (small set of plain markdown, read in full at session start) — not a file-naming convention being adopted; the existing vault structure (`_session_logs/<project>/`, `_projects/<project>.md`, `_Global_Profile.md` + `_Standards.md`) already fits it as-is.
- The real defect being fixed is compliance (agent might not read a pointed-to file), not token cost. This reframing shrank the design considerably from the first draft — no truncation-for-large-logs urgency, no profile/standards caching (never a real token saving), no elaborate rollout story (the fallback chain already ships today unmodified).
- Second reframing (post-implementation) shrank it further: no new file at all, read-time extraction only. Simpler code, one fewer thing that can go stale, and it surfaced a real correctness bug (unfilled template placeholders) that the file-based version would have shipped with too.
