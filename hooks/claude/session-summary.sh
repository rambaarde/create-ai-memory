#!/usr/bin/env bash
# Claude Code Stop hook for the AI-memory vault.
#
# Idempotently writes a concrete "Auto Session Log" block (branch, commits made
# this session, and uncommitted changes) into the active session log, so the
# NEXT session has real carryover instead of an empty template. Runs on every
# Stop and rewrites a single block, so the log always reflects the latest state
# even if the session is later killed abruptly.
#
# No-ops unless the session was launched via claude-start (which exports
# AI_MEM_ACTIVE_SESSION_LOG).
set -euo pipefail

log="${AI_MEM_ACTIVE_SESSION_LOG:-}"
[ -n "$log" ] || exit 0
[ -f "$log" ] || exit 0

marker="## Auto Session Log"

branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '(no git)')"
repo="$(git rev-parse --show-toplevel 2>/dev/null || true)"

start_sha=""
[ -f "${log%.md}.startsha" ] && start_sha="$(cat "${log%.md}.startsha" 2>/dev/null || true)"

commits=""
if [ -n "$start_sha" ]; then
    commits="$(git log --no-merges --format='- %h %s' "${start_sha}..HEAD" 2>/dev/null || true)"
fi
[ -n "$commits" ] || commits="- (no commits this session)"

changes="$(git status --short 2>/dev/null | sed 's/^/- /' || true)"
[ -n "$changes" ] || changes="- (working tree clean)"

stamp="$(date '+%Y-%m-%d %H:%M:%S')"

block="$(cat <<EOF
${marker}
_Auto-generated ${stamp}. Edit the Session Outcome section above for durable notes._

* **Repo:** ${repo:-?}
* **Branch:** ${branch}
* **Commits this session:**
${commits}
* **Uncommitted changes at last checkpoint:**
${changes}
EOF
)"

# Strip any previous auto block (from marker to EOF), then append the fresh one.
tmp="$(mktemp)"
awk -v m="$marker" 'index($0, m)==1 { exit } { print }' "$log" > "$tmp"
printf '%s\n\n%s\n' "$(cat "$tmp")" "$block" > "$log"
rm -f "$tmp"
