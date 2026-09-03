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

# --- Example: add another agent by defining its adapter and listing it in
# AI_MEM_AGENTS. aider takes the initial instruction via --message:
# __ai_adapter_aider() {
#     local memory_prompt="$1"
#     aider --message "$memory_prompt"
# }
