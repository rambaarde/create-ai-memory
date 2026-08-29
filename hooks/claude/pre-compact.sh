#!/usr/bin/env bash
# Claude Code PreCompact hook for the AI-memory vault.
#
# Auto-compact erases whatever the agent hasn't written down yet. This hook
# blocks the FIRST auto-compact attempt per session (exit 2 + stderr, which
# Claude Code surfaces to the agent) to nudge it into running `ai-note` before
# its working context is thrown away. A marker file makes it one-shot: every
# later compact attempt this session exits 0 immediately, so the session can
# never get stuck refusing to compact.
#
# No-ops unless the session was launched via claude-start (which exports
# AI_MEM_ACTIVE_SESSION_LOG). Wire this with matcher "auto" only -- a manual
# /compact is a deliberate user action, not the silent-erasure case this
# guards against.
set -euo pipefail

log="${AI_MEM_ACTIVE_SESSION_LOG:-}"
[ -n "$log" ] || exit 0
[ -f "$log" ] || exit 0

marker="${log%.md}.precompact-nudged"
[ -f "$marker" ] && exit 0

touch "$marker"
echo "Auto-compact is about to run and will erase anything not written down. Run ai-note \"<what matters from this session so far>\" now, then continue." >&2
exit 2
