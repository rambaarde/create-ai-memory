# === AI CLI + Obsidian memory ===
# Portable, agent-agnostic session memory. Source this from ~/.zshrc after
# exporting AI_MEM_ROOT to point at your vault. Zsh-only (uses print -r, ${(s)},
# and associative arrays). Add a new agent by defining _ai_adapter_<name> in adapters.zsh and
# listing it in AI_MEM_AGENTS; a matching <name>-start function is generated.

# Directory holding this module, used to source sibling files.
AI_MEM_HOME="${0:A:h}"

# Where the shipped example notes and templates live, used to auto-scaffold a
# vault on first use so install.sh is optional (plugin-manager installs work).
AI_MEM_TEMPLATE_SRC="${AI_MEM_HOME:h}/vault-template"

# Vault root. Override in ~/.zshrc; defaults to a hidden dir under $HOME.
: "${AI_MEM_ROOT:=$HOME/.ai-memory/_Ai_Memory}"
if [[ -d "$AI_MEM_ROOT" ]]; then
    AI_MEM_ROOT="$(cd "$AI_MEM_ROOT" && pwd -P)"
fi
export AI_MEM_ROOT
export AI_MEM_GLOBAL="$AI_MEM_ROOT/_Global_Profile.md"
export AI_MEM_STANDARDS="$AI_MEM_ROOT/_Standards.md"
export AI_MEM_PROJECT_DIR="$AI_MEM_ROOT/_projects"
export AI_MEM_SESSION_DIR="$AI_MEM_ROOT/_session_logs"

_ai_mem_guard() {
    local path="${1:-}"
    case "$path" in
        "$AI_MEM_ROOT"|"$AI_MEM_ROOT"/*) return 0 ;;
        *)
            echo "Refusing to touch non-memory path: $path"
            return 1
            ;;
    esac
}

# Read a vault note only when it exists inside the memory root.
_ai_mem_note_contents() {
    local path="${1:-}"
    if [[ -z "$path" || ! -f "$path" ]]; then
        return 0
    fi

    _ai_mem_guard "$path" || return 1
    print -r -- "$(<"$path")"
}

_ai_mem_resolve_project() {
    # Prefer the git repo we are actually standing in. Otherwise `cd`-ing between
    # projects in one shell keeps a stale AI_MEM_ACTIVE_PROJECT pinned, so a later
    # claude-start writes its log under the wrong project's folder.
    local git_root=""
    git_root="$(git rev-parse --show-toplevel 2>/dev/null)" || true
    if [[ -n "$git_root" ]]; then
        basename "$git_root"
        return 0
    fi

    # Outside any repo, fall back to the active session's project, then the cwd.
    if [[ -n "${AI_MEM_ACTIVE_PROJECT:-}" ]]; then
        print -r -- "$AI_MEM_ACTIVE_PROJECT"
        return 0
    fi

    basename "$PWD"
}

_ai_mem_project_session_dir() {
    local project_name="${1:-}"
    if [[ -z "$project_name" ]]; then
        project_name="$(_ai_mem_resolve_project)"
    fi

    print -r -- "$AI_MEM_SESSION_DIR/$project_name"
}

_ai_mem_graphify_repo_root() {
    local git_root=""
    git_root="$(git rev-parse --show-toplevel 2>/dev/null)" || true
    if [[ -n "$git_root" ]]; then
        print -r -- "$git_root"
    else
        print -r -- "$PWD"
    fi
}

_ai_mem_graphify_context() {
    local repo_root="$(_ai_mem_graphify_repo_root)"
    local graph_root="$repo_root/graphify-out"
    local graph_json="$graph_root/graph.json"
    local graph_report="$graph_root/GRAPH_REPORT.md"
    local graph_wiki="$graph_root/wiki/index.md"

    if [[ ! -f "$graph_json" ]]; then
        return 0
    fi

    export AI_GRAPHIFY_ROOT="$graph_root"
    export AI_GRAPHIFY_GRAPH_JSON="$graph_json"

    printf '%s\n' \
        "Graphify context:" \
        "- Knowledge graph available at: $graph_root" \
        "- Use graphify query/path/explain before raw grep for codebase or architecture questions." \
        "- Read the graph report for broad overviews: $graph_report"

    if [[ -f "$graph_wiki" ]]; then
        printf '%s\n' "- Use the wiki index for broad navigation: $graph_wiki"
    fi
}

# Returns the newest saved session log for the current project.
# The active run gets a fresh log, so this only feeds carryover context.
_ai_mem_latest_session_log() {
    local project_name="${1:-}"
    if [[ -z "$project_name" ]]; then
        project_name="$(_ai_mem_resolve_project)"
    fi

    local latest=""
    local project_session_dir
    project_session_dir="$(_ai_mem_project_session_dir "$project_name")"

    latest="$(find "$project_session_dir" -maxdepth 1 -type f -name "${project_name}-*.md" 2>/dev/null | sort | tail -n 1)" || true
    if [[ -z "$latest" ]]; then
        latest="$(find "$AI_MEM_SESSION_DIR" -maxdepth 1 -type f -name "${project_name}-*.md" 2>/dev/null | sort | tail -n 1)" || true
    fi
    if [[ -n "$latest" ]]; then
        _ai_mem_guard "$latest" || return 1
        print -r -- "$latest"
    fi
}

# Copy the shipped profile, standards, and templates into the vault on first use.
# Idempotent and additive: it never overwrites a file the user already has, so a
# plugin-manager install (source only, no install.sh) still gets a working vault.
_ai_mem_ensure_vault() {
    [[ -d "$AI_MEM_TEMPLATE_SRC" ]] || return 0
    mkdir -p "$AI_MEM_PROJECT_DIR" "$AI_MEM_SESSION_DIR" "$AI_MEM_ROOT/_lessons"
    local rel
    for rel in _Global_Profile.md _Standards.md \
               _projects/_project_template.md _session_logs/_session_template.md \
               _lessons/_lesson_template.md; do
        local src="$AI_MEM_TEMPLATE_SRC/$rel" dst="$AI_MEM_ROOT/$rel"
        if [[ -f "$src" && ! -f "$dst" ]]; then
            _ai_mem_guard "$dst" || return 1
            cp "$src" "$dst"
        fi
    done
}

_ai_mem_prepare_session() {
    local project_name="${1:-}"
    if [[ -z "$project_name" ]]; then
        project_name="$(_ai_mem_resolve_project)"
    fi

    _ai_mem_ensure_vault || return 1

    local project_note="$AI_MEM_PROJECT_DIR/${project_name}.md"
    local project_session_dir
    project_session_dir="$(_ai_mem_project_session_dir "$project_name")"
    local previous_session_note=""
    previous_session_note="$(_ai_mem_latest_session_log "$project_name")" || return 1
    local session_note="$project_session_dir/${project_name}-$(date +%Y-%m-%d_%H-%M-%S).md"

    _ai_mem_guard "$project_note" || return 1
    _ai_mem_guard "$session_note" || return 1

    mkdir -p "$AI_MEM_PROJECT_DIR" "$AI_MEM_SESSION_DIR" "$project_session_dir"

    if [[ ! -f "$project_note" ]]; then
        PROJECT_NAME="$project_name" perl -0pe 's/\[Insert Project Name\]/$ENV{PROJECT_NAME}/g' \
            "$AI_MEM_PROJECT_DIR/_project_template.md" > "$project_note"
    fi

    local prev_link=""
    if [[ -n "$previous_session_note" ]]; then
        prev_link="[[${previous_session_note:t:r}]]"
    fi

    SESSION_DATE="$(date +%Y-%m-%d)" PROJECT_NAME="$project_name" PREV_LINK="$prev_link" perl -0pe 's/\{\{date\}\}/$ENV{SESSION_DATE}/g; s/\{\{project_name\}\}/$ENV{PROJECT_NAME}/g; s/\{\{previous_session_link\}\}/$ENV{PREV_LINK}/g' \
        "$AI_MEM_SESSION_DIR/_session_template.md" > "$session_note"

    export AI_MEM_ACTIVE_PROJECT="$project_name"
    export AI_MEM_PREVIOUS_SESSION_LOG="$previous_session_note"
    export AI_MEM_ACTIVE_SESSION_LOG="$session_note"

    print -r -- "$project_name|$project_note|$previous_session_note|$session_note"
}

# Pull one "* **Label:** value" bullet out of a session log's fixed
# "# Session Outcome" section. Reads the log directly — no separate file is
# ever written, so there is nothing extra sitting in the vault.
_ai_mem_session_field() {
    local file="$1" label="$2" value
    [[ -f "$file" ]] || return 0
    value="$(grep -m1 -E "^\* \*\*${label}:\*\*" "$file" | sed -E "s|^\* \*\*${label}:\*\*[[:space:]]*||")"
    # An untouched template still has its literal [bracket] placeholder — that
    # is not real content, so treat it the same as an empty field.
    [[ "$value" == \[*\] ]] && return 0
    print -r -- "$value"
}

# Defensive cap so one unusually long freeform bullet can't blow up the
# prompt. Never triggers for the template's intended single-line bullets.
_ai_mem_cap_field() {
    local text="$1" cap="${2:-500}" source_ref="$3"
    if (( ${#text} > cap )); then
        print -r -- "${text[1,$cap]}… (truncated, ${#text} chars total — see $source_ref)"
    else
        print -r -- "$text"
    fi
}

_ai_mem_context_prompt() {
    local project_note="${1:-}"
    local previous_session_note="${2:-}"
    local session_note="${3:-}"
    local previous_session_label="(none yet)"
    local previous_session_block="- Latest prior session log: (none yet)"

    if [[ -n "$previous_session_note" ]]; then
        previous_session_label="$previous_session_note"

        local summary decisions blockers next
        summary="$(_ai_mem_session_field "$previous_session_note" 'High-Level Summary')"
        decisions="$(_ai_mem_session_field "$previous_session_note" 'Important Decisions')"
        blockers="$(_ai_mem_session_field "$previous_session_note" 'Constraints / Blockers')"
        next="$(_ai_mem_session_field "$previous_session_note" 'Next Step')"

        if [[ -z "${AI_MEM_NO_DIGEST:-}" && ( -n "$summary" || -n "$decisions" || -n "$blockers" || -n "$next" ) ]]; then
            [[ -n "$summary" ]] || summary="—"
            [[ -n "$decisions" ]] || decisions="—"
            [[ -n "$blockers" ]] || blockers="—"
            [[ -n "$next" ]] || next="—"

            previous_session_block="- Latest prior session ($previous_session_note), summarized below:"
            previous_session_block+=$'\n'"* **Summary:** $(_ai_mem_cap_field "$summary" 500 "$previous_session_note")"
            previous_session_block+=$'\n'"* **Decisions:** $(_ai_mem_cap_field "$decisions" 500 "$previous_session_note")"
            previous_session_block+=$'\n'"* **Blockers:** $(_ai_mem_cap_field "$blockers" 500 "$previous_session_note")"
            previous_session_block+=$'\n'"* **Next:** $(_ai_mem_cap_field "$next" 500 "$previous_session_note")"
        else
            previous_session_block="- Latest prior session log: $previous_session_label"
            previous_session_block+=$'\n'
            previous_session_block+="Read the latest prior session log for continuity before acting. Do not load the full session history unless the user asks for it."
        fi
    fi

    cat <<EOF
Read these notes before doing anything else:
- Global profile:
$(_ai_mem_note_contents "$AI_MEM_GLOBAL")

- Standards:
$(_ai_mem_note_contents "$AI_MEM_STANDARDS")

- Project context: $project_note
$previous_session_block
- Active session log: $session_note

Use the Obsidian vault as the persistent memory layer.
Treat the global profile and standards note as the shared baseline for every run.
Keep durable preferences and project facts in the vault, and keep the active session log updated with decisions, blockers, and next steps.
For anything not covered above -- a decision from further back, a different project, a health check on the vault's links -- run \`ai-mem-search <term> [project]\` or \`ai-mem-lint\` yourself; both are plain shell commands already on PATH.
When you hit a mistake, decision, or solution worth remembering across projects (not just this one), run \`ai-lesson <topic-slug> <problem> <solution>\` -- e.g. \`ai-lesson rate-limiting "a fixed-window limiter kept losing bursts of legitimate traffic" "switched to a token bucket, which absorbs bursts correctly"\`. It appends a dated Problem/Solution entry to a cross-project note at _lessons/<topic-slug>.md; ai-mem-search already covers it.
EOF
}

# Mark the current shell as having loaded AI vault context for the active repo.
_ai_mem_mark_commit_ready() {
    local project_name="${1:-}"
    local source="${2:-ai-context}"
    local ready_dir="$AI_MEM_SESSION_DIR/.context-ready"
    local ready_file
    local token

    if [[ -z "$project_name" ]]; then
        project_name="$(_ai_mem_resolve_project)"
    fi

    ready_file="$ready_dir/${project_name}.token"
    _ai_mem_guard "$ready_file" || return 1

    mkdir -p "$ready_dir"

    token="${EPOCHSECONDS:-$(date +%s)}-$$-$RANDOM"
    {
        printf '%s\n' "$token"
        printf 'source=%s\n' "$source"
        printf 'project=%s\n' "$project_name"
        printf 'loaded_at=%s\n' "$(date +%Y-%m-%dT%H:%M:%S%z)"
    } > "$ready_file"

    export AI_MEM_CONTEXT_READY=1
    export AI_MEM_CONTEXT_TOKEN="$token"
    export AI_MEM_CONTEXT_SOURCE="$source"
    export AI_MEM_CONTEXT_READY_FILE="$ready_file"
    export AI_MEM_CONTEXT_PROJECT="$project_name"
}

# Re-export the active-session vars in the CALLER's shell. _ai_mem_prepare_session
# exports them too, but it is always invoked inside $(...) command substitution, so
# those exports die in the subshell and never reach the launched client or its hooks
# (Claude's SessionStart/Stop hooks gate on AI_MEM_ACTIVE_SESSION_LOG).
_ai_mem_export_active() {
    export AI_MEM_ACTIVE_PROJECT="${1:-}"
    export AI_MEM_PREVIOUS_SESSION_LOG="${2:-}"
    export AI_MEM_ACTIVE_SESSION_LOG="${3:-}"
}

ai-start() {
    local project_name="${1:-}"
    shift || true

    local resolved
    resolved="$(_ai_mem_prepare_session "$project_name")" || return 1

    local active_project project_note previous_session_note session_note
    IFS='|' read -r active_project project_note previous_session_note session_note <<< "$resolved"
    _ai_mem_export_active "$active_project" "$previous_session_note" "$session_note"

    local previous_session_label="(none yet)"
    if [[ -n "$previous_session_note" ]]; then
        previous_session_label="$previous_session_note"
    fi

    cat <<EOF
AI memory prepared
- Project: $active_project
- Global: $AI_MEM_GLOBAL
- Project note: $project_note
- Latest prior session log: $previous_session_label
- Active session log: $session_note
EOF
}

ai-context() {
    local project_name="${1:-}"
    local resolved project_note previous_session_note session_note
    resolved="$(_ai_mem_prepare_session "$project_name")" || return 1

    local active_project
    IFS='|' read -r active_project project_note previous_session_note session_note <<< "$resolved"
    _ai_mem_export_active "$active_project" "$previous_session_note" "$session_note"

    _ai_mem_mark_commit_ready "$active_project" "ai-context" || return 1
    _ai_mem_context_prompt "$project_note" "$previous_session_note" "$session_note"
}

# Yes/no helper used by the session-mode prompts. Empty answer counts as no.
_ai_yesno() {
    local prompt="$1" reply
    while true; do
        read -r "reply?${prompt} [y/N] "
        case "$reply" in
            [Yy]*) return 0 ;;
            [Nn]*|"") return 1 ;;
            *) echo "Answer y or n." ;;
        esac
    done
}

# Optional per-session skills, defined by you. Each entry maps a short key to
#   "yes/no prompt::instruction block injected when the skill is enabled"
# and AI_MEM_SKILL_ORDER sets the ask order. Both are empty by default, so a
# stock install asks nothing and injects nothing. Define your own in ~/.zshrc
# BEFORE sourcing this file, e.g.:
#   typeset -gA AI_MEM_SKILLS
#   AI_MEM_SKILLS[terse]='Use terse output this session?::Respond tersely; drop filler and hedging.'
#   AI_MEM_SKILLS[design]='Use strict UI design discipline this session?::Apply careful frontend/UI design review to any design work.'
#   AI_MEM_SKILL_ORDER=(terse design)
# The chosen block is injected into every launched agent, so a session's skills
# persist as instructions for that whole run.
typeset -gA AI_MEM_SKILLS
typeset -ga AI_MEM_SKILL_ORDER

# Ask which optional skills to enable. Each is independent; answer y/n per skill.
# Echoes a pipe-joined list of chosen keys; empty means a plain session.
_ai_session_modes_pick() {
    local modes=() key prompt
    for key in "${AI_MEM_SKILL_ORDER[@]}"; do
        prompt="${AI_MEM_SKILLS[$key]%%::*}"
        [[ -n "$prompt" ]] || continue
        _ai_yesno "$prompt" && modes+=("$key")
    done
    print -r -- "${(j:|:)modes}"
}

# Build the instruction block to inject from the chosen skill keys.
_ai_session_modes_instructions() {
    local modes="$1" block="" m text
    for m in ${(s:|:)modes}; do
        text="${AI_MEM_SKILLS[$m]#*::}"
        [[ -n "$text" ]] && block+="$text"$'\n\n'
    done
    print -r -- "${block%$'\n\n'}"
}

# Start an AI client with the shared memory block and the chosen session mode.
_ai_session_start() {
    local launcher="${1:-}"
    if (( $# > 0 )); then
        shift
    fi

    local session_prompt="${*:-}"

    # Fail fast with a clear message if the agent's CLI is missing, before a
    # session log is created. Cursor is exempt: its adapter falls back to opening
    # the app when the `cursor` CLI is absent.
    if [[ "$launcher" != cursor ]] && ! command -v "$launcher" >/dev/null 2>&1; then
        echo "ai-memory: '$launcher' CLI not found on PATH. Install it, or drop it from AI_MEM_AGENTS." >&2
        return 1
    fi

    local resolved
    resolved="$(_ai_mem_prepare_session)" || return 1

    local active_project project_note previous_session_note session_note
    IFS='|' read -r active_project project_note previous_session_note session_note <<< "$resolved"
    _ai_mem_export_active "$active_project" "$previous_session_note" "$session_note"

    local session_modes mode_block
    session_modes="$(_ai_session_modes_pick)" || return 1
    mode_block="$(_ai_session_modes_instructions "$session_modes")"

    # AI_SESSION_MODES carries the chosen skill keys; AI_SESSION_STYLE_LABEL
    # carries the assembled instruction block for launchers to inject.
    export AI_SESSION_MODES="$session_modes"
    export AI_SESSION_STYLE_LABEL="$mode_block"

    local memory_prompt
    memory_prompt="$(_ai_mem_context_prompt "$project_note" "$previous_session_note" "$session_note")"

    local graphify_context=""
    graphify_context="$(_ai_mem_graphify_context)" || return 1
    if [[ -n "$graphify_context" ]]; then
        memory_prompt+=$'\n\n'
        memory_prompt+="$graphify_context"
    fi

    if [[ -n "$mode_block" ]]; then
        memory_prompt+=$'\n\n'
        memory_prompt+="$mode_block"
    fi
    if [[ -n "$session_prompt" ]]; then
        memory_prompt+=$'\n\n'
        memory_prompt+="$session_prompt"
    fi

    _ai_mem_mark_commit_ready "$active_project" "$launcher-start" || return 1

    # Dispatch to the agent adapter. Each adapter is passed the assembled
    # memory prompt, the mode block, and any remaining CLI args (e.g. files to
    # open). Adapters live in adapters.zsh; add one to support a new agent.
    if ! typeset -f "_ai_adapter_$launcher" >/dev/null; then
        echo "Unknown AI launcher: $launcher (define _ai_adapter_$launcher in adapters.zsh)" >&2
        return 1
    fi
    "_ai_adapter_$launcher" "$memory_prompt" "$mode_block" "$@"
}

# Load the agent adapters, then generate a <name>-start launcher for every
# registered agent that has a matching adapter. Users extend by appending to
# AI_MEM_AGENTS (space-separated) and defining _ai_adapter_<name>.
source "$AI_MEM_HOME/adapters.zsh"
: "${AI_MEM_AGENTS:=claude codex gemini cursor opencode}"
for _ai_agent in ${(z)AI_MEM_AGENTS}; do
    if typeset -f "_ai_adapter_$_ai_agent" >/dev/null; then
        # A same-named alias (e.g. from another plugin) makes zsh refuse to
        # `eval` a function definition of that name at all -- "defining
        # function based on alias", parse error near '()'. Clear it first;
        # the function this defines is what should win.
        unalias "${_ai_agent}-start" 2>/dev/null
        eval "${_ai_agent}-start() { _ai_session_start ${_ai_agent} \"\$@\"; }"
    fi
done
unset _ai_agent

_ai_mem_current_project() {
    _ai_mem_resolve_project
}

_ai_mem_today_session_log() {
    local project_name="${1:-}"
    if [[ -z "$project_name" ]]; then
        project_name="$(_ai_mem_resolve_project)"
    fi

    _ai_mem_ensure_vault || return 1

    local today
    today="$(date +%Y-%m-%d)"
    local project_session_dir
    project_session_dir="$(_ai_mem_project_session_dir "$project_name")"

    if [[ -n "${AI_MEM_ACTIVE_SESSION_LOG:-}" && -f "$AI_MEM_ACTIVE_SESSION_LOG" ]]; then
        case "$AI_MEM_ACTIVE_SESSION_LOG" in
            "$AI_MEM_ROOT"|"$AI_MEM_ROOT"/*)
                if [[ "$AI_MEM_ACTIVE_SESSION_LOG" == "$project_session_dir/${project_name}-${today}_"* ]]; then
                    print -r -- "$AI_MEM_ACTIVE_SESSION_LOG"
                    return 0
                fi
                ;;
        esac
    fi

    local latest=""
    latest="$(find "$project_session_dir" -maxdepth 1 -type f -name "${project_name}-${today}_*.md" 2>/dev/null | sort | tail -n 1)" || true
    if [[ -z "$latest" ]]; then
        latest="$(find "$AI_MEM_SESSION_DIR" -maxdepth 1 -type f -name "${project_name}-${today}_*.md" 2>/dev/null | sort | tail -n 1)" || true
    fi
    if [[ -n "$latest" ]]; then
        _ai_mem_guard "$latest" || return 1
        print -r -- "$latest"
        return 0
    fi

    local session_note="$project_session_dir/${project_name}-${today}_$(date +%H-%M-%S).md"
    _ai_mem_guard "$session_note" || return 1
    mkdir -p "$project_session_dir"
    SESSION_DATE="$today" PROJECT_NAME="$project_name" perl -0pe 's/\{\{date\}\}/$ENV{SESSION_DATE}/g; s/\{\{project_name\}\}/$ENV{PROJECT_NAME}/g' \
        "$AI_MEM_SESSION_DIR/_session_template.md" > "$session_note"
    print -r -- "$session_note"
}

codex-note() {
    ai-note "$@"
}

ai-note() {
    local note_text="${*:-}"
    if [[ -z "$note_text" ]]; then
        echo "Usage: ai-note <note text>"
        return 1
    fi

    local project_name session_note timestamp
    project_name="$(_ai_mem_current_project)" || return 1
    session_note="$(_ai_mem_today_session_log "$project_name")" || return 1
    timestamp="$(date +%H:%M)"

    _ai_mem_guard "$session_note" || return 1

    if ! grep -q '^### Live Notes' "$session_note" 2>/dev/null; then
        printf '\n### Live Notes\n' >> "$session_note"
    fi

    printf '\n- %s %s\n' "$timestamp" "$note_text" >> "$session_note"
    printf 'Appended to %s\n' "$session_note"
    printf 'Appended to %s\n' "$session_note"
}

codex-lesson() {
    ai-lesson "$@"
}

# Cross-project memory: a mistake, decision, or reusable solution, filed under
# a topic instead of a single project's session log. One flat file per topic
# (ADR/postmortem shape, not a full wiki) so ai-mem-search already covers it
# for free -- no new search path, no taxonomy to maintain.
ai-lesson() {
    local topic="${1:-}" problem="${2:-}" solution="${3:-}"
    if [[ -z "$topic" || -z "$problem" || -z "$solution" ]]; then
        echo "Usage: ai-lesson <topic-slug> <problem> <solution>"
        return 1
    fi

    local slug
    slug="$(print -r -- "$topic" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g')"
    if [[ -z "$slug" ]]; then
        echo "ai-lesson: topic slug must contain at least one letter or digit"
        return 1
    fi

    local project_name lesson_file timestamp
    project_name="$(_ai_mem_current_project)" || return 1
    lesson_file="$AI_MEM_ROOT/_lessons/${slug}.md"
    timestamp="$(date '+%Y-%m-%d %H:%M')"

    _ai_mem_guard "$lesson_file" || return 1

    if [[ ! -f "$lesson_file" ]]; then
        mkdir -p "$AI_MEM_ROOT/_lessons"
        local lesson_template="$AI_MEM_ROOT/_lessons/_lesson_template.md"
        if [[ -f "$lesson_template" ]]; then
            TOPIC="$slug" perl -0pe 's/\{\{topic\}\}/$ENV{TOPIC}/g' "$lesson_template" \
                | awk '/^# /{print; exit} {print}' > "$lesson_file"
        else
            printf -- '---\ntype: ai-lesson\ntopic: %s\n---\n\n# %s\n' "$slug" "$slug" > "$lesson_file"
        fi
    fi

    printf -- '\n## %s [[%s]]\n\n### Problem\n%s\n\n### Solution\n%s\n' \
        "$timestamp" "$project_name" "$problem" "$solution" >> "$lesson_file"
    printf 'Appended to %s\n' "$lesson_file"
}
# Lints the vault's links: session logs missing a project wikilink, previous
# links pointing at a note that no longer exists, and project notes nothing
# links back to. Pure grep/find -- no new dependency, catches exactly the
# "isolated dots in Graph View" class of problem before you have to notice it
# by eye.
ai-mem-lint() {
    local issues=0 f label target found

    while IFS= read -r -d '' f; do
        [[ "${f:t}" == "_session_template.md" ]] && continue

        if ! grep -qm1 -E '^project:.*\[\[.*\]\]' "$f" 2>/dev/null; then
            print -r -- "orphaned session log (no project link): $f"
            (( issues++ ))
        fi

        label="$(grep -m1 '^previous:' "$f" 2>/dev/null)"
        if [[ "$label" == *'[['* ]]; then
            target="${label#*\[\[}"
            target="${target%%\]\]*}"
            found="$(find "${f:h}" -maxdepth 1 -name "${target}.md" -print -quit 2>/dev/null)"
            if [[ -z "$found" ]]; then
                print -r -- "dangling previous link: $f -> [[${target}]] (not found)"
                (( issues++ ))
            fi
        fi
    done < <(find "$AI_MEM_SESSION_DIR" -maxdepth 2 -name "*.md" -print0 2>/dev/null)

    while IFS= read -r -d '' f; do
        [[ "${f:t}" == "_project_template.md" ]] && continue
        local pname="${f:t:r}"
        if ! grep -rq -- "\[\[${pname}\]\]" "$AI_MEM_SESSION_DIR" 2>/dev/null; then
            print -r -- "unreferenced project note (no session log links to it): $f"
            (( issues++ ))
        fi
    done < <(find "$AI_MEM_PROJECT_DIR" -maxdepth 1 -name "*.md" -print0 2>/dev/null)

    if (( issues == 0 )); then
        print -r -- "ok: vault links are clean"
    else
        print -r -- "$issues issue(s) found"
    fi
    return $(( issues > 0 ? 1 : 0 ))
}

# Full-text search across the vault. Plain grep -- no new dependency, and at
# vault scale (a personal notes collection, not a codebase) there is no real
# performance reason to reach for anything faster.
ai-mem-search() {
    local term="${1:-}"
    local project="${2:-}"
    if [[ -z "$term" ]]; then
        echo "Usage: ai-mem-search <term> [project]"
        return 1
    fi

    local search_root="$AI_MEM_ROOT"
    if [[ -n "$project" ]]; then
        search_root="$(_ai_mem_project_session_dir "$project")"
        if [[ ! -d "$search_root" ]]; then
            print -r -- "ai-mem-search: no session logs for project '$project'"
            return 1
        fi
    fi

    local raw
    raw="$(grep -rn --exclude-dir=.git --exclude='_session_template.md' --exclude='_project_template.md' --exclude='_lesson_template.md' -- "$term" "$search_root" 2>/dev/null)"

    if [[ -z "$raw" ]]; then
        print -r -- "no matches for '$term' in $search_root"
        return 1
    fi

    # Newest-first: for a time-series log the most recent match is usually the
    # relevant one, so a large result set stays usable at a glance even without
    # ranking. Sort key is the YYYY-MM-DD_HH-MM-SS embedded in the filename;
    # lines with no such timestamp (e.g. _Global_Profile.md) sort last.
    local sorted ts
    sorted="$(print -r -- "$raw" | while IFS= read -r line; do
        ts="$(print -r -- "$line" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2}' | head -1)"
        print -r -- "${ts:-0000-00-00_00-00-00}|${line}"
    done | sort -r | cut -d'|' -f2-)"

    print -r -- "$sorted"
    print -r -- "--"
    print -r -- "$(print -r -- "$raw" | wc -l | tr -d ' ') match(es) for '$term'"
}
