#!/usr/bin/env bash
# ai-memory installer. Interactive when run in a terminal (banner + prompts),
# and non-interactive when piped (npx, CI): it takes defaults or environment
# overrides and never blocks. Idempotent; it never clobbers existing vault notes
# and never double-appends to ~/.zshrc.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"

# Interactive only when both stdin and stdout are a terminal.
INTERACTIVE=0
[ -t 0 ] && [ -t 1 ] && INTERACTIVE=1

# ask <var> <prompt> <default>: read a value interactively, else take the default
# (or an existing environment value of the same name).
ask() {
  local __var="$1" __prompt="$2" __default="$3" __cur __reply
  __cur="${!__var:-}"
  [ -n "$__cur" ] && __default="$__cur"
  if [ "$INTERACTIVE" -eq 1 ]; then
    read -r -p "  $__prompt [$__default] " __reply || true
    printf -v "$__var" '%s' "${__reply:-$__default}"
  else
    printf -v "$__var" '%s' "$__default"
  fi
}

confirm() { # confirm <prompt>  -> 0 for yes; defaults to yes, and yes when piped
  [ "$INTERACTIVE" -eq 0 ] && return 0
  local __reply
  read -r -p "  $1 [Y/n] " __reply || true
  case "${__reply:-Y}" in [Nn]*) return 1 ;; *) return 0 ;; esac
}

# Color only when it lands in a real terminal that wants it.
supports_color() {
  [ "$INTERACTIVE" -eq 1 ] || return 1
  [ -z "${NO_COLOR:-}" ] || return 1
  [ "${TERM:-}" != "dumb" ] || return 1
}

# ANSI Shadow "AI MEMORY" with a teal->violet vertical gradient (24-bit color),
# degrading to plain block art when color is unavailable.
banner() {
  local art=(
' █████╗ ██╗    ███╗   ███╗███████╗███╗   ███╗ ██████╗ ██████╗ ██╗   ██╗'
'██╔══██╗██║    ████╗ ████║██╔════╝████╗ ████║██╔═══██╗██╔══██╗╚██╗ ██╔╝'
'███████║██║    ██╔████╔██║█████╗  ██╔████╔██║██║   ██║██████╔╝ ╚████╔╝ '
'██╔══██║██║    ██║╚██╔╝██║██╔══╝  ██║╚██╔╝██║██║   ██║██╔══██╗  ╚██╔╝  '
'██║  ██║██║    ██║ ╚═╝ ██║███████╗██║ ╚═╝ ██║╚██████╔╝██║  ██║   ██║   '
'╚═╝  ╚═╝╚═╝    ╚═╝     ╚═╝╚══════╝╚═╝     ╚═╝ ╚═════╝ ╚═╝  ╚═╝   ╚═╝   '
  )
  local grad=( '45;212;191' '56;189;248' '59;130;246' '99;102;241' '139;92;246' '168;85;247' )
  echo
  if supports_color; then
    local i
    for i in "${!art[@]}"; do
      printf '\033[1;38;2;%sm%s\033[0m\n' "${grad[$i]}" "${art[$i]}"
    done
    printf '\033[2m   persistent, agent-agnostic session memory · one vault, any CLI\033[0m\n\n'
  else
    printf '%s\n' "${art[@]}"
    printf '   persistent, agent-agnostic session memory - one vault, any CLI\n\n'
  fi
}

banner

# --- gather settings ---------------------------------------------------------
AI_MEM_ROOT="${AI_MEM_ROOT:-$HOME/.ai-memory/_Ai_Memory}"
ask AI_MEM_ROOT   "Where should your memory vault live?" "$AI_MEM_ROOT"
AI_MEM_AGENTS="${AI_MEM_AGENTS:-claude codex gemini cursor}"
ask AI_MEM_AGENTS "Which agents should get <agent>-start launchers?" "$AI_MEM_AGENTS"

# --- scaffold the vault ------------------------------------------------------
echo
echo "  scaffolding vault at: $AI_MEM_ROOT"
mkdir -p "$AI_MEM_ROOT/_projects" "$AI_MEM_ROOT/_session_logs"

copy_if_absent() { # never overwrite the user's real notes on a re-run
  local src="$1" dst="$2"
  if [ -e "$dst" ]; then echo "    keep   ${dst##*/}"; else cp "$src" "$dst"; echo "    create ${dst##*/}"; fi
}
copy_if_absent "$HERE/vault-template/_Global_Profile.md"                 "$AI_MEM_ROOT/_Global_Profile.md"
copy_if_absent "$HERE/vault-template/_Standards.md"                      "$AI_MEM_ROOT/_Standards.md"
copy_if_absent "$HERE/vault-template/_projects/_project_template.md"     "$AI_MEM_ROOT/_projects/_project_template.md"
copy_if_absent "$HERE/vault-template/_session_logs/_session_template.md" "$AI_MEM_ROOT/_session_logs/_session_template.md"

# --- assemble the ~/.zshrc lines ---------------------------------------------
LINES="export AI_MEM_ROOT=\"$AI_MEM_ROOT\""
if [ "$AI_MEM_AGENTS" != "claude codex gemini cursor" ]; then
  LINES="$LINES
export AI_MEM_AGENTS=\"$AI_MEM_AGENTS\""
fi
LINES="$LINES
source \"$HERE/shell/ai-mem.zsh\""

RC="$HOME/.zshrc"
SOURCE_LINE="source \"$HERE/shell/ai-mem.zsh\""

echo
if [ -f "$RC" ] && grep -qF "$SOURCE_LINE" "$RC"; then
  echo "  ~/.zshrc already sources ai-memory; leaving it untouched."
elif confirm "Append the setup lines to ~/.zshrc now?"; then
  { printf '\n# ai-memory (https://github.com/rambaarde/create-ai-memory)\n'; printf '%s\n' "$LINES"; } >> "$RC"
  echo "  added to $RC"
  echo
  echo "  Reload your shell:  exec zsh"
else
  cat <<EOF

  Add these lines to your ~/.zshrc yourself:

$(printf '%s\n' "$LINES" | sed 's/^/    /')
EOF
fi

cat <<EOF

  Done. From inside any git repo, run:  claude-start
  (or codex-start / gemini-start / cursor-start)

  Optional integrations: see $HERE/hooks/  and the README.
EOF
