#!/usr/bin/env zsh
# ai-mem test suite. Pure zsh, no framework, no network. Spins up a throwaway
# vault and a throwaway git repo, sources the module, and asserts the behaviors
# that matter: path guarding, project resolution, session prep, the context
# prompt, the config-driven skill picker, launcher generation, adapter dispatch,
# the commit-ready token, and ai-note appends.
#
# Run:  zsh tests/run.sh   (exits non-zero if any assertion fails)

emulate -L zsh
setopt no_unset pipe_fail

REPO_ROOT="${0:A:h:h}"

# --- tiny TAP-ish harness -----------------------------------------------------
integer PASS=0 FAIL=0
ok()  { print -r -- "ok   - $1"; (( PASS++ )); }
nok() { print -r -- "NOT OK - $1"; (( FAIL++ )); }
is()       { [[ "$1" == "$2" ]] && ok "$3" || nok "$3 (got [$1] want [$2])"; }
has()      { [[ "$1" == *"$2"* ]] && ok "$3" || nok "$3 (missing [$2])"; }
hasnt()    { [[ "$1" != *"$2"* ]] && ok "$3" || nok "$3 (unexpected [$2])"; }
succeeds() { if eval "$1" >/dev/null 2>&1; then ok "$2"; else nok "$2 (expected success)"; fi }
fails()    { if eval "$1" >/dev/null 2>&1; then nok "$2 (expected failure)"; else ok "$2"; fi }
exists()   { [[ -e "$1" ]] && ok "$2" || nok "$2 (missing $1)"; }

# --- fixture: throwaway vault + git repo + a fake agent -----------------------
# Isolate from any parent shell that was itself launched via *-start (which
# exports these), so the assertions see only what this run produces.
unset AI_MEM_ACTIVE_SESSION_LOG AI_MEM_PREVIOUS_SESSION_LOG AI_MEM_ACTIVE_PROJECT \
      AI_MEM_CONTEXT_TOKEN AI_MEM_CONTEXT_READY 2>/dev/null || true

export AI_MEM_ROOT="$(mktemp -d)/_Ai_Memory"
"$REPO_ROOT/install.sh" >/dev/null

# Register a fake agent + a fake skill BEFORE sourcing so the launcher loop and
# the picker pick them up. The adapter just records the prompt it was handed.
CAPTURE="$(mktemp)"
_ai_adapter_faketest() { print -r -- "$1" > "$CAPTURE"; }
export AI_MEM_AGENTS="claude codex gemini cursor opencode faketest"
typeset -gA AI_MEM_SKILLS
AI_MEM_SKILLS[terse]='Use terse output this session?::Respond tersely; drop filler.'
AI_MEM_SKILL_ORDER=(terse)

source "$REPO_ROOT/shell/ai-mem.zsh"

WORK="$(mktemp -d)/demoproj"
mkdir -p "$WORK"
git -C "$WORK" init -q
git -C "$WORK" config user.email test@example.com
git -C "$WORK" config user.name  tester
cd "$WORK"

# --- 1. path guard ------------------------------------------------------------
succeeds '_ai_mem_guard "$AI_MEM_ROOT/_projects/x.md"' "guard allows a path inside the vault"
fails    '_ai_mem_guard /etc/passwd'                    "guard rejects a path outside the vault"

# --- 2. project resolution = git repo basename --------------------------------
is "$(_ai_mem_resolve_project)" "demoproj" "project resolves to the git repo dir name"

# --- 3. session prep creates notes and exports state --------------------------
resolved="$(_ai_mem_prepare_session)"
project="${resolved%%|*}"; rest="${resolved#*|}"
project_note="${rest%%|*}"; rest="${rest#*|}"
prev_log="${rest%%|*}"; session_note="${rest##*|}"
is "$project" "demoproj"                          "prepare_session reports the project"
exists "$project_note"                            "prepare_session creates the project note"
exists "$session_note"                            "prepare_session creates a session log"
is "$prev_log" ""                                 "no prior log on the first session"
has "$(<"$project_note")" "demoproj"              "project note has the name substituted in from the template"

# --- 4. context prompt embeds the whole memory stack --------------------------
# Redirect (not $()) so ai-context runs in THIS shell and its exports survive.
CTXFILE="$(mktemp)"
ai-context > "$CTXFILE"
ctx="$(<"$CTXFILE")"
has "$ctx" "Read these notes before doing anything else:" "context prompt has the lead instruction"
has "$ctx" "type: ai-global-profile"                       "context prompt embeds the global profile"
has "$ctx" "Shared Standards"                              "context prompt embeds the standards note"
has "$ctx" "_projects/demoproj.md"                         "context prompt references the project note"
has "${AI_MEM_ACTIVE_SESSION_LOG:-}" "$AI_MEM_ROOT"        "active session log is exported under the vault"
has "${AI_MEM_ACTIVE_SESSION_LOG:-}" "demoproj"            "active session log belongs to this project"

# --- 5. commit-ready token is written and matches the shell -------------------
token_file="$AI_MEM_ROOT/_session_logs/.context-ready/demoproj.token"
exists "$token_file"                                       "ai-context writes the commit-ready token file"
is "$(sed -n 1p "$token_file")" "${AI_MEM_CONTEXT_TOKEN:-}" "token file matches the exported token"

# --- 6. config-driven skill picker -------------------------------------------
AI_MEM_SKILL_ORDER=()
is "$(_ai_session_modes_pick </dev/null)" "" "picker is empty when no skills are registered"
AI_MEM_SKILL_ORDER=(terse)
picked="$(printf 'y\n' | _ai_session_modes_pick)"
is "$picked" "terse"                                            "picker returns a skill answered yes"
is "$(printf 'n\n' | _ai_session_modes_pick)" ""                "picker drops a skill answered no"
has "$(_ai_session_modes_instructions terse)" "Respond tersely" "instructions inject the chosen skill's block"

# --- 7. launcher generation ---------------------------------------------------
for a in claude codex gemini cursor opencode faketest; do
  succeeds "typeset -f ${a}-start" "generated launcher: ${a}-start"
done
fails 'typeset -f bogus-start' "no launcher for an unregistered agent"

# --- 8. adapter dispatch: unknown agent errors, known agent gets the prompt ---
fails '_ai_session_start bogus </dev/null' "dispatch fails for an agent with no adapter"
faketest-start </dev/null >/dev/null 2>&1
has "$(<"$CAPTURE")" "Read these notes before doing anything else:" "adapter receives the assembled memory prompt"
has "$(<"$CAPTURE")" "demoproj"                                     "assembled prompt carries project context"

# --- 9. ai-note appends under Live Notes -------------------------------------
ai-note "wired the payment webhook" >/dev/null
today_log="$(_ai_mem_today_session_log demoproj)"
has "$(<"$today_log")" "### Live Notes"           "ai-note creates the Live Notes section"
has "$(<"$today_log")" "wired the payment webhook" "ai-note appends the note text"

# --- 10. cursor adapter: writes/clears its managed rule file (no GUI) ---------
# cursor has no headless prompt path; the adapter persists the session's skills
# as an always-apply rule instead. Verify that offline with the GUI launch stubbed.
CURSOR_HOME="$(mktemp -d)"; _OLDHOME="$HOME"; export HOME="$CURSOR_HOME"
open()   { : ; }   # stub `open -a Cursor`
cursor() { : ; }   # stub the cursor CLI if present
CRULE="$HOME/.cursor/rules/_ai-session.mdc"
_ai_adapter_cursor "mem" "SESSION SKILL BLOCK" </dev/null
exists "$CRULE"                                "cursor adapter writes the managed rule file"
has "$(<"$CRULE")" "SESSION SKILL BLOCK"       "cursor rule carries the session skill block"
_ai_adapter_cursor "mem" "" </dev/null
[[ ! -e "$CRULE" ]] && ok "cursor adapter clears the rule when no skills are chosen" \
                    || nok "cursor adapter clears the rule when no skills are chosen"
unfunction open cursor 2>/dev/null
export HOME="$_OLDHOME"

# --- summary ------------------------------------------------------------------
print -r -- "----"
print -r -- "$(( PASS + FAIL )) tests, $PASS passed, $FAIL failed"
(( FAIL == 0 ))
