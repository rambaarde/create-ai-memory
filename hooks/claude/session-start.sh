#!/usr/bin/env bash
# Claude Code SessionStart hook for the AI-memory vault.
#
# Records the repo HEAD at session start so the matching summary hook can show
# exactly which commits this session produced. No-ops unless the session was
# launched via claude-start (which exports AI_MEM_ACTIVE_SESSION_LOG), so plain
# `claude` runs are untouched.
set -euo pipefail

log="${AI_MEM_ACTIVE_SESSION_LOG:-}"
[ -n "$log" ] || exit 0

sha="$(git rev-parse HEAD 2>/dev/null || true)"
[ -n "$sha" ] || exit 0

# The log directory can disappear under a running shell -- a project rename
# moves it, and AI_MEM_ACTIVE_SESSION_LOG still points at the old path.
# Without this guard the redirect fails, `set -e` aborts, and Claude Code
# prints the hook's error -- including these absolute paths -- into the first
# frame of every session. A SessionStart hook must fail open: it is
# bookkeeping, not a gate.
[ -d "$(dirname "$log")" ] || exit 0

printf '%s\n' "$sha" > "${log%.md}.startsha" 2>/dev/null || exit 0
