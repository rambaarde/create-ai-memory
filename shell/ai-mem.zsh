# === AI CLI + Obsidian memory ===
# Portable, agent-agnostic session memory. Source this from ~/.zshrc after
# exporting AI_MEM_ROOT to point at your vault. Zsh-only (uses print -r, ${(s)},
# select). Add a new agent by defining _ai_adapter_<name> in adapters.zsh and
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
    mkdir -p "$AI_MEM_PROJECT_DIR" "$AI_MEM_SESSION_DIR"
    local rel
    for rel in _Global_Profile.md _Standards.md \
               _projects/_project_template.md _session_logs/_session_template.md; do
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

    SESSION_DATE="$(date +%Y-%m-%d)" PROJECT_NAME="$project_name" perl -0pe 's/\{\{date\}\}/$ENV{SESSION_DATE}/g; s/\{\{project_name\}\}/$ENV{PROJECT_NAME}/g' \
        "$AI_MEM_SESSION_DIR/_session_template.md" > "$session_note"

    export AI_MEM_ACTIVE_PROJECT="$project_name"
    export AI_MEM_PREVIOUS_SESSION_LOG="$previous_session_note"
    export AI_MEM_ACTIVE_SESSION_LOG="$session_note"

    print -r -- "$project_name|$project_note|$previous_session_note|$session_note"
}

_ai_mem_context_prompt() {
    local project_note="${1:-}"
    local previous_session_note="${2:-}"
    local session_note="${3:-}"
    local previous_session_label="(none yet)"

    if [[ -n "$previous_session_note" ]]; then
        previous_session_label="$previous_session_note"
    fi

    cat <<EOF
Read these notes before doing anything else:
- Global profile:
$(_ai_mem_note_contents "$AI_MEM_GLOBAL")

- Standards:
$(_ai_mem_note_contents "$AI_MEM_STANDARDS")

- Project context: $project_note
- Latest prior session log: $previous_session_label
- Active session log: $session_note

Use the Obsidian vault as the persistent memory layer.
Treat the global profile and standards note as the shared baseline for every run.
Read the latest prior session log for continuity before acting. Do not load the full session history unless the user asks for it.
Keep durable preferences and project facts in the vault, and keep the active session log updated with decisions, blockers, and next steps.
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
}
