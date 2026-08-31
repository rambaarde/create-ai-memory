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
__ai_adapter_faketest() { print -r -- "$1" > "$CAPTURE"; }
faketest() { : }            # stub CLI so the missing-agent guard lets faketest through
__ai_adapter_ghost() { : }   # adapter exists but there is no `ghost` CLI on PATH
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
succeeds '__ai_mem_guard "$AI_MEM_ROOT/_projects/x.md"' "guard allows a path inside the vault"
fails    '__ai_mem_guard /etc/passwd'                    "guard rejects a path outside the vault"

# --- 2. project resolution = git repo basename --------------------------------
is "$(__ai_mem_resolve_project)" "demoproj" "project resolves to the git repo dir name"

# --- 3. session prep creates notes and exports state --------------------------
resolved="$(__ai_mem_prepare_session)"
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
LT1="$(__ai_mem_prepare_session linktest)"
LT1_NOTE="${LT1##*|}"
has "$(<"$LT1_NOTE")" 'project: "[[linktest]]"' "session frontmatter links to the project note"
has "$(<"$LT1_NOTE")" 'previous: ""'            "first session has no previous link"

LT2="$(__ai_mem_prepare_session linktest)"
LT2_NOTE="${LT2##*|}"
LT1_BASENAME="${LT1_NOTE:t:r}"
has "$(<"$LT2_NOTE")" "previous: \"[[${LT1_BASENAME}]]\"" "second session links back to the first"

# Persistence beyond 2 sessions: a third session must chain to the second,
# not fall back to the first or drop the link entirely.
sleep 1.1  # filenames are second-granularity; guarantee a distinct timestamp
LT3="$(__ai_mem_prepare_session linktest)"
LT3_NOTE="${LT3##*|}"
LT2_BASENAME="${LT2_NOTE:t:r}"
has "$(<"$LT3_NOTE")" "previous: \"[[${LT2_BASENAME}]]\"" "third session links back to the second, not the first"

# A brand-new, different project gets the same treatment automatically, and
# its chain starts fresh -- it must not pick up linktest's history.
OTHERPROJ="$(__ai_mem_prepare_session othernewproj)"
OTHERPROJ_NOTE="${OTHERPROJ##*|}"
has "$(<"$OTHERPROJ_NOTE")" 'project: "[[othernewproj]]"' "a brand-new project also gets a correct project wikilink"
has "$(<"$OTHERPROJ_NOTE")" 'previous: ""'                 "a brand-new project's first session is isolated from another project's chain"
# --- 4. context prompt embeds the whole memory stack --------------------------
# Redirect (not $()) so ai-context runs in THIS shell and its exports survive.
CTXFILE="$(mktemp)"
ai-context > "$CTXFILE"
ctx="$(<"$CTXFILE")"
has "$ctx" "Read these notes before doing anything else:" "context prompt has the lead instruction"
has "$ctx" "type: ai-global-profile"                       "context prompt embeds the global profile"
has "$ctx" "Shared Standards"                              "context prompt embeds the standards note"
has "$ctx" "_projects/demoproj.md"                         "context prompt references the project note"
has "$ctx" "ai-mem-search"                                 "context prompt tells the agent ai-mem-search exists"
has "$ctx" "ai-mem-lint"                                   "context prompt tells the agent ai-mem-lint exists"
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

inline_ctx="$(__ai_mem_context_prompt "$project_note" "$PREVLOG" "$session_note")"
has   "$inline_ctx" "used option B"                                    "prior session bullets are extracted and inlined directly from the log"
hasnt "$inline_ctx" "Read the latest prior session log for continuity" "no read-instruction fallback text when bullets are found"

nodigest_ctx="$(AI_MEM_NO_DIGEST=1 __ai_mem_context_prompt "$project_note" "$PREVLOG" "$session_note")"
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
unfilled_ctx="$(__ai_mem_context_prompt "$project_note" "$UNFILLEDLOG" "$session_note")"
has   "$unfilled_ctx" "Read the latest prior session log for continuity" "an untouched template's bracket placeholders fall back to the read instruction"
hasnt "$unfilled_ctx" "What changed or was decided"                     "bracket placeholder text is never inlined as if it were real content"
# --- 5. commit-ready token is written and matches the shell -------------------
token_file="$AI_MEM_ROOT/_session_logs/.context-ready/demoproj.token"
exists "$token_file"                                       "ai-context writes the commit-ready token file"
is "$(sed -n 1p "$token_file")" "${AI_MEM_CONTEXT_TOKEN:-}" "token file matches the exported token"

# --- 6. config-driven skill picker -------------------------------------------
AI_MEM_SKILL_ORDER=()
is "$(__ai_session_modes_pick </dev/null)" "" "picker is empty when no skills are registered"
AI_MEM_SKILL_ORDER=(terse)
picked="$(printf 'y\n' | __ai_session_modes_pick)"
is "$picked" "terse"                                            "picker returns a skill answered yes"
is "$(printf 'n\n' | __ai_session_modes_pick)" ""                "picker drops a skill answered no"
has "$(__ai_session_modes_instructions terse)" "Respond tersely" "instructions inject the chosen skill's block"

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

# --- 7b. stale-shell detection ------------------------------------------------
# An already-open shell keeps the function definitions it loaded at startup,
# so editing the module or upgrading the package changes nothing there. The
# launcher would otherwise run, report success, and silently use months-old
# behaviour. Copy the module to a temp dir so the test can mutate it without
# touching the repo.
STALEDIR="$(mktemp -d)"
cp "$REPO_ROOT/shell/ai-mem.zsh" "$REPO_ROOT/shell/adapters.zsh" "$STALEDIR/"
STALE_FRESH_OUT="$(AI_MEM_ROOT="$(mktemp -d)/_Ai_Memory" zsh -c "
  source '$STALEDIR/ai-mem.zsh'
  __ai_session_start bogus </dev/null
" 2>&1)"
hasnt "$STALE_FRESH_OUT" "older copy" "no stale warning when the loaded module matches the file on disk"

STALE_CHANGED_OUT="$(AI_MEM_ROOT="$(mktemp -d)/_Ai_Memory" zsh -c "
  source '$STALEDIR/ai-mem.zsh'
  printf '\n# edited after this shell sourced it\n' >> '$STALEDIR/ai-mem.zsh'
  __ai_session_start bogus </dev/null
" 2>&1)"
has "$STALE_CHANGED_OUT" "older copy"      "warns when the module changed after this shell sourced it"
has "$STALE_CHANGED_OUT" "source ~/.zshrc" "the stale warning names the concrete fix"
rm -rf "$STALEDIR"

# --- 8. adapter dispatch: unknown agent errors, known agent gets the prompt ---
fails '__ai_session_start bogus </dev/null' "dispatch fails for an agent with no adapter"
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
today_log="$(__ai_mem_today_session_log demoproj)"
has "$(<"$today_log")" "### Live Notes"           "ai-note creates the Live Notes section"
has "$(<"$today_log")" "wired the payment webhook" "ai-note appends the note text"

# --- 9b. ai-lesson files a cross-project Problem/Solution note under _lessons/
LESSON_FILE="$AI_MEM_ROOT/_lessons/rate-limiting.md"
fails 'ai-lesson' "ai-lesson fails without a topic"
fails 'ai-lesson rate-limiting' "ai-lesson fails without a problem"
fails 'ai-lesson rate-limiting "fixed window lost bursts"' "ai-lesson fails without a solution"
succeeds 'ai-lesson rate-limiting "fixed window lost bursts" "token bucket beat fixed window for bursty traffic"' \
  "ai-lesson accepts a topic, problem, and solution"
exists "$LESSON_FILE" "ai-lesson creates _lessons/<topic-slug>.md"
has "$(<"$LESSON_FILE")" "### Problem"                  "ai-lesson writes a Problem header"
has "$(<"$LESSON_FILE")" "fixed window lost bursts"      "ai-lesson appends the problem text"
has "$(<"$LESSON_FILE")" "### Solution"                 "ai-lesson writes a Solution header"
has "$(<"$LESSON_FILE")" "token bucket beat fixed window" "ai-lesson appends the solution text"
has "$(<"$LESSON_FILE")" "[[demoproj]]" "ai-lesson tags the entry with a project wikilink, not a plain bracket"
ai-lesson "Rate Limiting!!" "second problem, same topic" "second solution" >/dev/null
is "$(grep -c '^## ' "$LESSON_FILE")" "2" "ai-lesson slugifies the topic so a re-run appends to the same file"

exists "$AI_MEM_ROOT/_lessons/_lesson_template.md" "install.sh seeds a _lesson_template.md, matching the project/session template pattern"
LESSON_TEMPLATE_BACKUP="$(<"$AI_MEM_ROOT/_lessons/_lesson_template.md")"
print -r -- $'---\ntype: ai-lesson\ntopic: "{{topic}}"\nmarker: CUSTOM-TEMPLATE-MARKER\n---\n\n# {{topic}}' > "$AI_MEM_ROOT/_lessons/_lesson_template.md"
ai-lesson custom-template-check "problem" "proves the template file drives creation, not a hardcoded string" >/dev/null
has "$(<"$AI_MEM_ROOT/_lessons/custom-template-check.md")" "CUSTOM-TEMPLATE-MARKER" \
  "ai-lesson expands _lesson_template.md (with {{topic}} substituted) for new files, not a hardcoded format"
print -r -- "$LESSON_TEMPLATE_BACKUP" > "$AI_MEM_ROOT/_lessons/_lesson_template.md"
succeeds 'ai-mem-search "token bucket"' "ai-mem-search already covers _lessons/ with no extra wiring"

LESSON_COUNT_BEFORE="$(find "$AI_MEM_ROOT/_lessons" -type f -name '*.md' | wc -l | tr -d ' ')"
fails 'ai-lesson "!!!" "problem" "solution"' "ai-lesson rejects a topic that slugifies to nothing"
is "$(find "$AI_MEM_ROOT/_lessons" -type f -name '*.md' | wc -l | tr -d ' ')" "$LESSON_COUNT_BEFORE" \
  "a rejected topic creates no stray file"

ai-lesson "../../etc/evil" "problem" "should not escape the vault" >/dev/null
is "$(find "$AI_MEM_ROOT" -name 'evil.md' -o -name '*passwd*' 2>/dev/null)" "" \
  "ai-lesson cannot path-traverse out of _lessons/ via a crafted topic"
exists "$AI_MEM_ROOT/_lessons/etc-evil.md" "a crafted topic is slugified flat, not treated as a path"

# --- 10. cursor adapter: writes/clears its managed rule file (no GUI) ---------
# cursor has no headless prompt path; the adapter persists the session's skills
# as an always-apply rule instead. Verify that offline with the GUI launch stubbed.
CURSOR_HOME="$(mktemp -d)"; _OLDHOME="$HOME"; export HOME="$CURSOR_HOME"
open()   { : ; }   # stub `open -a Cursor`
cursor() { : ; }   # stub the cursor CLI if present
CRULE="$HOME/.cursor/rules/_ai-session.mdc"
__ai_adapter_cursor "mem" "SESSION SKILL BLOCK" </dev/null
exists "$CRULE"                                "cursor adapter writes the managed rule file"
has "$(<"$CRULE")" "SESSION SKILL BLOCK"       "cursor rule carries the session skill block"
__ai_adapter_cursor "mem" "" </dev/null
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

# --- ai-note/ai-lesson trigger a real vault backup too, not just the Stop
# hook -- Stop can silently never fire, so a note must be durable the moment
# it's written.
NOTEVAULT="$(mktemp -d)"
git -C "$NOTEVAULT" init -q
git -C "$NOTEVAULT" config user.email t@t.com
git -C "$NOTEVAULT" config user.name t

NOTEWORK="$(mktemp -d)/repo"
mkdir -p "$NOTEWORK"
git -C "$NOTEWORK" init -q
git -C "$NOTEWORK" config user.email t@t.com
git -C "$NOTEWORK" config user.name t
git -C "$NOTEWORK" commit --allow-empty -q -m init

AI_MEM_ROOT="$NOTEVAULT" zsh -c '
  "'"$REPO_ROOT"'/install.sh" >/dev/null 2>&1
  git -C "'"$NOTEVAULT"'" add -A && git -C "'"$NOTEVAULT"'" commit -q -m "seed" 2>/dev/null
  source "'"$REPO_ROOT"'/shell/ai-mem.zsh"
  cd "'"$NOTEWORK"'"
  ai-note "backup smoke test" >/dev/null
'
has "$(git -C "$NOTEVAULT" log --oneline -1)" "vault backup" "ai-note triggers a real vault backup commit, not just the Stop hook"

# --- ai-mem-vault-backup: the public entry point anything else can call
# (e.g. the update-session-log skill, which edits files directly and never
# goes through ai-note/ai-lesson).
echo "more" >> "$NOTEVAULT/_Global_Profile.md"
BACKUP_OUT="$(AI_MEM_ROOT="$NOTEVAULT" zsh -c '
  source "'"$REPO_ROOT"'/shell/ai-mem.zsh"
  ai-mem-vault-backup
')"
has "$BACKUP_OUT" "pushed" "ai-mem-vault-backup reports pushed when there is something to commit"
is "$(git -C "$NOTEVAULT" status --short)" "" "ai-mem-vault-backup leaves the vault clean after committing"
BACKUP_OUT2="$(AI_MEM_ROOT="$NOTEVAULT" zsh -c '
  source "'"$REPO_ROOT"'/shell/ai-mem.zsh"
  ai-mem-vault-backup
')"
has "$BACKUP_OUT2" "nothing to commit" "ai-mem-vault-backup reports nothing to commit on a clean tree"

# A concurrent Stop from a second terminal must skip cleanly, not crash --
# and a lock abandoned by a crashed run must not wedge every future backup.
LOCKVAULT="$(mktemp -d)"
git -C "$LOCKVAULT" init -q
git -C "$LOCKVAULT" config user.email t@t.com
git -C "$LOCKVAULT" config user.name t
mkdir -p "$LOCKVAULT/proj"
LOCKVAULT_LOG="$LOCKVAULT/proj/hooklog.md"
echo "# Session Outcome" > "$LOCKVAULT_LOG"
git -C "$LOCKVAULT" add -A && git -C "$LOCKVAULT" commit -q -m init

mkdir "$LOCKVAULT/.git/aimem-backup.lock"
echo "more" >> "$LOCKVAULT_LOG"
succeeds 'AI_MEM_ROOT="$LOCKVAULT" AI_MEM_ACTIVE_SESSION_LOG="$LOCKVAULT_LOG" bash "$REPO_ROOT/hooks/claude/session-summary.sh"' \
  "vault backup hook exits cleanly when another process holds a fresh lock"
exists "$LOCKVAULT/.git/aimem-backup.lock" "a fresh, contended lock is left untouched, not stolen"
is "$(git -C "$LOCKVAULT" log --oneline | wc -l | tr -d ' ')" "1" "no backup commit happens while the lock is held by someone else"
rmdir "$LOCKVAULT/.git/aimem-backup.lock"

mkdir "$LOCKVAULT/.git/aimem-backup.lock"
touch -t "$(date -v-61S '+%Y%m%d%H%M.%S' 2>/dev/null || date -d '61 seconds ago' '+%Y%m%d%H%M.%S')" "$LOCKVAULT/.git/aimem-backup.lock"
AI_MEM_ROOT="$LOCKVAULT" AI_MEM_ACTIVE_SESSION_LOG="$LOCKVAULT_LOG" bash "$REPO_ROOT/hooks/claude/session-summary.sh"
is "$(git -C "$LOCKVAULT" log --oneline | wc -l | tr -d ' ')" "2" "a lock older than 60s is reclaimed and the backup proceeds"

# --- 12b. pre-compact.sh nudges once, then gets out of the way ----------------
PCVAULT="$(mktemp -d)"
mkdir -p "$PCVAULT/proj"
PCVAULT_LOG="$PCVAULT/proj/pclog.md"
echo "# Session Outcome" > "$PCVAULT_LOG"

pc_out="$(AI_MEM_ACTIVE_SESSION_LOG="$PCVAULT_LOG" bash "$REPO_ROOT/hooks/claude/pre-compact.sh" 2>&1)"
pc_rc=$?
is "$pc_rc" "2"                          "pre-compact hook blocks the first auto-compact"
has "$pc_out" "ai-note"                  "pre-compact hook's block message points at ai-note"
exists "${PCVAULT_LOG%.md}.precompact-nudged" "pre-compact hook leaves a one-shot marker"

succeeds 'AI_MEM_ACTIVE_SESSION_LOG="$PCVAULT_LOG" bash "$REPO_ROOT/hooks/claude/pre-compact.sh"' \
  "pre-compact hook allows every compact attempt after the first nudge"

succeeds 'env -u AI_MEM_ACTIVE_SESSION_LOG bash "$REPO_ROOT/hooks/claude/pre-compact.sh"' \
  "pre-compact hook no-ops outside a claude-start session"

# --- 13. ai-mem-lint catches broken/orphaned links -----------------------------
LINTVAULT="$(mktemp -d)"
mkdir -p "$LINTVAULT/_session_logs/lintproj" "$LINTVAULT/_projects"
cat > "$LINTVAULT/_session_logs/lintproj/lintproj-2026-08-28_10-00-00.md" <<'EOF'
---
date: 2026-08-28
project: "[[lintproj]]"
previous: ""
---
EOF
: > "$LINTVAULT/_projects/lintproj.md"

_OLD_SESSION_DIR="$AI_MEM_SESSION_DIR"
_OLD_PROJECT_DIR="$AI_MEM_PROJECT_DIR"
AI_MEM_SESSION_DIR="$LINTVAULT/_session_logs"
AI_MEM_PROJECT_DIR="$LINTVAULT/_projects"

LINTOUT="$(ai-mem-lint)"; LINTEXIT=$?
is  "$LINTEXIT" "0"                        "ai-mem-lint reports clean on a well-linked vault"
has "$LINTOUT" "ok: vault links are clean" "ai-mem-lint's clean message"

# Break it three ways: no project link, dangling previous, orphaned project note.
cat > "$LINTVAULT/_session_logs/lintproj/lintproj-2026-08-28_11-00-00.md" <<'EOF'
---
date: 2026-08-28
project: plain-text
previous: "[[does-not-exist]]"
---
EOF
: > "$LINTVAULT/_projects/orphanproj.md"

LINTOUT2="$(ai-mem-lint)"; LINTEXIT2=$?
is  "$LINTEXIT2" "1"                    "ai-mem-lint exits non-zero when issues exist"
has "$LINTOUT2" "orphaned session log"  "ai-mem-lint catches a missing project link"
has "$LINTOUT2" "dangling previous link" "ai-mem-lint catches a dangling previous link"
has "$LINTOUT2" "unreferenced project note" "ai-mem-lint catches an unreferenced project note"

AI_MEM_SESSION_DIR="$_OLD_SESSION_DIR"
AI_MEM_PROJECT_DIR="$_OLD_PROJECT_DIR"

# --- 14. ai-mem-search finds text across the vault -----------------------------
SEARCHVAULT="$(mktemp -d)"
mkdir -p "$SEARCHVAULT/_session_logs/searchproj1" "$SEARCHVAULT/_session_logs/searchproj2"
echo "the answer is 42" > "$SEARCHVAULT/_session_logs/searchproj1/searchproj1-2026-01-01_00-00-00.md"
echo "nothing relevant here" > "$SEARCHVAULT/_session_logs/searchproj2/searchproj2-2026-01-01_00-00-00.md"

_OLD_AI_MEM_ROOT="$AI_MEM_ROOT"
_OLD_SESSION_DIR2="$AI_MEM_SESSION_DIR"
_OLD_PROJECT_DIR2="$AI_MEM_PROJECT_DIR"
AI_MEM_ROOT="$SEARCHVAULT"
AI_MEM_SESSION_DIR="$SEARCHVAULT/_session_logs"
AI_MEM_PROJECT_DIR="$SEARCHVAULT/_projects"

succeeds 'ai-mem-search "the answer"'                    "ai-mem-search finds a term present in the vault"
has "$(ai-mem-search "the answer")" "searchproj1"        "ai-mem-search reports the matching file"
fails 'ai-mem-search "nope-not-here"'                     "ai-mem-search exits non-zero when nothing matches"
has "$(ai-mem-search "nope-not-here")" "no matches"       "ai-mem-search prints an explicit empty state, not silence"
fails 'ai-mem-search "the answer" searchproj2'            "ai-mem-search scoped to a project without the term finds nothing"
succeeds 'ai-mem-search "the answer" searchproj1'         "ai-mem-search scoped to the right project finds it"

mkdir -p "$SEARCHVAULT/_projects"
print -r -- $'---\ntype: ai-project-context\nproject_name: searchproj1\n---\n\n# Project Snapshot\n* **Purpose:** internal tool for testing the search layer' \
  > "$SEARCHVAULT/_projects/searchproj1.md"
echo "the answer involves [[searchproj1]] specifically" > "$SEARCHVAULT/_session_logs/searchproj2/searchproj2-2026-02-02_00-00-00.md"
HOPS_OUT="$(ai-mem-search "the answer")"
has "$HOPS_OUT" "one hop out"                       "ai-mem-search always adds a hop section when a match links out, no flag needed"
has "$HOPS_OUT" "_projects/searchproj1.md"           "ai-mem-search resolves the [[wikilink]] to its target note"
has "$HOPS_OUT" "internal tool for testing the search layer" \
  "ai-mem-search shows the linked project's Purpose as an excerpt"
HOPS_NOLINK_OUT="$(ai-mem-search "nothing relevant")"
hasnt "$HOPS_NOLINK_OUT" "one hop out" "ai-mem-search adds nothing when no match links anywhere"
fails 'ai-mem-search'                                     "ai-mem-search fails without a search term"
fails 'ai-mem-search "x" no-such-project'                 "ai-mem-search fails cleanly for an unknown project"

# --- ai-mem-search is agent-facing: correctness and bounded output ----------
# A case-sensitive default made the tool report a confident "no matches" for
# a term the vault did hold under different casing -- measured on the real
# vault, `precompact` found 0 vs 3 with -i. A false empty state is worse than
# a noisy one because it is indistinguishable from the truth.
# (deliberately avoids the word the recency test below searches for -- now
# that matching is case-insensitive, a fixture containing it would silently
# become that test's newest hit)
echo "A CamelCase Token here" > "$SEARCHVAULT/_session_logs/searchproj1/searchproj1-2026-07-07_07-00-00.md"
succeeds 'ai-mem-search camelcase' "ai-mem-search matches case-insensitively, so a casing mismatch is not a false empty state"
has "$(ai-mem-search camelcase)" "CamelCase" "ai-mem-search returns the differently-cased hit"

# -F: the caller is usually an agent passing a free-text term; regex
# metacharacters in it must match literally rather than blowing up or
# silently matching something else.
echo 'literal a.b(c) token' > "$SEARCHVAULT/_session_logs/searchproj1/searchproj1-2026-07-08_07-00-00.md"
succeeds 'ai-mem-search "a.b(c)"' "ai-mem-search treats regex metacharacters in the term literally"
fails 'ai-mem-search "a.b(X)"'    "ai-mem-search does not spuriously match a near-miss metachar term"

# Bounded output: an unbounded dump overflowed the host's tool-response cap
# on a real vault (~29k tokens for one ordinary term) and was silently
# truncated, leaving the agent unable to tell "hidden" from "absent".
BOUNDVAULT_DIR="$SEARCHVAULT/_session_logs/searchproj1"
for i in $(seq 1 12); do
  echo "boundedterm occurrence $i" > "$BOUNDVAULT_DIR/searchproj1-2026-09-$(printf '%02d' $i)_00-00-00.md"
done
BOUND_OUT="$(AI_MEM_SEARCH_LIMIT=5 ai-mem-search boundedterm)"
is "$(print -r -- "$BOUND_OUT" | grep -c '^_session_logs/')" "5" "ai-mem-search caps the number of result lines at AI_MEM_SEARCH_LIMIT"
has "$BOUND_OUT" "12 match(es)"  "ai-mem-search reports the true total even when it shows fewer"
has "$BOUND_OUT" "7 hidden"      "ai-mem-search says explicitly how many results it withheld"
has "$BOUND_OUT" "narrow with"   "ai-mem-search suggests a concrete next step when it truncates"
hasnt "$(ai-mem-search boundedterm)" "hidden" "ai-mem-search adds no truncation notice when nothing was withheld"

# The count must lead: a reader with a bounded context window needs the size
# of the result set before the result set, not after it.
has "$(print -r -- "$BOUND_OUT" | head -1)" "12 match(es)" "ai-mem-search prints the match count as the very first line"

# Paths are printed relative to a root stated once, rather than repeating an
# absolute prefix on every line (a third to a half of all output bytes on a
# real vault).
ROOTSTRIP_OUT="$(ai-mem-search "the answer")"
has   "$ROOTSTRIP_OUT" "paths below $SEARCHVAULT" "ai-mem-search states the root once in a header"
has   "$ROOTSTRIP_OUT" "_session_logs/searchproj1/" "ai-mem-search prints result paths relative to that root"
hasnt "$(print -r -- "$ROOTSTRIP_OUT" | grep '^_session_logs/')" "$SEARCHVAULT" \
  "ai-mem-search does not repeat the absolute root on every result line"

# Recency ordering: three dated hits, newest must come first, oldest last,
# and the output must contain nothing but the expected lines (regression
# guard for a real zsh bug hit while building this -- `local` re-declared on
# each loop iteration inside a piped while-loop leaked a stray "ts=<value>"
# line into stdout).
echo "needle here" > "$SEARCHVAULT/_session_logs/searchproj1/searchproj1-2026-01-01_00-00-00.md"
echo "needle here" > "$SEARCHVAULT/_session_logs/searchproj1/searchproj1-2026-06-15_12-30-00.md"
echo "needle here" > "$SEARCHVAULT/_session_logs/searchproj1/searchproj1-2026-03-10_08-00-00.md"
RECENCY_OUT="$(ai-mem-search needle)"
# Filter to just the result lines rather than indexing by absolute line
# number -- the output carries a header (count, root, separator) and an
# earlier version of this test broke purely because that header shifted the
# offsets, which says nothing about whether the sort itself works.
RECENCY_HITS="$(print -r -- "$RECENCY_OUT" | grep -E '^_session_logs/')"
has "$(print -r -- "$RECENCY_HITS" | head -1)" "2026-06-15_12-30-00" "ai-mem-search sorts the newest match first"
has "$(print -r -- "$RECENCY_HITS" | tail -1)" "2026-01-01_00-00-00" "ai-mem-search sorts the oldest match last"
hasnt "$RECENCY_OUT" "ts=" "ai-mem-search never leaks its internal sort-key variable into the output"

# Performance regression guard. The recency sort once spawned two
# subprocesses PER MATCHED LINE, which cost 25s for a common term on a real
# 486-file vault while the grep underneath it took 0.16s -- a bug every
# correctness test above passed straight through. The bound here is
# deliberately loose (this completes in well under a second once the sort is
# a single awk pass); it exists to catch a return to per-line subprocess
# spawning, not to police small changes.
PERFDIR="$SEARCHVAULT/_session_logs/searchproj2"
for i in $(seq 1 400); do
  printf 'perfneedle line one\nperfneedle line two\nperfneedle line three\n' \
    > "$PERFDIR/searchproj2-2026-10-$(printf '%02d' $(( (i % 28) + 1 )))_$(printf '%02d' $(( i % 24 )))-00-00.md"
done
PERF_START=$(date +%s)
AI_MEM_SEARCH_LIMIT=5 ai-mem-search perfneedle >/dev/null 2>&1
PERF_ELAPSED=$(( $(date +%s) - PERF_START ))
# Bound chosen by measuring both implementations at exactly this fixture
# size: the awk version takes 0.009s, the old per-line-subprocess version
# 6.9s. A 10s bound looked generous but would have let the regression pass;
# 3s keeps a ~300x margin for the correct path while still failing the
# broken one by more than 2x.
[[ "$PERF_ELAPSED" -lt 3 ]] \
  && ok  "ai-mem-search sorts a large result set without per-line subprocess spawning (${PERF_ELAPSED}s)" \
  || nok "ai-mem-search sorts a large result set without per-line subprocess spawning (took ${PERF_ELAPSED}s, expected <3s)"

AI_MEM_ROOT="$_OLD_AI_MEM_ROOT"
AI_MEM_SESSION_DIR="$_OLD_SESSION_DIR2"
AI_MEM_PROJECT_DIR="$_OLD_PROJECT_DIR2"

# --- private helpers must survive a Claude Code shell snapshot -----------------
# Claude Code snapshots the interactive shell and replays it for every
# agent-run command, dropping every function whose name starts with a single
# underscore (its filter targets zsh's ~1000 `_git`-style completion
# functions). A helper named _ai_mem_x is therefore simply absent in every
# agent shell, and its public caller fails silently rather than loudly.
# Two-underscore names are kept, so assert the naming rather than trusting it.
SINGLE_US_DEFS="$(grep -rhoE '^_[a-zA-Z][a-zA-Z0-9_]*\(\)' "$REPO_ROOT/shell/" || true)"
is "$SINGLE_US_DEFS" "" "no shell/ helper is defined with a single leading underscore (a snapshot would drop it)"

# The guard must convert that absence into a loud failure, because the natural
# behavior is a lie: HEAD does not move, so the old code printed
# "nothing to commit" and exited 0 while backing up nothing.
GUARD_OUT="$(AI_MEM_ROOT="$NOTEVAULT" zsh -c '
  source "'"$REPO_ROOT"'/shell/ai-mem.zsh"
  unfunction __ai_mem_vault_backup
  ai-mem-vault-backup
' 2>&1 || true)"
has "$GUARD_OUT" "is not defined" "ai-mem-vault-backup fails loudly when its helper was dropped from the shell"
hasnt "$GUARD_OUT" "nothing to commit" "ai-mem-vault-backup does not report a clean tree when it could not run at all"
fails 'AI_MEM_ROOT="'"$NOTEVAULT"'" zsh -c "
  source \"'"$REPO_ROOT"'/shell/ai-mem.zsh\"
  unfunction __ai_mem_vault_backup
  ai-mem-vault-backup
"' "ai-mem-vault-backup exits non-zero when its helper was dropped"

# --- summary ------------------------------------------------------------------
print -r -- "----"
print -r -- "$(( PASS + FAIL )) tests, $PASS passed, $FAIL failed"
(( FAIL == 0 ))
