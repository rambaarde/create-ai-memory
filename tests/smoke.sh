#!/usr/bin/env zsh
# LIVE agent smoke test (opt-in). Actually launches each agent headlessly with a
# trivial prompt and checks it echoes a sentinel back. This proves the adapters'
# CLIs really run end to end, unlike tests/run.sh, which is offline and stubs the
# agents.
#
# It makes REAL API calls, so it needs each CLI installed and authed and may cost
# tokens. It is NOT part of tests/run.sh; run it deliberately:
#
#   zsh tests/smoke.sh                 # every supported agent that is installed
#   zsh tests/smoke.sh claude opencode # just these
#
# opencode defaults to DeepSeek (cheap/free tier). Override any of:
#   AIMEM_SMOKE_TIMEOUT=120
#   AIMEM_SMOKE_OPENCODE_MODEL=deepseek/deepseek-chat

emulate -L zsh
setopt pipe_fail

SENTINEL="AIMEM_SMOKE_OK"
PROMPT="Reply with exactly this token and nothing else: $SENTINEL"
TIMEOUT_SECS="${AIMEM_SMOKE_TIMEOUT:-120}"
OPENCODE_MODEL="${AIMEM_SMOKE_OPENCODE_MODEL:-deepseek/deepseek-chat}"

# Pick a timeout wrapper: GNU timeout, coreutils gtimeout, or none (macOS base).
if command -v timeout >/dev/null 2>&1;  then TIMEOUT=(timeout "$TIMEOUT_SECS")
elif command -v gtimeout >/dev/null 2>&1; then TIMEOUT=(gtimeout "$TIMEOUT_SECS")
else TIMEOUT=(); print -r -- "note: no timeout(1) found; runs are unbounded"; fi

integer PASS=0 FAIL=0 SKIP=0
first_line() { print -r -- "${1%%$'\n'*}"; }

# run_agent <name> <cmd...>: skip if the CLI is absent, else run and match sentinel.
run_agent() {
  local name="$1"; shift
  if ! command -v "$1" >/dev/null 2>&1; then
    print -r -- "skip $name (not installed)"; (( SKIP++ )); return
  fi
  local out rc
  out="$("${TIMEOUT[@]}" "$@" </dev/null 2>&1)"; rc=$?
  if [[ "$out" == *"$SENTINEL"* ]]; then
    print -r -- "ok   $name"; (( PASS++ ))
  elif (( rc == 124 )); then
    print -r -- "FAIL $name (timed out after ${TIMEOUT_SECS}s)"; (( FAIL++ ))
  else
    print -r -- "FAIL $name (exit $rc): $(first_line "$out")"; (( FAIL++ ))
  fi
}

# Agents with a real headless path. cursor has none (it opens the app), so it is
# verified offline in tests/run.sh instead, not here.
local -a agents
if [[ $# -gt 0 ]]; then agents=("$@"); else agents=(claude codex gemini opencode); fi

for a in $agents; do
  case "$a" in
    claude)   run_agent claude   claude -p "$PROMPT" ;;
    codex)    run_agent codex    codex exec "$PROMPT" ;;
    gemini)   run_agent gemini   gemini -p "$PROMPT" ;;
    opencode) run_agent opencode opencode run "$PROMPT" --model "$OPENCODE_MODEL" ;;
    cursor)   print -r -- "FAIL cursor has no headless path; run tests/run.sh (offline) to verify its adapter"; (( FAIL++ )) ;;
    *)        print -r -- "FAIL unknown agent: $a"; (( FAIL++ )) ;;
  esac
done

print -r -- "----"
print -r -- "$PASS passed, $FAIL failed, $SKIP skipped"
(( FAIL == 0 ))
