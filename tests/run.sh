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
faketest() { : }            # stub CLI so the missing-agent guard lets faketest through
_ai_adapter_ghost() { : }   # adapter exists but there is no `ghost` CLI on PATH
export AI_MEM_AGENTS="claude codex gemini cursor opencode faketest ghost"
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

# --- 3b. session log frontmatter links to the project note and prior session --
# A separate project name so this never perturbs demoproj's own session chain,
# which later sections rely on being exactly what section 3 created.
LT1="$(_ai_mem_prepare_session linktest)"
LT1_NOTE="${LT1##*|}"
has "$(<"$LT1_NOTE")" 'project: "[[linktest]]"' "session frontmatter links to the project note"
has "$(<"$LT1_NOTE")" 'previous: ""'            "first session has no previous link"

LT2="$(_ai_mem_prepare_session linktest)"
LT2_NOTE="${LT2##*|}"
LT1_BASENAME="${LT1_NOTE:t:r}"
has "$(<"$LT2_NOTE")" "previous: \"[[${LT1_BASENAME}]]\"" "second session links back to the first"
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

# --- 4b. prior session's Session Outcome bullets inline directly, no extra file
PREVLOG="$AI_MEM_SESSION_DIR/demoproj/demoproj-2026-08-20_10-00-00.md"
cat > "$PREVLOG" <<'EOF'
---
date: 2026-08-20
---

# Session Outcome
* **High-Level Summary:** built the thing
* **Important Decisions:** used option B
* **Constraints / Blockers:** none
* **Next Step:** ship it
EOF

inline_ctx="$(_ai_mem_context_prompt "$project_note" "$PREVLOG" "$session_note")"
has   "$inline_ctx" "used option B"                                    "prior session bullets are extracted and inlined directly from the log"
hasnt "$inline_ctx" "Read the latest prior session log for continuity" "no read-instruction fallback text when bullets are found"

nodigest_ctx="$(AI_MEM_NO_DIGEST=1 _ai_mem_context_prompt "$project_note" "$PREVLOG" "$session_note")"
hasnt "$nodigest_ctx" "used option B"                                    "AI_MEM_NO_DIGEST skips inlining even when bullets exist"
has   "$nodigest_ctx" "Read the latest prior session log for continuity" "AI_MEM_NO_DIGEST falls back to the read instruction"

# An untouched template (still has [bracket] placeholders) must not be inlined
# as if it were real content.
UNFILLEDLOG="$AI_MEM_SESSION_DIR/demoproj/demoproj-2026-08-21_10-00-00.md"
cat > "$UNFILLEDLOG" <<'EOF'
# Session Outcome
* **High-Level Summary:** [What changed or was decided]
* **Important Decisions:** [Durable decisions only]
* **Constraints / Blockers:** [What is still limiting progress]
* **Next Step:** [Most important follow-up]
EOF
unfilled_ctx="$(_ai_mem_context_prompt "$project_note" "$UNFILLEDLOG" "$session_note")"
has   "$unfilled_ctx" "Read the latest prior session log for continuity" "an untouched template's bracket placeholders fall back to the read instruction"
hasnt "$unfilled_ctx" "What changed or was decided"                     "bracket placeholder text is never inlined as if it were real content"
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

# A same-named alias from another plugin (e.g. ai-prompt-search wraps
# claude-start/codex-start as aliases) used to make zsh refuse to `eval` the
# launcher function at all: "defining function based on alias", parse error
# near '()'. Re-source in a throwaway shell with that alias predefined.
ALIAS_CONFLICT_OUT="$(AI_MEM_ROOT="$(mktemp -d)/_Ai_Memory" zsh -c '
  alias claude-start="echo should-not-run"
  source "'"$REPO_ROOT"'/shell/ai-mem.zsh"
  typeset -f claude-start >/dev/null && echo is-function || echo not-a-function
' 2>&1)"
has   "$ALIAS_CONFLICT_OUT" "is-function"   "a pre-existing same-named alias does not break launcher generation"
hasnt "$ALIAS_CONFLICT_OUT" "parse error"    "no parse error when a launcher name collides with an existing alias"

# --- 8. adapter dispatch: unknown agent errors, known agent gets the prompt ---
fails '_ai_session_start bogus </dev/null' "dispatch fails for an agent with no adapter"
faketest-start </dev/null >/dev/null 2>&1
has "$(<"$CAPTURE")" "Read these notes before doing anything else:" "adapter receives the assembled memory prompt"
has "$(<"$CAPTURE")" "demoproj"                                     "assembled prompt carries project context"

# --- 8b. missing agent CLI is blocked before a session log is created ---------
ghost_before="$(find "$AI_MEM_SESSION_DIR" -name 'demoproj-*.md' 2>/dev/null | wc -l | tr -d ' ')"
ghost_out="$(ghost-start </dev/null 2>&1)"; ghost_rc=$?
[[ $ghost_rc -ne 0 ]] && ok "missing agent CLI makes the launcher fail" || nok "missing agent CLI makes the launcher fail"
has "$ghost_out" "not found on PATH" "missing agent CLI prints a clear message"
ghost_after="$(find "$AI_MEM_SESSION_DIR" -name 'demoproj-*.md' 2>/dev/null | wc -l | tr -d ' ')"
is "$ghost_after" "$ghost_before" "missing agent CLI creates no stray session log"

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

# --- 12. session-summary.sh optionally backs up a git-backed vault -----------
GITVAULT="$(mktemp -d)"
git -C "$GITVAULT" init -q
git -C "$GITVAULT" config user.email t@t.com
git -C "$GITVAULT" config user.name t
mkdir -p "$GITVAULT/proj"
GITVAULT_LOG="$GITVAULT/proj/hooklog.md"
print -r -- $'---\ndate: 2026-08-28\n---\n\n# Session Outcome' > "$GITVAULT_LOG"
git -C "$GITVAULT" add -A && git -C "$GITVAULT" commit -q -m "initial vault state"

AI_MEM_ROOT="$GITVAULT" AI_MEM_ACTIVE_SESSION_LOG="$GITVAULT_LOG" \
  bash "$REPO_ROOT/hooks/claude/session-summary.sh"
is "$(git -C "$GITVAULT" status --short)" ""                     "vault backup hook leaves the git-backed vault clean after committing"
has "$(git -C "$GITVAULT" log --oneline -1)" "vault backup"       "vault backup hook creates a commit"

NOGITVAULT="$(mktemp -d)/not_a_git_repo"
mkdir -p "$NOGITVAULT/proj"
NOGITVAULT_LOG="$NOGITVAULT/proj/hooklog.md"
print -r -- $'---\ndate: 2026-08-28\n---' > "$NOGITVAULT_LOG"
succeeds 'AI_MEM_ROOT="$NOGITVAULT" AI_MEM_ACTIVE_SESSION_LOG="$NOGITVAULT_LOG" bash "$REPO_ROOT/hooks/claude/session-summary.sh"' \
  "vault backup hook no-ops cleanly when the vault isn't git-backed"
# --- summary ------------------------------------------------------------------
print -r -- "----"
print -r -- "$(( PASS + FAIL )) tests, $PASS passed, $FAIL failed"
(( FAIL == 0 ))
