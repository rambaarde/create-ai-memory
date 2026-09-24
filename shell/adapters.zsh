# Agent launch adapters for ai-mem.
#
# One function per agent: __ai_adapter_<name>. It receives:
#   $1  memory_prompt  — assembled vault context + session-mode block
#   $2  mode_block      — just the session-mode instructions (may be empty)
#   $3… extra CLI args  — anything passed to <name>-start (e.g. files to open)
#
# Add a new agent (opencode, aider, …) by defining __ai_adapter_<name> here and
# listing <name> in AI_MEM_AGENTS (see ai-mem.zsh). No core edits needed.

# Codex: --add-dir grants read access to the vault; prompt is positional.
__ai_adapter_codex() {
    local memory_prompt="$1"
    codex --add-dir "$AI_MEM_ROOT" "$memory_prompt"
}

# Claude Code: --add-dir is variadic, so the prompt must come FIRST or it gets
# swallowed as a bogus directory and Claude starts with no initial prompt.
__ai_adapter_claude() {
    local memory_prompt="$1" mode_block="$2"
    if [[ -n "$mode_block" ]]; then
        claude "$memory_prompt" --add-dir "$AI_MEM_ROOT" --append-system-prompt "$mode_block"
    else
        claude "$memory_prompt" --add-dir "$AI_MEM_ROOT"
    fi
}

# Gemini CLI: --include-directories for vault access, -i for the initial prompt.
__ai_adapter_gemini() {
    local memory_prompt="$1"
    gemini --include-directories "$AI_MEM_ROOT" -i "$memory_prompt"
}

# Antigravity (agy): Google's successor to the Gemini CLI, installed as the
# `antigravity-cli` cask with `agy` as its binary. It takes --add-dir like
# codex and -i for an interactive initial prompt like the Gemini CLI did, so
# the vault is granted the same way and the session still opens interactively
# rather than printing one answer and exiting.
#
# --prompt on agy is an alias for --print, which runs ONE turn and exits. That
# is the wrong verb here: a launcher exists to start a session the developer
# keeps working in, so -i (--prompt-interactive) is the correct flag.
__ai_adapter_agy() {
    local memory_prompt="$1"
    shift 2>/dev/null || true
    agy --add-dir "$AI_MEM_ROOT" -i "$memory_prompt"
}

# Cursor ships two entry points. `cursor-agent` is the CLI and takes the
# prompt positionally, so it gets the vault context like every other agent.
# `cursor` is the GUI, which has no prompt path -- launching it drops the
# memory prompt entirely, so it is a fallback rather than the target.
#
# Either way the session's skill choices are persisted as a managed
# always-apply rule, rewritten each launch and cleared when nothing is
# selected: cursor-agent has no --append-system-prompt equivalent, so the
# rule file is the only channel for the mode block.
#
# --workspace is deliberately not passed. It sets the working directory,
# which already is the project being worked on, and it is not an --add-dir
# equivalent -- the vault reaches Cursor through the absolute note paths
# inlined in the prompt.
__ai_adapter_cursor() {
    local memory_prompt="$1" mode_block="$2"
    shift 2
    local cursor_rule="$HOME/.cursor/rules/_ai-session.mdc"
    if [[ -n "$mode_block" ]]; then
        mkdir -p "$HOME/.cursor/rules"
        {
            print -r -- "---"
            print -r -- "description: Active AI session skills (managed by cursor-start; rewritten each launch, cleared when none chosen)."
            print -r -- "globs:"
            print -r -- "alwaysApply: true"
            print -r -- "---"
            print -r --
            print -r -- "$mode_block"
        } > "$cursor_rule"
    else
        rm -f "$cursor_rule"
    fi
    if command -v cursor-agent >/dev/null 2>&1; then
        cursor-agent "$memory_prompt" "$@"
    elif command -v cursor >/dev/null 2>&1; then
        cursor "$@"
    else
        open -a Cursor
    fi
}

# opencode (sst/opencode): the TUI seeds its first message from --prompt. It has
# no --add-dir, so vault access rides on the inlined profile/standards in the
# prompt plus the absolute note paths the agent can read on demand.
__ai_adapter_opencode() {
    local memory_prompt="$1"
    opencode --prompt "$memory_prompt"
}

# omp (Oh My Pi): grant the TUI direct vault access, keep the memory context as
# the opening message, and put selected session skills in OMP's system prompt
# channel so they have higher authority than ordinary prompt text. Do not use
# -p/--print here; that is one-shot mode.
__ai_omp_model_selector() {
    local requested="${AI_MEM_REQUESTED_LAUNCHER:-omp}"
    local configured="${AI_MEM_OMP_MODEL:-}"
    local mapped="${AI_MEM_OMP_MODELS[$requested]:-}"
    if [[ -n "$mapped" ]]; then
        print -r -- "$mapped"
        return 0
    fi
    if [[ -n "$configured" ]]; then
        print -r -- "$configured"
        return 0
    fi
    if [[ -r "$HOME/.omp/agent/config.yml" ]]; then
        sed -n 's/^[[:space:]]*default:[[:space:]]*//p' "$HOME/.omp/agent/config.yml" | sed -n '1p'
    fi
}

__ai_omp_provider_args() {
    local requested="${AI_MEM_REQUESTED_LAUNCHER:-omp}"
    [[ "$requested" == omp ]] && return 0
    local provider="${AI_MEM_OMP_PROVIDERS[$requested]:-$requested}"
    local model="${AI_MEM_OMP_MODELS[$requested]:-}"
    print -r -- "--provider"
    print -r -- "$provider"
    if [[ -n "$model" ]]; then
        print -r -- "--model"
        print -r -- "$model"
    fi
}

__ai_omp_usage_snapshot() {
    [[ "${AI_MEM_OMP_SHOW_USAGE:-1}" != 0 ]] || return 0
    local usage_snapshot
    usage_snapshot="$(omp usage --redact 2>/dev/null)" || return 0
    [[ -n "$usage_snapshot" ]] || return 0
    print -r -- "ai-memory: OMP provider usage (weekly/account limits):"
    print -r -- "$usage_snapshot"
}

__ai_omp_skill_instructions() {
    local modes="$1" key skill_file skill_root text block=""
    for key in ${(s:|:)modes}; do
        skill_file=""
        for skill_root in "$HOME/.codex/skills" "$HOME/.agents/skills"; do
            if [[ -f "$skill_root/$key/SKILL.md" ]]; then
                skill_file="$skill_root/$key/SKILL.md"
                break
            fi
        done

        if [[ -n "$skill_file" ]]; then
            block+=$'\n--- local skill '
            block+="$key"
            block+=$' (already loaded locally; do not look up in OMP registry) ---\n'
            block+="$(<"$skill_file")"
            block+=$'\n--- end local skill '
            block+="$key"
            block+=$' ---\n'
        else
            text="${AI_MEM_SKILLS[$key]#*::}"
            [[ -n "$text" ]] || continue
            block+=$'\n--- local session instruction '
            block+="$key"
            block+=$' (already loaded locally; do not look up in OMP registry) ---\n'
            block+="$text"
            block+=$'\n--- end local session instruction '
            block+="$key"
            block+=$' ---\n'
        fi
    done
    print -r -- "$block"
}

__ai_adapter_omp() {
    local memory_prompt="$1" mode_block="$2"
    shift 2 2>/dev/null || true
    local system_prompt model_selector arg previous_arg="" loaded_skills="" provider_args=()
    provider_args=( ${(f)"$(__ai_omp_provider_args)"} )
    model_selector="$(__ai_omp_model_selector)"
    for arg in "$@"; do
        if [[ "$arg" == --model=* ]]; then
            model_selector="${arg#--model=}"
        elif [[ "$previous_arg" == --model ]]; then
            model_selector="$arg"
        fi
        previous_arg="$arg"
    done
    if [[ -n "$model_selector" ]]; then
        print -r -- "ai-memory: OMP provider/model: $model_selector" >&2
    else
        print -r -- "ai-memory: OMP provider/model: OMP default (not resolved)" >&2
    fi
    __ai_omp_usage_snapshot >&2
    loaded_skills="$(__ai_omp_skill_instructions "${AI_SESSION_MODES:-}")"
    [[ -n "$loaded_skills" ]] || loaded_skills="$mode_block"
    system_prompt="You are running inside an ai-memory session. The vault is available at $AI_MEM_ROOT. Read the relevant project and session notes when the user gives a task. The local skill and instruction contents below are already loaded. Do not search OMP's separate skill registry; apply these instructions directly. Wait for the user's task before taking action."
    if [[ -n "$model_selector" ]]; then
        system_prompt+=$'\nCurrent provider/model selector: '
        system_prompt+="$model_selector"
    fi
    local ai_mem_bin="${AI_MEM_HOME:h}/bin"
    if [[ -x "$ai_mem_bin/ai-mem-search" ]]; then
        export PATH="$ai_mem_bin:$PATH"
        system_prompt+=$'\nUse the executable ai-mem-search for vault searches. Do not glob or read session-log files directly when answering memory questions; use ai-mem-search so project scope, archived-log filtering, ranking, and output limits remain correct.'
    fi
    if [[ -n "$mode_block" ]]; then
        system_prompt+=$'\n\nActive local skill instructions:\n'
        system_prompt+="$loaded_skills"
    fi
    omp --add-dir "$AI_MEM_ROOT" --append-system-prompt "$system_prompt" \
        $provider_args "$memory_prompt" "$@"
}

# --- Example: add another harness by defining its adapter and listing it in
# AI_MEM_HARNESSES. aider takes the initial instruction via --message:
# __ai_adapter_aider() {
#     local memory_prompt="$1"
#     aider --message "$memory_prompt"
# }
