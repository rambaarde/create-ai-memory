# === AI CLI + Obsidian memory ===
# Portable, agent-agnostic session memory. Source this from ~/.zshrc after
# exporting AI_MEM_ROOT to point at your vault. Zsh-only (uses print -r, ${(s)},
# and associative arrays). Add a new agent by defining __ai_adapter_<name> in adapters.zsh and
# listing it in AI_MEM_AGENTS; a matching <name>-start function is generated.
#
# Private helpers are named __ai_* with TWO leading underscores, deliberately.
# Claude Code snapshots the interactive shell and replays that snapshot for
# every agent-run command, and its snapshot drops every function whose name
# starts with a single underscore -- the filter is aimed at zsh's ~1000
# completion functions (_git, _ssh, ...), and single-underscore private
# helpers are collateral. Measured on one real shell: 1018 single-underscore
# functions defined, 0 survived; all 9 double-underscore ones did.
#
# The failure that causes is silent, not loud. A public function survives,
# calls a helper that no longer exists, and carries on: ai-mem-vault-backup
# printed "nothing to commit" and exited 0 while backing up nothing, which
# an agent then reports as success. Do not "tidy" these back to one
# underscore -- tests/run.sh asserts the naming for exactly this reason.

# Directory holding this module, used to source sibling files.
AI_MEM_HOME="${0:A:h}"

# Where the shipped example notes and templates live, used to auto-scaffold a
# vault on first use so install.sh is optional (plugin-manager installs work).
AI_MEM_TEMPLATE_SRC="${AI_MEM_HOME:h}/vault-template"

# Fingerprint of the module files, recorded at source time and re-checked at
# launch. A shell keeps whatever function definitions it loaded at startup:
# editing these files, or upgrading the package, changes nothing in a
# terminal that is already open. That is a silent trap rather than an
# obvious one -- the launcher still runs, still reports success, and quietly
# uses whatever behaviour was current whenever this terminal was opened,
# which can be months. Comparing the two makes the staleness visible.
# cksum is POSIX, so this needs no macOS/Linux branch.
__ai_mem_fingerprint() {
    cksum "$AI_MEM_HOME/ai-mem.zsh" "$AI_MEM_HOME/adapters.zsh" 2>/dev/null \
        | awk '{ printf "%s-", $1 }'
}
export AI_MEM_SOURCED_FINGERPRINT="$(__ai_mem_fingerprint)"
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

# `note_path`, not `path`: in zsh `path` is the special array tied to $PATH,
# so `local path=...` inside a function replaces command lookup with the
# string being passed in and every external command becomes "command not
# found". This function only uses builtins, so it survived the mistake -- but
# the next editor to add a `grep` here would not.
__ai_mem_guard() {
    local note_path="${1:-}"
    case "$note_path" in
        "$AI_MEM_ROOT"|"$AI_MEM_ROOT"/*) return 0 ;;
        *)
            echo "Refusing to touch non-memory path: $note_path"
            return 1
            ;;
    esac
}

# Best-effort git commit+push for the vault itself (not the project repo being
# worked on) -- shared by ai-note/ai-lesson (so a note is durable the moment
# it's written, not just at session Stop, which can silently never fire) and
# the Stop hook's own copy (hooks/claude/session-summary.sh runs standalone,
# outside this sourced shell, so it can't call this function directly).
# No-ops silently if AI_MEM_ROOT isn't its own git repo; never fails the
# caller on a push error (no network, no remote configured, etc).
__ai_mem_vault_backup() {
    local vault_git_root
    vault_git_root="$(git -C "${AI_MEM_ROOT:-}" rev-parse --show-toplevel 2>/dev/null || true)"
    [[ -n "$vault_git_root" ]] || return 0

    local lock_dir="$vault_git_root/.git/aimem-backup.lock"
    if [[ -d "$lock_dir" ]]; then
        local lock_age=$(( $(date +%s) - $(stat -c %Y "$lock_dir" 2>/dev/null || stat -f %m "$lock_dir" 2>/dev/null || echo 0) ))
        (( lock_age > 60 )) && rmdir "$lock_dir" 2>/dev/null
    fi

    if mkdir "$lock_dir" 2>/dev/null; then
        git -C "$vault_git_root" add -A 2>/dev/null
        if ! git -C "$vault_git_root" diff --cached --quiet 2>/dev/null; then
            git -C "$vault_git_root" commit -q -m "vault backup: $(date '+%Y-%m-%d %H:%M:%S')" 2>/dev/null
            git -C "$vault_git_root" push -q 2>/dev/null
        fi
        rmdir "$lock_dir" 2>/dev/null
    fi
    return 0
}

# Public entry point for anything that writes to the vault outside
# ai-note/ai-lesson -- e.g. the update-session-log skill, which edits the
# Session Outcome section directly and has no other reason to know this
# function exists.
# The graph viewer and the MCP server are Node scripts shipped beside this
# module. They are declared as npm `bin` entries too, but `npm create` copies
# the tool into a folder rather than installing it globally, so nothing puts
# them on PATH -- exposing them as functions is what makes the documented
# commands work for everyone, however they installed.
#
# The bundled copy wins over anything on PATH: it is guaranteed to match the
# module the shell just sourced, which a separately-installed global may not.
__ai_mem_node_bin() {
    local script="$AI_MEM_HOME/../bin/$1"
    shift
    if [[ -f "$script" ]]; then
        command node "$script" "$@"
    elif command -v "${1:-}" >/dev/null 2>&1; then
        command "$@"
    else
        print -r -- "$script is missing -- reinstall with: npm create ai-memory@latest" >&2
        return 1
    fi
}

ai-mem-serve() { __ai_mem_node_bin ai-mem-serve.js "$@" }
ai-mem-mcp()   { __ai_mem_node_bin ai-mem-mcp.js "$@" }

ai-mem-vault-backup() {
    # Fail loudly if the helper is absent. Without this the function still
    # "works": HEAD does not move, so it prints "nothing to commit" and exits
    # 0, and the agent reading that reports a successful backup of a vault
    # nothing was written to. A wrong answer that looks like a right one is
    # the worst outcome for a memory tool, so refuse instead of guessing.
    if (( ! $+functions[__ai_mem_vault_backup] )); then
        print -r -- "ai-mem-vault-backup: helper __ai_mem_vault_backup is not defined -- this shell's function table is incomplete (stale or filtered snapshot). Re-run in a fresh terminal, or commit and push \$AI_MEM_ROOT by hand." >&2
        return 1
    fi

    local before after
    before="$(git -C "${AI_MEM_ROOT:-}" rev-parse HEAD 2>/dev/null || true)"
    __ai_mem_vault_backup
    after="$(git -C "${AI_MEM_ROOT:-}" rev-parse HEAD 2>/dev/null || true)"
    if [[ -z "$before" && -z "$after" ]]; then
        echo "ai-mem-vault-backup: vault isn't git-backed, nothing to do"
        return 0
    fi

    # "pushed" used to mean "HEAD moved", which is what a COMMIT does. The push
    # is best-effort and swallows its own errors, so a commit that never left
    # the machine still reported success -- observed for real: three commits
    # sat unpushed for an hour while every backup said "pushed", because the
    # credential in use had lost access to the vault repo.
    #
    # Ask the only question that matters: does the remote have what we have.
    local upstream local_sha remote_sha
    upstream="$(git -C "$AI_MEM_ROOT" rev-parse --abbrev-ref '@{u}' 2>/dev/null || true)"
    if [[ -z "$upstream" ]]; then
        if [[ "$before" != "$after" ]]; then
            echo "ai-mem-vault-backup: committed, but this branch has no upstream -- nothing was pushed"
            return 1
        fi
        echo "ai-mem-vault-backup: nothing to commit (no upstream configured)"
        return 0
    fi

    git -C "$AI_MEM_ROOT" fetch -q origin 2>/dev/null
    local_sha="$(git -C "$AI_MEM_ROOT" rev-parse HEAD 2>/dev/null || true)"
    remote_sha="$(git -C "$AI_MEM_ROOT" rev-parse '@{u}' 2>/dev/null || true)"

    if [[ -n "$local_sha" && "$local_sha" == "$remote_sha" ]]; then
        if [[ "$before" != "$after" ]]; then
            echo "ai-mem-vault-backup: pushed"
        else
            echo "ai-mem-vault-backup: nothing to commit"
        fi
        return 0
    fi

    local ahead
    ahead="$(git -C "$AI_MEM_ROOT" rev-list --count '@{u}..HEAD' 2>/dev/null || echo '?')"
    print -r -- "ai-mem-vault-backup: NOT PUSHED -- $ahead commit(s) exist only on this machine." >&2
    print -r -- "  The vault is committed locally but the remote does not have it. Check credentials and push by hand:" >&2
    print -r -- "  git -C \"$AI_MEM_ROOT\" push" >&2
    return 1
}
# Read a vault note only when it exists inside the memory root.
#
# A note may declare `mirror_of: <other-note>` in its frontmatter, as the
# shipped _Standards.md does for _Global_Profile.md. The mirror exists so the
# shared rules stay visible wherever only one of the two gets read -- but
# injecting BOTH in full into the SAME prompt restates text the model just
# finished reading. Measured on a real vault: 72 of the mirror's 80 unique
# lines were already verbatim in its source, ~2900 of the launch prompt's
# ~7200 tokens spent saying the same thing twice.
#
# So a mirror contributes only the lines that actually differ. This fails
# OPEN in every uncertain case -- no frontmatter, an unreadable or missing
# target, a target outside the vault, or a diff that would leave nothing --
# because injecting a note twice merely costs tokens, while dropping one
# costs the agent context it was promised.
# Bound what a single note can contribute to the launch prompt.
#
# Every other path into the prompt is already bounded: session-log fields at
# 500 chars each, the lesson index at 200 slugs, search output at a flat cap,
# and the project note is a path rather than its contents. The inlined notes
# were the one exception, so a profile that grows makes EVERY session in
# EVERY project more expensive, forever, and nothing reports it.
#
# Truncation states the real total and where to read the rest, because a
# truncated note the agent cannot tell from a complete one is worse than a
# long one -- it would answer from half a profile believing it had all of it.
#
# The cut lands on a line boundary. Markdown cut mid-line can leave an
# unterminated code fence or half a heading, which reads as content rather
# than as damage.
__ai_mem_cap_note() {
    local text="$1" source_ref="${2:-the note}"
    local cap="${AI_MEM_NOTE_MAX_CHARS:-8000}"
    # 0 disables the cap outright, for anyone who wants the old behaviour.
    if (( cap <= 0 )) || (( ${#text} <= cap )); then
        print -r -- "$text"
        return 0
    fi
    local head_text="${text[1,$cap]}"
    local trimmed="${head_text%$'\n'*}"
    # A single line longer than the whole cap leaves nothing after trimming;
    # keep the hard cut rather than emitting an empty note.
    [[ -n "${trimmed//[[:space:]]/}" ]] && head_text="$trimmed"
    print -r -- "$head_text"
    print -r -- "[truncated at ${cap} of ${#text} chars -- read the rest with: cat \"$source_ref\"]"
}

__ai_mem_note_contents() {
    local note_path="${1:-}"
    if [[ -z "$note_path" || ! -f "$note_path" ]]; then
        return 0
    fi

    __ai_mem_guard "$note_path" || return 1

    # Read mirror_of from the frontmatter block only (lines 2..next `---`), so
    # the word appearing in a note's prose can never be mistaken for a claim.
    local mirror
    mirror="$(sed -n '2,/^---$/p' "$note_path" 2>/dev/null | sed -n 's/^mirror_of:[[:space:]]*//p' | head -1)"
    if [[ -z "$mirror" ]]; then
        __ai_mem_cap_note "$(<"$note_path")" "$note_path"
        return 0
    fi

    # A mirror names a sibling note, never a path. __ai_mem_guard matches on
    # the string, so "$AI_MEM_ROOT/../../etc/passwd" would satisfy it -- and
    # this value comes out of a file's frontmatter, so accepting a path here
    # would turn any note into a request to read an arbitrary file. Rejecting
    # every separator outright is both the safer rule and the simpler one.
    local target="$AI_MEM_ROOT/$mirror"
    if [[ "$mirror" == */* || ! -f "$target" ]]; then
        __ai_mem_cap_note "$(<"$note_path")" "$note_path"
        return 0
    fi

    # -x -F: drop only lines that are byte-for-byte identical to one in the
    # source. Anything reworded stays, because a near-match is a real edit.
    local unique
    unique="$(grep -vxF -f "$target" -- "$note_path" 2>/dev/null)"
    if [[ -z "${unique//[[:space:]]/}" ]]; then
        print -r -- "(identical to ${mirror}; nothing further)"
        return 0
    fi

    print -r -- "(mirror of ${mirror}, shown above -- only the lines that differ from it are repeated here)"
    __ai_mem_cap_note "$unique" "$note_path"
}

__ai_mem_resolve_project() {
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

__ai_mem_project_session_dir() {
    local project_name="${1:-}"
    if [[ -z "$project_name" ]]; then
        project_name="$(__ai_mem_resolve_project)"
    fi

    print -r -- "$AI_MEM_SESSION_DIR/$project_name"
}

__ai_mem_graphify_repo_root() {
    local git_root=""
    git_root="$(git rev-parse --show-toplevel 2>/dev/null)" || true
    if [[ -n "$git_root" ]]; then
        print -r -- "$git_root"
    else
        print -r -- "$PWD"
    fi
}

__ai_mem_graphify_context() {
    local repo_root="$(__ai_mem_graphify_repo_root)"
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
__ai_mem_latest_session_log() {
    local project_name="${1:-}"
    if [[ -z "$project_name" ]]; then
        project_name="$(__ai_mem_resolve_project)"
    fi

    local latest=""
    local project_session_dir
    project_session_dir="$(__ai_mem_project_session_dir "$project_name")"

    latest="$(find "$project_session_dir" -maxdepth 1 -type f -name "${project_name}-*.md" 2>/dev/null | sort | tail -n 1)" || true
    if [[ -z "$latest" ]]; then
        latest="$(find "$AI_MEM_SESSION_DIR" -maxdepth 1 -type f -name "${project_name}-*.md" 2>/dev/null | sort | tail -n 1)" || true
    fi
    if [[ -n "$latest" ]]; then
        __ai_mem_guard "$latest" || return 1
        print -r -- "$latest"
    fi
}

# Copy the shipped profile, standards, and templates into the vault on first use.
# Idempotent and additive: it never overwrites a file the user already has, so a
# plugin-manager install (source only, no install.sh) still gets a working vault.
__ai_mem_ensure_vault() {
    [[ -d "$AI_MEM_TEMPLATE_SRC" ]] || return 0
    mkdir -p "$AI_MEM_PROJECT_DIR" "$AI_MEM_SESSION_DIR" "$AI_MEM_ROOT/_lessons"
    local rel
    for rel in _Global_Profile.md _Standards.md \
               _projects/_project_template.md _session_logs/_session_template.md \
               _lessons/_lesson_template.md; do
        local src="$AI_MEM_TEMPLATE_SRC/$rel" dst="$AI_MEM_ROOT/$rel"
        if [[ -f "$src" && ! -f "$dst" ]]; then
            __ai_mem_guard "$dst" || return 1
            cp "$src" "$dst"
        fi
    done

    # Seeding only fills in a MISSING file, which is right -- these are the
    # user's notes and templates, and an upgrade must not overwrite edits they
    # made. But that leaves an existing vault on whatever templates it had
    # when it was created: `npm update` never touches them, and neither does
    # install.sh. The session log template is the one where that silently
    # matters, because every future log is copied from it -- a template with
    # no `type:` rebuilds a backlog of non-conforming notes one session at a
    # time, and nothing surfaces it.
    #
    # So repair exactly that one field, additively, and leave everything else
    # in the file alone. This runs on session prep, so an existing install
    # heals on its next launch rather than waiting for someone to think to run
    # ai-mem-lint --fix.
    # The `project:` line must be a [[wikilink]] or every log created from this
    # template is orphaned from its project note -- which is what the graph
    # edges and ai-mem-lint both key on. A vault whose template predates that
    # produced disconnected logs silently, one per session.
    local tmpl="$AI_MEM_SESSION_DIR/_session_template.md"
    if [[ -f "$tmpl" ]] && grep -qm1 '^project: {{project_name}}$' "$tmpl"; then
        __ai_mem_guard "$tmpl" || return 1
        local ptmp="$tmpl.aimem-upgrade"
        sed 's|^project: {{project_name}}$|project: "[[{{project_name}}]]"|' "$tmpl" > "$ptmp" && mv "$ptmp" "$tmpl"
    fi
    if [[ -f "$tmpl" ]] && ! grep -qm1 '^previous:' "$tmpl"; then
        __ai_mem_guard "$tmpl" || return 1
        local vtmp="$tmpl.aimem-upgrade"
        awk '/^project:/ { print; print "previous: \"{{previous_session_link}}\""; next } { print }' "$tmpl" > "$vtmp" && mv "$vtmp" "$tmpl"
    fi

    if [[ -f "$tmpl" ]] && ! grep -qm1 '^type: ' "$tmpl"; then
        __ai_mem_guard "$tmpl" || return 1
        local tmp="$tmpl.aimem-upgrade"
        if [[ "$(head -1 "$tmpl")" == "---" ]]; then
            { head -1 "$tmpl"; print -r -- "type: ai-session-log"; tail -n +2 "$tmpl"; } > "$tmp"
        else
            { print -rl -- "---" "type: ai-session-log" "---" ""; cat "$tmpl"; } > "$tmp"
        fi
        mv "$tmp" "$tmpl"
    fi
}

__ai_mem_prepare_session() {
    local project_name="${1:-}"
    if [[ -z "$project_name" ]]; then
        project_name="$(__ai_mem_resolve_project)"
    fi

    __ai_mem_ensure_vault || return 1

    local project_note="$AI_MEM_PROJECT_DIR/${project_name}.md"
    local project_session_dir
    project_session_dir="$(__ai_mem_project_session_dir "$project_name")"
    local previous_session_note=""
    previous_session_note="$(__ai_mem_latest_session_log "$project_name")" || return 1
    local session_note="$project_session_dir/${project_name}-$(date +%Y-%m-%d_%H-%M-%S).md"

    __ai_mem_guard "$project_note" || return 1
    __ai_mem_guard "$session_note" || return 1

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
__ai_mem_session_field() {
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
__ai_mem_cap_field() {
    local text="$1" cap="${2:-500}" source_ref="$3"
    if (( ${#text} > cap )); then
        print -r -- "${text[1,$cap]}… (truncated, ${#text} chars total — see $source_ref)"
    else
        print -r -- "$text"
    fi
}

# An agent cannot search for knowledge it does not know exists, and the
# lesson bodies are far too large to inject -- but a slug like
# prisma-connection-pool-exhaustion is already the lesson compressed to a
# handful of tokens. Listing the names turns a blind guess into a precise
# ai-mem-search, at roughly 4 tokens per lesson. Recognition is the point;
# recall is what the agent is bad at.
#
# Names only, never bodies. The cap exists because this stops paying for
# itself once most entries are irrelevant to the session at hand: a long
# tail of near-miss titles is the most damaging kind of distractor for a
# model, which is the same reason ai-mem-search bounds its own output.
# Newest first, so the cap drops the stalest rather than the alphabetically
# unlucky.
__ai_mem_lesson_index() {
    local dir="$AI_MEM_ROOT/_lessons"
    [[ -d "$dir" ]] || return 0

    # (N) tolerate an empty dir, (.) files only, (om) newest mtime first,
    # (:t:r) basename without the extension. Then drop _lesson_template.
    local -a slugs
    slugs=("$dir"/*.md(N.om:t:r))
    slugs=(${slugs:#_*})
    (( $#slugs )) || return 0

    local limit="${AI_MEM_LESSON_INDEX_LIMIT:-200}"
    local total=$#slugs extra=0
    if (( total > limit )); then
        extra=$(( total - limit ))
        slugs=(${slugs[1,$limit]})
    fi

    print -r -- "- Lessons already recorded ($total), listed by topic slug only -- the bodies are NOT included here. If one looks relevant to the task at hand, read it with \`ai-mem-search <slug>\` before solving the problem again from scratch."
    print -r -- "  ${(j:, :)slugs}"
    (( extra )) && print -r -- "  (+$extra older, not listed; \`ls \$AI_MEM_ROOT/_lessons\` for the rest)"
    return 0
}

__ai_mem_context_prompt() {
    local project_note="${1:-}"
    local previous_session_note="${2:-}"
    local session_note="${3:-}"
    local previous_session_label="(none yet)"
    local previous_session_block="- Latest prior session log: (none yet)"

    if [[ -n "$previous_session_note" ]]; then
        previous_session_label="$previous_session_note"

        local summary decisions blockers next
        summary="$(__ai_mem_session_field "$previous_session_note" 'High-Level Summary')"
        decisions="$(__ai_mem_session_field "$previous_session_note" 'Important Decisions')"
        blockers="$(__ai_mem_session_field "$previous_session_note" 'Constraints / Blockers')"
        next="$(__ai_mem_session_field "$previous_session_note" 'Next Step')"

        if [[ -z "${AI_MEM_NO_DIGEST:-}" && ( -n "$summary" || -n "$decisions" || -n "$blockers" || -n "$next" ) ]]; then
            [[ -n "$summary" ]] || summary="—"
            [[ -n "$decisions" ]] || decisions="—"
            [[ -n "$blockers" ]] || blockers="—"
            [[ -n "$next" ]] || next="—"

            previous_session_block="- Latest prior session ($previous_session_note), summarized below:"
            previous_session_block+=$'\n'"* **Summary:** $(__ai_mem_cap_field "$summary" 500 "$previous_session_note")"
            previous_session_block+=$'\n'"* **Decisions:** $(__ai_mem_cap_field "$decisions" 500 "$previous_session_note")"
            previous_session_block+=$'\n'"* **Blockers:** $(__ai_mem_cap_field "$blockers" 500 "$previous_session_note")"
            previous_session_block+=$'\n'"* **Next:** $(__ai_mem_cap_field "$next" 500 "$previous_session_note")"
        else
            previous_session_block="- Latest prior session log: $previous_session_label"
            previous_session_block+=$'\n'
            previous_session_block+="Read the latest prior session log for continuity before acting. Do not load the full session history unless the user asks for it."
        fi
    fi

    # A project note straight from the template is worse than no note: the
    # prompt points at it as "Project context", the agent opens it, and finds
    # "[What problem this repository solves]". That reads as context and
    # carries none -- the same present-but-empty failure as a search that
    # returns nothing while looking authoritative. Say so, and say what to do.
    local project_state=""
    if [[ -f "$project_note" ]] && grep -q '\[What problem this repository solves\]' "$project_note" 2>/dev/null; then
        project_state=" -- NOT YET FILLED IN: it is still the blank template, so it holds no context. Read the repo (README, package manifest, AGENTS.md/CLAUDE.md, recent git log) and fill it in early in this session; every future session on this repo starts from it."
    fi

    cat <<EOF
Read these notes before doing anything else:
- Global profile:
$(__ai_mem_note_contents "$AI_MEM_GLOBAL")

- Standards:
$(__ai_mem_note_contents "$AI_MEM_STANDARDS")

- Project context: $project_note$project_state
$previous_session_block
- Active session log: $session_note
$(__ai_mem_lesson_index)

Use the Obsidian vault as the persistent memory layer.
Treat the global profile and standards note as the shared baseline for every run.
Keep durable preferences and project facts in the vault, and keep the active session log updated with decisions, blockers, and next steps.
For anything not covered above -- a decision from further back, a different project, a health check on the vault's links -- run \`ai-mem-search <term> [project]\` or \`ai-mem-lint\` yourself; both are zsh functions from the sourced module, so \`command -v\` finds them but \`which\` under bash will not. Search is case-insensitive and matches literally, and its output is capped: if it reports results hidden, narrow with a project argument or a more specific term rather than assuming you have seen everything. Start broad and narrow from there -- a first query that is too specific is the usual way to miss what you were looking for.
When you hit a blocker -- an error you do not immediately understand, a test failing for an unclear reason, a decision you cannot settle from the code in front of you, or a second failed attempt at the same thing -- search the vault BEFORE guessing again. You have likely been here before, and \`_lessons/\` exists because the answer usually was written down; lessons are ranked above session logs in the results, so a hit under \`_lessons/\` is the recorded fix.
Search ONE distinctive word, not a sentence. Matching is literal substring, so a whole error line ('command not found: sed') finds nothing while 'command not found' finds it, and a bare tool name ('sed', 'git') returns hundreds of irrelevant lines. Pick the most unusual word in the symptom and try two or three of them separately.
If the user asks to see, open or browse their memory rather than search it, run \`ai-mem-serve\` -- it opens the vault as a graph in their browser, and is safe to run again if it is already up.
When you hit a mistake, decision, or solution worth remembering across projects (not just this one), run \`ai-lesson <topic-slug> <problem> <solution>\` -- e.g. \`ai-lesson rate-limiting "a fixed-window limiter kept losing bursts of legitimate traffic" "switched to a token bucket, which absorbs bursts correctly"\`. It appends a dated Problem/Solution entry to a cross-project note at _lessons/<topic-slug>.md; ai-mem-search already covers it.
EOF
}

# Mark the current shell as having loaded AI vault context for the active repo.
__ai_mem_mark_commit_ready() {
    local project_name="${1:-}"
    local source="${2:-ai-context}"
    local ready_dir="$AI_MEM_SESSION_DIR/.context-ready"
    local ready_file
    local token

    if [[ -z "$project_name" ]]; then
        project_name="$(__ai_mem_resolve_project)"
    fi

    ready_file="$ready_dir/${project_name}.token"
    __ai_mem_guard "$ready_file" || return 1

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

# Re-export the active-session vars in the CALLER's shell. __ai_mem_prepare_session
# exports them too, but it is always invoked inside $(...) command substitution, so
# those exports die in the subshell and never reach the launched client or its hooks
# (Claude's SessionStart/Stop hooks gate on AI_MEM_ACTIVE_SESSION_LOG).
__ai_mem_export_active() {
    export AI_MEM_ACTIVE_PROJECT="${1:-}"
    export AI_MEM_PREVIOUS_SESSION_LOG="${2:-}"
    export AI_MEM_ACTIVE_SESSION_LOG="${3:-}"
}

ai-start() {
    local project_name="${1:-}"
    shift || true

    local resolved
    resolved="$(__ai_mem_prepare_session "$project_name")" || return 1

    local active_project project_note previous_session_note session_note
    IFS='|' read -r active_project project_note previous_session_note session_note <<< "$resolved"
    __ai_mem_export_active "$active_project" "$previous_session_note" "$session_note"

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
    resolved="$(__ai_mem_prepare_session "$project_name")" || return 1

    local active_project
    IFS='|' read -r active_project project_note previous_session_note session_note <<< "$resolved"
    __ai_mem_export_active "$active_project" "$previous_session_note" "$session_note"

    __ai_mem_mark_commit_ready "$active_project" "ai-context" || return 1
    __ai_mem_context_prompt "$project_note" "$previous_session_note" "$session_note"
}

# Yes/no helper used by the session-mode prompts. Empty answer counts as no.
__ai_yesno() {
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
__ai_session_modes_pick() {
    local modes=() key prompt
    for key in "${AI_MEM_SKILL_ORDER[@]}"; do
        prompt="${AI_MEM_SKILLS[$key]%%::*}"
        [[ -n "$prompt" ]] || continue
        __ai_yesno "$prompt" && modes+=("$key")
    done
    print -r -- "${(j:|:)modes}"
}

# Build the instruction block to inject from the chosen skill keys.
__ai_session_modes_instructions() {
    local modes="$1" block="" m text
    for m in ${(s:|:)modes}; do
        text="${AI_MEM_SKILLS[$m]#*::}"
        [[ -n "$text" ]] && block+="$text"$'\n\n'
    done
    print -r -- "${block%$'\n\n'}"
}

# Start an AI client with the shared memory block and the chosen session mode.
__ai_session_start() {
    local launcher="${1:-}"
    if (( $# > 0 )); then
        shift
    fi

    # Warn (never block) if this shell is running a stale copy. Everything
    # below would otherwise succeed quietly using the old behaviour, and the
    # only symptom is a fix that appears not to have worked.
    local _fp_now
    _fp_now="$(__ai_mem_fingerprint)"
    if [[ -n "$AI_MEM_SOURCED_FINGERPRINT" && -n "$_fp_now" \
          && "$_fp_now" != "$AI_MEM_SOURCED_FINGERPRINT" ]]; then
        echo "ai-memory: this shell loaded an older copy of ai-mem; the files on disk have changed since." >&2
        echo "           Run 'source ~/.zshrc' or open a new terminal to pick up the current version." >&2
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
    resolved="$(__ai_mem_prepare_session)" || return 1

    local active_project project_note previous_session_note session_note
    IFS='|' read -r active_project project_note previous_session_note session_note <<< "$resolved"
    __ai_mem_export_active "$active_project" "$previous_session_note" "$session_note"

    local session_modes mode_block
    session_modes="$(__ai_session_modes_pick)" || return 1
    mode_block="$(__ai_session_modes_instructions "$session_modes")"

    # AI_SESSION_MODES carries the chosen skill keys; AI_SESSION_STYLE_LABEL
    # carries the assembled instruction block for launchers to inject.
    export AI_SESSION_MODES="$session_modes"
    export AI_SESSION_STYLE_LABEL="$mode_block"

    local memory_prompt
    memory_prompt="$(__ai_mem_context_prompt "$project_note" "$previous_session_note" "$session_note")"

    local graphify_context=""
    graphify_context="$(__ai_mem_graphify_context)" || return 1
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

    __ai_mem_mark_commit_ready "$active_project" "$launcher-start" || return 1

    # Dispatch to the agent adapter. Each adapter is passed the assembled
    # memory prompt, the mode block, and any remaining CLI args (e.g. files to
    # open). Adapters live in adapters.zsh; add one to support a new agent.
    if ! typeset -f "__ai_adapter_$launcher" >/dev/null; then
        echo "Unknown AI launcher: $launcher (define __ai_adapter_$launcher in adapters.zsh)" >&2
        return 1
    fi
    "__ai_adapter_$launcher" "$memory_prompt" "$mode_block" "$@"
}

# Load the agent adapters, then generate a <name>-start launcher for every
# registered agent that has a matching adapter. Users extend by appending to
# AI_MEM_AGENTS (space-separated) and defining __ai_adapter_<name>.
source "$AI_MEM_HOME/adapters.zsh"
: "${AI_MEM_AGENTS:=claude codex agy gemini cursor opencode}"
for _ai_agent in ${(z)AI_MEM_AGENTS}; do
    if typeset -f "__ai_adapter_$_ai_agent" >/dev/null; then
        # A same-named alias (e.g. from another plugin) makes zsh refuse to
        # `eval` a function definition of that name at all -- "defining
        # function based on alias", parse error near '()'. Clear it first;
        # the function this defines is what should win.
        unalias "${_ai_agent}-start" 2>/dev/null
        eval "${_ai_agent}-start() { __ai_session_start ${_ai_agent} \"\$@\"; }"
    fi
done
unset _ai_agent

__ai_mem_current_project() {
    __ai_mem_resolve_project
}

__ai_mem_today_session_log() {
    local project_name="${1:-}"
    if [[ -z "$project_name" ]]; then
        project_name="$(__ai_mem_resolve_project)"
    fi

    __ai_mem_ensure_vault || return 1

    local today
    today="$(date +%Y-%m-%d)"
    local project_session_dir
    project_session_dir="$(__ai_mem_project_session_dir "$project_name")"

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
        __ai_mem_guard "$latest" || return 1
        print -r -- "$latest"
        return 0
    fi

    local session_note="$project_session_dir/${project_name}-${today}_$(date +%H-%M-%S).md"
    __ai_mem_guard "$session_note" || return 1
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
    project_name="$(__ai_mem_current_project)" || return 1
    session_note="$(__ai_mem_today_session_log "$project_name")" || return 1
    timestamp="$(date +%H:%M)"

    __ai_mem_guard "$session_note" || return 1

    if ! grep -q '^### Live Notes' "$session_note" 2>/dev/null; then
        printf '\n### Live Notes\n' >> "$session_note"
    fi

    printf '\n- %s %s\n' "$timestamp" "$note_text" >> "$session_note"
    __ai_mem_vault_backup
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
    project_name="$(__ai_mem_current_project)" || return 1
    lesson_file="$AI_MEM_ROOT/_lessons/${slug}.md"
    timestamp="$(date '+%Y-%m-%d %H:%M')"

    __ai_mem_guard "$lesson_file" || return 1

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
    __ai_mem_vault_backup
    # Make the reinforcement visible: a second-or-later entry is the same
    # lesson firing again, which ai-mem-search now ranks higher. Derived from
    # the entries themselves, so nothing is stored twice.
    local recalls
    recalls="$(grep -c '^## [0-9]' "$lesson_file" 2>/dev/null)"
    if (( recalls > 1 )); then
        printf 'Reinforced %s -- %d recalls now, so it ranks higher in ai-mem-search\n' "$lesson_file" "$recalls"
    else
        printf 'Appended to %s\n' "$lesson_file"
    fi
}
# Lints the vault's links: session logs missing a project wikilink, previous
# links pointing at a note that no longer exists, and project notes nothing
# links back to. Pure grep/find -- no new dependency, catches exactly the
# "isolated dots in Graph View" class of problem before you have to notice it
# by eye.
ai-mem-lint() {
    local fix=0
    [[ "${1:-}" == "--fix" ]] && fix=1
    local issues=0 f label target found
    # Open Knowledge Format names exactly one required frontmatter field:
    # `type`. Every note the vault ships already declares one except session
    # logs, which predate the field -- so a vault that has been in use carries
    # a backlog of them. Counted rather than listed: one actionable line beats
    # several hundred identical ones, and the fix is a single pass anyway.
    local -a untyped_files

    while IFS= read -r -d '' f; do
        [[ "${f:t}" == "_session_template.md" ]] && continue

        grep -qm1 '^type: ' "$f" 2>/dev/null || untyped_files+=("$f")

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

    # The template is skipped by the loop above, and rightly -- it is not a
    # note. But it is what every future log is copied from, so a template
    # without `type:` quietly re-creates the whole backlog one session at a
    # time. An existing install keeps its own copy of the template and never
    # picks up a newer one, so fixing the shipped file is not enough.
    local tmpl="$AI_MEM_SESSION_DIR/_session_template.md"
    if [[ -f "$tmpl" ]] && ! grep -qm1 '^type: ' "$tmpl"; then
        if (( fix )); then
            __ai_mem_guard "$tmpl" >/dev/null && {
                local ttmp="$tmpl.aimem-backfill"
                if [[ "$(head -1 "$tmpl")" == "---" ]]; then
                    { head -1 "$tmpl"; print -r -- "type: ai-session-log"; tail -n +2 "$tmpl"; } > "$ttmp"
                else
                    { print -rl -- "---" "type: ai-session-log" "---" ""; cat "$tmpl"; } > "$ttmp"
                fi
                mv "$ttmp" "$tmpl"
                print -r -- "added \`type:\` to the session log template, so new logs carry it"
            }
        else
            print -r -- "the session log template has no \`type:\` field, so every new log will lack one. Fix with: ai-mem-lint --fix"
            (( issues++ ))
        fi
    fi

    # Logs already written from a stale template stay orphaned until repaired.
    # Reporting them without offering the fix leaves the user to hand-edit
    # hundreds of files, which nobody does.
    local -a orphan_files
    while IFS= read -r -d '' f; do
        [[ "${f:t}" == "_session_template.md" ]] && continue
        grep -qm1 -E '^project:.*\[\[.*\]\]' "$f" 2>/dev/null && continue
        grep -qm1 -E '^project: .+' "$f" 2>/dev/null && orphan_files+=("$f")
    done < <(find "$AI_MEM_SESSION_DIR" -maxdepth 2 -name "*.md" -print0 2>/dev/null)

    if (( $#orphan_files && fix )); then
        local pname otmp
        for f in $orphan_files; do
            __ai_mem_guard "$f" >/dev/null || continue
            pname="$(grep -m1 '^project: ' "$f" | sed 's/^project: *//; s/^"//; s/"$//')"
            [[ -n "$pname" ]] || continue
            otmp="$f.aimem-link"
            sed "s|^project: .*$|project: \"[[${pname}]]\"|" "$f" > "$otmp" && mv "$otmp" "$f"
        done
        print -r -- "linked $#orphan_files session log(s) back to their project note"
    fi

    if (( $#untyped_files )); then
        if (( fix )); then
            # Written by hand rather than with `sed -i`, whose in-place flag
            # takes an argument on BSD and not on GNU -- a portability trap
            # for a one-liner a user would otherwise paste from the README.
            local tmp
            for f in $untyped_files; do
                __ai_mem_guard "$f" >/dev/null || continue
                tmp="$f.aimem-backfill"
                if [[ "$(head -1 "$f")" == "---" ]]; then
                    { head -1 "$f"; print -r -- "type: ai-session-log"; tail -n +2 "$f"; } > "$tmp"
                else
                    { print -rl -- "---" "type: ai-session-log" "---" ""; cat "$f"; } > "$tmp"
                fi
                mv "$tmp" "$f"
            done
            print -r -- "backfilled \`type: ai-session-log\` into $#untyped_files session log(s)"
        else
            print -r -- "$#untyped_files session log(s) missing the \`type:\` frontmatter field (Open Knowledge Format requires it). Fix with: ai-mem-lint --fix"
            (( issues++ ))
        fi
    fi


    # Dangling wikilinks: a [[target]] pointing at a note that does not exist --
    # a dead edge in the graph. Detection only: the dead link is surfaced, never
    # auto-removed, because the intended target is unknowable and a note's own
    # prose is the author's to edit. Wikilinks resolve by basename (the same way
    # ai-mem-serve draws them), so the node set is every note's basename.
    #
    # One grep over the vault, never a grep per file -- a per-file scan is the
    # 25s antipattern ai-mem-search documents. Scope is the vault root derived
    # from AI_MEM_SESSION_DIR (its parent), the same subtree the rest of this
    # linter walks, so a caller that redirects the session dir redirects this too.
    local vault="${AI_MEM_SESSION_DIR:h}"
    typeset -A _known
    local nf
    for nf in ${(f)"$(find "$vault" -name '*.md' -not -path '*/.git/*' 2>/dev/null)"}; do
        _known[${nf:t:r}]=1
    done
    local -a dangling
    local line src tgt
    for line in ${(f)"$(grep -rHoE --include='*.md' --exclude-dir=.git -- '\[\[[^]]+\]\]' "$vault" 2>/dev/null)"}; do
        src="${line%%:\[\[*}"          # path, before the ':[[' grep separator
        tgt="${line##*:\[\[}"; tgt="${tgt%\]\]}"   # inside the brackets
        tgt="${tgt%%\|*}"; tgt="${tgt%%#*}"        # drop |alias and #heading
        tgt="${tgt## }"; tgt="${tgt%% }"
        [[ -z "$tgt" ]] && continue
        [[ -n "${_known[$tgt]-}" ]] && continue
        dangling+=( "${src:t} -> [[${tgt}]]" )
    done
    if (( $#dangling )); then
        print -r -- "$#dangling dangling wikilink(s) -- a [[link]] that resolves to no note:"
        for line in $dangling; do print -r -- "  $line"; done
        (( issues += $#dangling ))
    fi
    if (( issues == 0 )); then
        print -r -- "ok: vault links are clean"
    else
        print -r -- "$issues issue(s) found"
    fi
    return $(( issues > 0 ? 1 : 0 ))
}


# ai-mem-sleep: the vault's "bedtime" pass -- consolidation, decay and lint in
# one run, modelled on how a brain sleeps. It NEVER prunes a lesson: the
# failure->fix records in _lessons/ are the durable knowledge that must survive,
# and reinforcement already strengthens them. Only ephemeral SESSION LOGS decay,
# and even they are ARCHIVED (moved under the project's _archive/, which
# ai-mem-search skips), never deleted -- git keeps every move reversible.
#
# Dry run by default: it reports what would move and nothing changes on disk.
# --apply performs the archive moves and backs the vault up. Tunables:
#   AI_MEM_SLEEP_KEEP        newest logs per project always kept hot (default 5)
#   AI_MEM_SLEEP_DAYS        archive logs older than this many days   (default 90)
#   AI_MEM_SLEEP_CONSOLIDATE flag a project with this many hot logs   (default 8)
ai-mem-sleep() {
    local apply=0
    [[ "${1:-}" == "--apply" ]] && apply=1

    zmodload zsh/datetime 2>/dev/null
    local keep="${AI_MEM_SLEEP_KEEP:-5}"
    local days="${AI_MEM_SLEEP_DAYS:-90}"
    local ripe="${AI_MEM_SLEEP_CONSOLIDATE:-8}"
    # Cut-off date as a string. Filenames carry YYYY-MM-DD, which sorts and
    # compares chronologically as text, so no BSD-vs-GNU `date` parsing is
    # needed -- strftime on an epoch offset is portable and dependency-free.
    local cutoff
    cutoff="$(strftime '%Y-%m-%d' $(( EPOCHSECONDS - days * 86400 )))"

    if (( apply )); then
        print -r -- "ai-mem-sleep: applying. Keep newest $keep per project; archive session logs dated before $cutoff."
    else
        print -r -- "ai-mem-sleep: dry run (nothing moves). Keep newest $keep per project; would archive logs dated before $cutoff."
    fi
    print -r -- "Lessons are never touched -- only ephemeral session logs, and they are archived, not deleted."
    print -r -- "--"

    local sessions_root="$AI_MEM_SESSION_DIR"
    if [[ ! -d "$sessions_root" ]]; then
        print -r -- "no session logs at $sessions_root -- nothing to do"
        return 0
    fi

    local -i total_archived=0
    local project pdir log sidecar stem logdate
    local -a logs stale
    local -i i hot remaining
    for pdir in "$sessions_root"/*(/N); do
        project="${pdir:t}"
        # Skip the archive dir itself and any bookkeeping dir (leading _ or .).
        [[ "$project" == [_.]* ]] && continue

        # Newest first: a log's name starts with the project slug, so name order
        # is date order within one project. (On) sorts by name, descending.
        logs=( "$pdir"/*.md(N.On) )
        (( ${#logs} )) || continue

        # The newest KEEP stay hot however old they are, so a dormant project
        # keeps a readable recent history instead of emptying out.
        hot=$(( keep < ${#logs} ? keep : ${#logs} ))
        stale=()
        for (( i = hot + 1; i <= ${#logs}; i++ )); do
            log="${logs[i]}"
            stem="${${log:t:r}%%_*}"      # "proj-2026-08-20_10-00-00.md" -> "proj-2026-08-20"
            logdate="${stem: -10}"          # -> "2026-08-20"
            [[ "$logdate" =~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' ]] || continue   # not a dated log
            [[ "$logdate" < "$cutoff" ]] || continue                          # not old enough
            stale+=( "$log" )
        done
        remaining=$(( ${#logs} - ${#stale} ))

        if (( ${#stale} )); then
            print -r -- "$project: ${#stale} log(s) to archive (of ${#logs}, keeping newest $hot)"
            if (( apply )); then
                mkdir -p "$pdir/_archive"
                for log in "${stale[@]}"; do
                    mv -- "$log" "$pdir/_archive/"
                    sidecar="${log:r}.startsha"
                    [[ -f "$sidecar" ]] && mv -- "$sidecar" "$pdir/_archive/"
                done
            fi
            (( total_archived += ${#stale} ))
        fi

        # Consolidation candidate: many still-hot logs are unconsolidated
        # knowledge -- a nudge to distil them into a durable lesson.
        if (( remaining >= ripe )); then
            print -r -- "$project: $remaining hot logs -- consolidation candidate (distil into a _lessons/ note)"
        fi
    done

    print -r -- "--"
    if (( apply && total_archived > 0 )); then
        __ai_mem_vault_backup
        print -r -- "Archived $total_archived session log(s) -- reversible: in each project's _archive/ and in git history."
    elif (( total_archived > 0 )); then
        print -r -- "Would archive $total_archived session log(s). Re-run with --apply to move them."
    else
        print -r -- "No session logs old enough to archive."
    fi

    print -r -- "--"
    print -r -- "lint:"
    ai-mem-lint
}

# ai-mem-sleep-schedule: run the bedtime pass on its own, nightly. A scheduled
# shell does not source ~/.zshrc, so the job sources the module directly
# ($AI_MEM_HOME/ai-mem.zsh) before calling ai-mem-sleep --apply. macOS uses a
# launchd LaunchAgent; every other platform uses crontab.
#
#   ai-mem-sleep-schedule                        print what it would install
#   ai-mem-sleep-schedule --install [--at HH:MM]  install it (default 03:00)
#   ai-mem-sleep-schedule --uninstall             remove it
#
# Dry run by default -- nothing is scheduled until --install. AI_MEM_LAUNCHAGENTS
# overrides where the plist is written (used by the tests).
ai-mem-sleep-schedule() {
    local action="print" at="03:00"
    while (( $# )); do
        case "$1" in
            --install)   action="install" ;;
            --uninstall) action="uninstall" ;;
            --at)        at="${2:-}"; shift ;;
            *) print -r -- "usage: ai-mem-sleep-schedule [--install|--uninstall] [--at HH:MM]"; return 2 ;;
        esac
        shift
    done
    if [[ ! "$at" =~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' ]]; then
        print -r -- "ai-mem-sleep-schedule: --at wants HH:MM (24-hour), got '$at'"
        return 2
    fi
    local hh="${at%%:*}" mm="${at##*:}"
    local module="$AI_MEM_HOME/ai-mem.zsh"
    local cmd="source ${(q)module}; ai-mem-sleep --apply"
    local label="app.ai-mem.sleep"
    local log="${AI_MEM_ROOT:h}/ai-mem-sleep.log"

    if [[ "$OSTYPE" == darwin* ]]; then
        local plist="${AI_MEM_LAUNCHAGENTS:-$HOME/Library/LaunchAgents}/${label}.plist"
        local body='<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>'"$label"'</string>
  <key>ProgramArguments</key>
  <array><string>/bin/zsh</string><string>-c</string><string>'"$cmd"'</string></array>
  <key>StartCalendarInterval</key>
  <dict><key>Hour</key><integer>'"${hh#0}"'</integer><key>Minute</key><integer>'"${mm#0}"'</integer></dict>
  <key>StandardOutPath</key><string>'"$log"'</string>
  <key>StandardErrorPath</key><string>'"$log"'</string>
</dict></plist>'
        case "$action" in
            print)
                print -r -- "would install a launchd agent (daily at $at):"
                print -r -- "  $plist"
                print -r -- "$body"
                print -r -- "--"
                print -r -- "install with: ai-mem-sleep-schedule --install --at $at" ;;
            install)
                mkdir -p "${plist:h}"
                print -r -- "$body" > "$plist" || { print -r -- "could not write $plist"; return 1 }
                if [[ -z "${AI_MEM_SLEEP_NO_LAUNCHCTL-}" ]] && command -v launchctl >/dev/null 2>&1; then
                    launchctl unload "$plist" 2>/dev/null
                    if launchctl load "$plist" 2>/dev/null; then
                        print -r -- "scheduled: $label runs daily at $at"
                    else
                        print -r -- "wrote $plist, but launchctl load failed -- it will load at next login"
                    fi
                else
                    print -r -- "wrote $plist (launchctl not found; loads at next login)"
                fi ;;
            uninstall)
                [[ -z "${AI_MEM_SLEEP_NO_LAUNCHCTL-}" ]] && command -v launchctl >/dev/null 2>&1 && launchctl unload "$plist" 2>/dev/null
                if [[ -f "$plist" ]]; then
                    rm -f "$plist" && print -r -- "removed $label"
                else
                    print -r -- "no schedule at $plist"
                fi ;;
        esac
        return 0
    fi

    # Linux and other: crontab. The comment marker lets --uninstall find its own
    # line without disturbing anything else the user has scheduled.
    local cronline="${mm#0} ${hh#0} * * * /bin/zsh -c '${cmd}' >> ${log} 2>&1  # ${label}"
    case "$action" in
        print)
            print -r -- "would add this crontab line (daily at $at):"
            print -r -- "  $cronline"
            print -r -- "--"
            print -r -- "install with: ai-mem-sleep-schedule --install --at $at" ;;
        install)
            if ! command -v crontab >/dev/null 2>&1; then
                print -r -- "crontab not found -- add this to your scheduler yourself:"
                print -r -- "  $cronline"
                return 1
            fi
            if { crontab -l 2>/dev/null | grep -v "# ${label}\$"; print -r -- "$cronline"; } | crontab -; then
                print -r -- "scheduled: crontab entry $label runs daily at $at"
            else
                print -r -- "crontab update failed"; return 1
            fi ;;
        uninstall)
            if ! command -v crontab >/dev/null 2>&1; then print -r -- "crontab not found"; return 1; fi
            crontab -l 2>/dev/null | grep -v "# ${label}\$" | crontab - && print -r -- "removed $label from crontab" ;;
    esac
}
# Full-text search across the vault. Plain grep -- no new dependency, and at
# vault scale (a personal notes collection, not a codebase) there is no real
# performance reason to reach for anything faster. Always resolves one hop
# out along any [[wikilinks]] on a matched line (see below) -- not a flag,
# because a flag only helps if whoever's calling this remembers it exists,
# and the whole point is not depending on that.
ai-mem-search() {
    local term="${1:-}"
    local project="${2:-}"
    if [[ -z "$term" ]]; then
        echo "Usage: ai-mem-search <term> [project]"
        return 1
    fi

    local search_root="$AI_MEM_ROOT"
    if [[ -n "$project" ]]; then
        search_root="$(__ai_mem_project_session_dir "$project")"
        if [[ ! -d "$search_root" ]]; then
            print -r -- "ai-mem-search: no session logs for project '$project'"
            return 1
        fi
    fi

    # -i: a case-sensitive default silently returns a confident "no matches"
    # for a term the vault genuinely holds under different casing. Measured on
    # a real vault: `precompact` found 0 case-sensitively and 3 with -i;
    # `Postgres` 56 vs 90. A false empty state is the worst possible answer
    # from a memory tool, because it is indistinguishable from the truth --
    # and the explicit empty-state message below is exactly what makes it
    # look authoritative.
    # -F: the caller is usually an agent passing a free-text term, where a
    # stray . ( | must match literally rather than as a regex metacharacter.
    local raw
    # --exclude-dir=_archive: session logs that ai-mem-sleep has retired are out
    # of the hot search path (their durable content lives on in a lesson). They
    # stay in git and on disk, just not in a default search.
    raw="$(grep -rniF --exclude-dir=.git --exclude-dir=_archive --exclude='_session_template.md' --exclude='_project_template.md' --exclude='_lesson_template.md' -- "$term" "$search_root" 2>/dev/null)"

    if [[ -z "$raw" ]]; then
        print -r -- "no matches for '$term' in $search_root"
        return 1
    fi

    # Newest-first: for a time-series log the most recent match is usually the
    # relevant one, so a large result set stays usable at a glance even without
    # ranking. Sort key is the YYYY-MM-DD_HH-MM-SS embedded in the filename;
    # lines with no such timestamp (e.g. _Global_Profile.md) sort last.
    #
    # One awk pass, not a shell loop. This used to spawn `grep -oE` AND `head`
    # per matched line, which cost 25s for a common term on a 486-file vault
    # -- while the grep that actually searched it took 0.16s. Measuring grep
    # alone said this command was fast; measuring the command said otherwise.
    # Interval syntax like {4} is avoided so this works on a stock BSD awk.
    # Lessons outrank everything else, then newest-first within each group.
    #
    # Recency alone was wrong for the case that matters most: hitting a blocker
    # you have hit before. Session logs outnumber lessons roughly four to one
    # and are always newer, so they swept the result set -- searching
    # "snapshot" on a real vault returned 25 session logs and none of the
    # THREE lessons that answer it exactly. The durable answer was in the
    # vault and unreachable.
    #
    # Sort key is rank + reinforcement + timestamp. "1" for _lessons/, "0"
    # for everything else, so a lesson with an old date still beats today's
    # chatter. Within the lessons tier, a lesson RECALLED more often ranks
    # above a once-seen one -- long-term potentiation for the vault: a pathway
    # that keeps firing is strengthened. Timestamp breaks ties below that.
    #
    # Reinforcement is the count of dated entries the lesson already carries.
    # ai-lesson appends one every time the same problem is hit again, so the
    # count is already in the data -- no separate counter to keep in sync (a
    # shadowed derived field is its own class of bug), and it is read in ONE
    # grep over the lesson headers, never a per-file scan. Only whole-vault
    # searches consult it; a project-scoped search sees no lessons anyway.
    local strengths=""
    [[ -z "$project" ]] && strengths="$(grep -rc '^## [0-9]' "$AI_MEM_ROOT/_lessons" 2>/dev/null)"

    local sorted
    sorted="$(awk -v root="$search_root/" '
        # First input: <lesson-file-path>:<entry-count>. Build the strength map.
        FNR == NR {
            if (match($0, /:[0-9]+$/)) {
                str[substr($0, 1, RSTART - 1)] = substr($0, RSTART + 1) + 0
            }
            next
        }
        {
            ts = "0000-00-00_00-00-00"
            if (match($0, /[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]_[0-9][0-9]-[0-9][0-9]-[0-9][0-9]/))
                ts = substr($0, RSTART, RLENGTH)
            rel = $0
            sub(root, "", rel)
            is_lesson = (rel ~ /^_lessons\//)
            rank = is_lesson ? "1" : "0"
            # The file this match came from, to look up its reinforcement count.
            path = $0
            sub(/:[0-9]+:.*$/, "", path)
            strength = is_lesson ? sprintf("%03d", str[path] + 0) : "000"
            print rank "|" strength "|" ts "|" $0
        }' <(print -r -- "$strengths") <(print -r -- "$raw") | sort -r | cut -d'|' -f4-)"

    # Bound the output. The consumer is normally an agent with a finite
    # context window, and an unbounded dump is actively harmful there in a
    # way it is not for a human who skims: a common term produced ~29k
    # tokens on a real vault, overflowing the host's tool-response cap and
    # getting silently truncated, so the agent could not tell "hidden" from
    # "absent". Near-miss padding is also the most damaging kind of
    # distractor for a model, so fewer, cleaner hits beat more of them.
    # Count goes FIRST -- the reader needs the size of the result set before
    # the result set, not after it.
    local total limit per_file
    total="$(print -r -- "$raw" | wc -l | tr -d ' ')"
    limit="${AI_MEM_SEARCH_LIMIT:-25}"
    per_file="${AI_MEM_SEARCH_PER_FILE:-1}"

    # Spend the line budget on distinct sources rather than on whichever note
    # happens to be chattiest. Measured on a real vault: 'prisma' matched 82
    # files, but one long session log took 9 of the 40 slots and the output
    # reached only 14 of them. Capping lines per file reaches roughly three
    # times as many notes for the same tokens, which is the number that
    # actually decides whether the answer is in there.
    #
    # Applied after the sort, so the lines kept from each file are its newest.
    # Only engage when the budget actually binds. If every match fits, showing
    # all of them beats withholding lines from a note that had three -- the
    # cap exists to allocate a scarce budget, and nothing is scarce here.
    local spread
    if (( total > limit )); then
        spread="$(print -r -- "$sorted" | awk -v cap="$per_file" '
            { f = $0; sub(/:[0-9]+:.*$/, "", f); if (++seen[f] <= cap) print }')"
    else
        spread="$sorted"
    fi
    local files_shown
    files_shown="$(print -r -- "$spread" | head -n "$limit" | awk '
        { f = $0; sub(/:[0-9]+:.*$/, "", f); seen[f] = 1 } END { print length(seen) }')"

    print -r -- "$total match(es) for '$term'"
    print -r -- "paths below $search_root"
    print -r -- "--"
    # Strip the repeated vault root (a third to a half of all output bytes on
    # a real vault, with zero information lost -- it is printed once above)
    # and clamp very long lines, which are common in prose notes.
    local shown
    shown="$(print -r -- "$spread" | head -n "$limit")"
    print -r -- "$shown" \
        | sed "s|^${search_root}/||" \
        | awk '{ if (length($0) > 200) print substr($0, 1, 200) " [...]"; else print }'

    local shown_n
    shown_n="$(print -r -- "$shown" | wc -l | tr -d ' ')"
    if (( total > shown_n )); then
        print -r -- "--"
        # The withheld count stays explicit. "showing 25 of 240" implies it,
        # but the reader has to be able to tell "hidden" from "absent" without
        # doing arithmetic -- that distinction is the whole reason this line
        # exists.
        print -r -- "showing $shown_n of $total ($(( total - shown_n )) hidden), across $files_shown file(s), at most $per_file line(s) each -- for more lines per file raise AI_MEM_SEARCH_PER_FILE, or narrow with: ai-mem-search '$term' <project>"
    fi
    # One hop out: resolve [[wikilinks]] found on matched lines to their
    # target note (currently: project notes only -- the confirmed use case
    # is a _lessons entry linking the project(s) it hit) and show a short
    # excerpt, so a match doesn't leave you to manually chase the link
    # yourself.
    local links link target excerpt
    links="$(print -r -- "$raw" | grep -oE '\[\[[^]]+\]\]' | sed -E 's/^\[\[|\]\]$//g' | sort -u)"
    [[ -n "$links" ]] || return 0

    print -r -- "--"
    print -r -- "one hop out:"
    while IFS= read -r link; do
        [[ -n "$link" ]] || continue
        target="$AI_MEM_PROJECT_DIR/${link}.md"
        [[ -f "$target" ]] || continue
        excerpt="$(grep -m1 -A1 '^\* \*\*Purpose:\*\*' "$target" 2>/dev/null | tail -1)"
        [[ -n "$excerpt" ]] || excerpt="$(sed -n '/^---$/,/^---$/!p' "$target" | grep -m1 -v '^$')"
        print -r -- "  [[$link]] -> $target"
        [[ -n "$excerpt" ]] && print -r -- "    $excerpt"
    done <<< "$links"
}
