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

printf '%s\n' "$sha" > "${log%.md}.startsha"
