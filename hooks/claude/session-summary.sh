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

# Optional vault backup: if AI_MEM_ROOT (or an ancestor directory) is its own
# git repo, commit and push whatever changed this session. Entirely separate
# from the project repo git calls above -- this targets the vault, not the
# code being worked on. No-ops silently if the vault isn't git-backed; this
# is best-effort and must never fail the hook or block the session on a push
# error (no network, no remote configured, etc).
vault_git_root="$(git -C "${AI_MEM_ROOT:-}" rev-parse --show-toplevel 2>/dev/null || true)"
if [ -n "$vault_git_root" ]; then
    # A same-second Stop from a second terminal is real -- flock isn't
    # portable to every platform this ships on, but `mkdir` is atomic
    # everywhere. A lock older than 60s is almost certainly abandoned by a
    # crashed run, not a genuine concurrent one (this operation normally
    # completes in well under a second), so clear it rather than let one
    # dead process wedge every future backup forever.
    lock_dir="$vault_git_root/.git/aimem-backup.lock"
    if [ -d "$lock_dir" ]; then
        lock_age=$(( $(date +%s) - $(stat -f %m "$lock_dir" 2>/dev/null || stat -c %Y "$lock_dir" 2>/dev/null || echo 0) ))
        if [ "$lock_age" -gt 60 ]; then
            rmdir "$lock_dir" 2>/dev/null || true
        fi
    fi

    if mkdir "$lock_dir" 2>/dev/null; then
        trap 'rmdir "$lock_dir" 2>/dev/null || true' EXIT
        git -C "$vault_git_root" add -A 2>/dev/null || true
        if ! git -C "$vault_git_root" diff --cached --quiet 2>/dev/null; then
            git -C "$vault_git_root" commit -q -m "vault backup: ${stamp}" 2>/dev/null || true
            git -C "$vault_git_root" push -q 2>/dev/null || true
        fi
        rmdir "$lock_dir" 2>/dev/null || true
        trap - EXIT
    fi
    # else: another process holds a fresh lock right now -- skip silently,
    # the next Stop event (this session or another) will catch up.
fi
