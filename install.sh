#!/usr/bin/env bash
# ai-mem installer: scaffold the vault and print the lines to add to ~/.zshrc.
# Idempotent — never overwrites existing vault notes. Override the vault
# location by exporting AI_MEM_ROOT before running.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
: "${AI_MEM_ROOT:=$HOME/.ai-memory/_Ai_Memory}"

echo "ai-mem: scaffolding vault at $AI_MEM_ROOT"
mkdir -p "$AI_MEM_ROOT/_projects" "$AI_MEM_ROOT/_session_logs"

# Copy a template file only when the destination does not already exist, so a
# re-run never clobbers the user's real notes.
copy_if_absent() {
  local src="$1" dst="$2"
  if [ -e "$dst" ]; then
    echo "  keep   $dst"
  else
    cp "$src" "$dst"
    echo "  create $dst"
  fi
}

copy_if_absent "$HERE/vault-template/_Global_Profile.md"                 "$AI_MEM_ROOT/_Global_Profile.md"
copy_if_absent "$HERE/vault-template/_Standards.md"                      "$AI_MEM_ROOT/_Standards.md"
copy_if_absent "$HERE/vault-template/_projects/_project_template.md"     "$AI_MEM_ROOT/_projects/_project_template.md"
copy_if_absent "$HERE/vault-template/_session_logs/_session_template.md" "$AI_MEM_ROOT/_session_logs/_session_template.md"

cat <<EOF

Done. Add these two lines to your ~/.zshrc:

  export AI_MEM_ROOT="$AI_MEM_ROOT"
  source "$HERE/shell/ai-mem.zsh"

Then: exec zsh, cd into a git repo, and run  claude-start  (or codex/gemini/cursor).

Optional:
  - Claude Code hooks : see $HERE/hooks/claude/settings.snippet.json
  - Git commit guard  : cp $HERE/hooks/git/* <repo>/.githooks/ && git config core.hooksPath .githooks
EOF
