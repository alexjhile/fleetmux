#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2059
# Brain — persistent memory backup to git
# Syncs all Claude Code memory files into ./brain/ for centralized backup
[[ -n "${_AIOS_BRAIN_LOADED:-}" ]] && return 0; _AIOS_BRAIN_LOADED=1

source "$(dirname "${BASH_SOURCE[0]}")/config.sh"
source "$(dirname "${BASH_SOURCE[0]}")/registry.sh"
source "$(dirname "${BASH_SOURCE[0]}")/display.sh"

BRAIN_DIR="${BRAIN_DIR:-${AIOS_DIR}/brain}"

# Encode a filesystem path to Claude's memory directory format
# /home/you/code/myproject → -home-you-code-myproject
_brain_encode_path() {
    local path="$1"
    echo "$path" | sed 's|/$||' | sed 's|/|-|g' | sed 's|_|-|g'
}

# Get the Claude projects base dir (overridable for tests)
_brain_claude_projects_dir() {
    echo "${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}"
}

# Sync memory files from a local session into brain/<name>/
# Usage: brain_sync_local <name> <path>
brain_sync_local() {
    local name="$1"
    local path="$2"
    local encoded
    encoded=$(_brain_encode_path "$path")
    local projects_dir
    projects_dir=$(_brain_claude_projects_dir)
    local memory_dir="${projects_dir}/${encoded}/memory"

    if [[ ! -d "$memory_dir" ]]; then
        return 0
    fi

    # Check if there are any .md files before creating dest dir
    local file_list
    file_list=$(find "$memory_dir" -maxdepth 1 -type f -name "*.md" 2>/dev/null)
    if [[ -z "$file_list" ]]; then
        return 0
    fi

    local dest="${BRAIN_DIR}/${name}"
    mkdir -p "$dest"

    # Copy all .md files from memory dir
    while IFS= read -r f; do
        cp "$f" "$dest/"
    done <<< "$file_list"

    # Remove files in brain that no longer exist in source
    while IFS= read -r bf; do
        local basename_f
        basename_f=$(basename "$bf")
        if [[ ! -f "${memory_dir}/${basename_f}" ]]; then
            rm "$bf"
        fi
    done < <(find "$dest" -maxdepth 1 -type f -name "*.md" 2>/dev/null)
}

# Sync memory files from a remote (VPS) session into brain/<name>/
# Usage: brain_sync_remote <name> <path> <host>
brain_sync_remote() {
    local name="$1"
    local path="$2"
    local host="$3"
    local encoded
    encoded=$(_brain_encode_path "$path")

    local dest="${BRAIN_DIR}/${name}"
    mkdir -p "$dest"

    # Single SSH call: list files + cat their contents with delimiters
    local result
    result=$(ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no "$host" "
        MEMORY_DIR=\"\$HOME/.claude/projects/${encoded}/memory\"
        if [ -d \"\$MEMORY_DIR\" ]; then
            for f in \"\$MEMORY_DIR\"/*.md; do
                [ -f \"\$f\" ] || continue
                echo \"===FILE:\$(basename \"\$f\")===\"
                cat \"\$f\"
            done
            echo '===END==='
        else
            echo '===EMPTY==='
        fi
    " 2>/dev/null)

    if [[ -z "$result" || "$result" == *"===EMPTY==="* ]]; then
        return 0
    fi

    # Parse delimited output into individual files
    local current_file=""
    local current_content=""
    while IFS= read -r line; do
        if [[ "$line" == ===FILE:*=== ]]; then
            # Write previous file if any
            if [[ -n "$current_file" ]]; then
                printf '%s\n' "$current_content" > "${dest}/${current_file}"
            fi
            current_file="${line#===FILE:}"
            current_file="${current_file%===}"
            current_content=""
        elif [[ "$line" == "===END===" ]]; then
            if [[ -n "$current_file" ]]; then
                printf '%s\n' "$current_content" > "${dest}/${current_file}"
            fi
        else
            if [[ -z "$current_content" ]]; then
                current_content="$line"
            else
                current_content="${current_content}
${line}"
            fi
        fi
    done <<< "$result"
}

# Copy tasks.json snapshot into brain/
brain_sync_tasks() {
    mkdir -p "$BRAIN_DIR"
    if [[ -f "$TASKS_FILE" ]]; then
        cp "$TASKS_FILE" "${BRAIN_DIR}/_tasks.json"
    fi
}

# Snapshot global Claude Code config files (~/.claude/settings.json + ~/.claude.json)
# into brain/_global/. These hold per-machine state (MCP servers, model prefs, project
# IDs, GrowthBook flags) and getting clobbered = loss. Validate JSON before copy so
# we never archive a half-written file.
brain_sync_global_config() {
    local out="${BRAIN_DIR}/_global"
    mkdir -p "$out"
    local copied=0
    for src in "${HOME}/.claude.json" "${HOME}/.claude/settings.json"; do
        [[ -f "$src" ]] || continue
        if python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$src" 2>/dev/null; then
            local base
            base=$(basename "$src")
            # ~/.claude.json -> claude.json ; ~/.claude/settings.json -> settings.json
            cp "$src" "${out}/${base}"
            copied=$((copied + 1))
        else
            printf "  ${C_YELLOW}⚠ skipped %s — invalid JSON, not snapshotted${C_RESET}\n" "$src" >&2
        fi
    done
    return 0
}

# Sync all sessions (local + remote in parallel)
# Usage: brain_sync [--quiet]
brain_sync() {
    local quiet=false
    [[ "${1:-}" == "--quiet" ]] && quiet=true

    mkdir -p "$BRAIN_DIR"

    local synced=0
    local vps_pids=()
    local vps_names=()

    # Sync local sessions
    while IFS= read -r name; do
        local type path
        type=$(registry_get_field "$name" "type")
        path=$(registry_get_field "$name" "path")

        case "$type" in
            local|utility)
                brain_sync_local "$name" "$path"
                if [[ -d "${BRAIN_DIR}/${name}" ]] && [[ -n "$(ls -A "${BRAIN_DIR}/${name}" 2>/dev/null)" ]]; then
                    synced=$((synced + 1))
                    $quiet || printf "  ${C_DIM}✓ %s${C_RESET}\n" "$name"
                fi
                ;;
            remote)
                local host
                host=$(registry_get_field "$name" "host")
                brain_sync_remote "$name" "$path" "$host" &
                vps_pids+=($!)
                vps_names+=("$name")
                ;;
        esac
    done < <(registry_list_names)

    # Optionally also sync the "controller" session's memory — a session whose
    # working dir is CLAUDE_CODE_ROOT itself (e.g. a top-level orchestrator that
    # manages the others). Enabled only when AIOS_CONTROLLER_SESSION is set to
    # that session's name; off by default.
    if [[ -n "${AIOS_CONTROLLER_SESSION:-}" ]]; then
        local ctrl="${AIOS_CONTROLLER_SESSION}"
        local ctrl_encoded
        ctrl_encoded=$(_brain_encode_path "$CLAUDE_CODE_ROOT")
        local projects_dir
        projects_dir=$(_brain_claude_projects_dir)
        local ctrl_memory="${projects_dir}/${ctrl_encoded}/memory"

        if [[ -d "$ctrl_memory" ]]; then
            mkdir -p "${BRAIN_DIR}/${ctrl}"
            while IFS= read -r f; do
                cp "$f" "${BRAIN_DIR}/${ctrl}/"
            done < <(find "$ctrl_memory" -maxdepth 1 -type f -name "*.md" 2>/dev/null)
            if [[ -n "$(ls -A "${BRAIN_DIR}/${ctrl}" 2>/dev/null)" ]]; then
                synced=$((synced + 1))
                $quiet || printf "  ${C_DIM}✓ %s${C_RESET}\n" "$ctrl"
            fi
        fi
    fi

    # Wait for VPS syncs
    for i in "${!vps_pids[@]}"; do
        if wait "${vps_pids[$i]}" 2>/dev/null; then
            local vname="${vps_names[$i]}"
            if [[ -d "${BRAIN_DIR}/${vname}" ]] && [[ -n "$(ls -A "${BRAIN_DIR}/${vname}" 2>/dev/null)" ]]; then
                synced=$((synced + 1))
                $quiet || printf "  ${C_DIM}✓ %s (remote)${C_RESET}\n" "$vname"
            fi
        else
            local vname="${vps_names[$i]}"
            $quiet || printf "  ${C_YELLOW}⚠ %s — unreachable${C_RESET}\n" "$vname"
        fi
    done

    # Copy tasks.json
    brain_sync_tasks

    # Snapshot global Claude Code config (~/.claude.json + settings.json)
    brain_sync_global_config

    $quiet || printf "\n  Synced %d session(s) into brain/\n" "$synced"
    return 0
}

# Commit brain changes to git
# Usage: brain_commit [--push]
brain_commit() {
    local push=false
    [[ "${1:-}" == "--push" ]] && push=true

    if [[ ! -d "${AIOS_DIR}/.git" ]]; then
        print_error "fleetmux directory is not a git repository"
        return 1
    fi

    cd "$AIOS_DIR" || return 1

    # Stage brain/ changes
    git add brain/ 2>/dev/null

    # Check if there's anything to commit
    if git diff --cached --quiet 2>/dev/null; then
        printf "  ${C_DIM}brain: nothing to commit (clean)${C_RESET}\n"
        return 0
    fi

    # Count sessions with changes
    local changed_count
    changed_count=$(git diff --cached --name-only 2>/dev/null | grep '^brain/' | sed 's|^brain/||' | cut -d/ -f1 | sort -u | wc -l | tr -d ' ')
    local date_str
    date_str=$(date +"%Y-%m-%d %H:%M")

    git commit -q -m "brain: sync ${changed_count} session(s) (${date_str})" 2>/dev/null

    if $push; then
        if git remote get-url origin &>/dev/null; then
            git push -q 2>/dev/null && printf "  ${C_GREEN}✓${C_RESET} brain committed and pushed\n" || printf "  ${C_YELLOW}⚠${C_RESET} brain committed but push failed\n"
        else
            printf "  ${C_GREEN}✓${C_RESET} brain committed (no remote)\n"
        fi
    else
        printf "  ${C_GREEN}✓${C_RESET} brain committed\n"
    fi
}

# Show what changed since last commit
brain_diff() {
    if [[ ! -d "${AIOS_DIR}/.git" ]]; then
        print_error "fleetmux directory is not a git repository"
        return 1
    fi

    cd "$AIOS_DIR" || return 1

    # Check for uncommitted brain changes
    local changes
    changes=$(git diff --name-only -- brain/ 2>/dev/null; git diff --cached --name-only -- brain/ 2>/dev/null; git ls-files --others --exclude-standard -- brain/ 2>/dev/null)

    if [[ -z "$changes" ]]; then
        printf "  ${C_DIM}brain: no changes since last commit${C_RESET}\n"
        return 0
    fi

    printf "  ${C_BOLD}Brain changes since last commit:${C_RESET}\n"
    echo "$changes" | sort -u | while IFS= read -r f; do
        printf "  ${C_YELLOW}M${C_RESET} %s\n" "$f"
    done
}

# Count sessions in brain/
brain_session_count() {
    if [[ ! -d "$BRAIN_DIR" ]]; then
        echo "0"
        return
    fi
    local count=0
    while IFS= read -r d; do
        [[ -d "$d" ]] && count=$((count + 1))
    done < <(find "$BRAIN_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
    echo "$count"
}
