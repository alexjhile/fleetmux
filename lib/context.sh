#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2059
# Context — read a session's Claude Code memory, git state, and task history
# This is the sync bridge between the controller and direct session work
[[ -n "${_AIOS_CONTEXT_LOADED:-}" ]] && return 0; _AIOS_CONTEXT_LOADED=1

source "$(dirname "${BASH_SOURCE[0]}")/config.sh"
source "$(dirname "${BASH_SOURCE[0]}")/registry.sh"
source "$(dirname "${BASH_SOURCE[0]}")/display.sh"

# Encode a filesystem path to Claude's memory directory format
# /home/you/code/myproject → -home-you-code-myproject
encode_claude_path() {
    local path="$1"
    # Strip trailing slash, replace / and _ with -
    echo "$path" | sed 's|/$||' | sed 's|/|-|g' | sed 's|_|-|g'
}

# Read context from a local session
read_local_context() {
    local name="$1"
    local path="$2"
    local encoded
    encoded=$(encode_claude_path "$path")
    local memory_dir="$HOME/.claude/projects/${encoded}/memory"

    # ── Memory Files ──
    printf "\n  ${C_BOLD}${C_CYAN}Memory Files:${C_RESET}\n"
    if [[ -d "$memory_dir" ]]; then
        local file_count=0
        while IFS= read -r f; do
            local fname
            fname=$(basename "$f")
            local mod_time size
            mod_time=$(epoch_fmt "$(file_mtime "$f")" "+%Y-%m-%d %H:%M")
            [[ -z "$mod_time" ]] && mod_time="?"
            size=$(wc -c < "$f" 2>/dev/null | tr -d ' ')
            printf "  ${C_DIM}%-30s %s  %s bytes${C_RESET}\n" "$fname" "$mod_time" "$size"
            file_count=$((file_count + 1))
        done < <(find "$memory_dir" -type f -name "*.md" 2>/dev/null | sort)

        if [[ $file_count -eq 0 ]]; then
            printf "  ${C_DIM}(no memory files)${C_RESET}\n"
        else
            # Read MEMORY.md content (truncated)
            local memory_file="${memory_dir}/MEMORY.md"
            if [[ -f "$memory_file" ]]; then
                printf "\n  ${C_BOLD}MEMORY.md:${C_RESET}\n"
                head -40 "$memory_file" | sed 's/^/  /'
                local total_lines
                total_lines=$(wc -l < "$memory_file" | tr -d ' ')
                if [[ $total_lines -gt 40 ]]; then
                    printf "\n  ${C_DIM}... (%d more lines)${C_RESET}\n" $((total_lines - 40))
                fi
            fi
        fi
    else
        printf "  ${C_DIM}(no memory directory)${C_RESET}\n"
    fi

    # ── Git Status ──
    printf "\n  ${C_BOLD}${C_CYAN}Git Status:${C_RESET}\n"
    if [[ -d "${path}/.git" ]]; then
        local branch dirty
        branch=$(git -C "$path" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "?")
        dirty=$(git -C "$path" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
        printf "  Branch: ${C_BOLD}%s${C_RESET}  Dirty: %s\n" "$branch" "$dirty"

        printf "\n  ${C_BOLD}Recent commits:${C_RESET}\n"
        git -C "$path" log --oneline -5 2>/dev/null | sed 's/^/  /'

        if [[ "$dirty" -gt 0 ]]; then
            printf "\n  ${C_BOLD}Uncommitted changes:${C_RESET}\n"
            git -C "$path" status --porcelain 2>/dev/null | head -10 | sed 's/^/  /'
            if [[ "$dirty" -gt 10 ]]; then
                printf "  ${C_DIM}... (%d more files)${C_RESET}\n" $((dirty - 10))
            fi
        fi
    else
        printf "  ${C_DIM}(not a git repository)${C_RESET}\n"
    fi
}

# Read context from a remote (VPS) session
read_remote_context() {
    local name="$1"
    local path="$2"
    local host="$3"
    local encoded
    encoded=$(encode_claude_path "$path")

    printf "\n  ${C_DIM}Reading from %s...${C_RESET}\n" "$host"

    # Single SSH call to gather everything
    local result
    result=$(ssh -o ConnectTimeout=10 "$host" "
        MEMORY_DIR=\"\$HOME/.claude/projects/${encoded}/memory\"

        # Memory files listing
        echo '===MEMORY_FILES==='
        if [ -d \"\$MEMORY_DIR\" ]; then
            find \"\$MEMORY_DIR\" -type f -name '*.md' -exec sh -c 'for f; do echo \"\$(basename \"\$f\")||\$(wc -c < \"\$f\" | tr -d \" \")\" ; done' _ {} +
        else
            echo 'NONE'
        fi

        # MEMORY.md content
        echo '===MEMORY_CONTENT==='
        if [ -f \"\$MEMORY_DIR/MEMORY.md\" ]; then
            head -40 \"\$MEMORY_DIR/MEMORY.md\"
            total=\$(wc -l < \"\$MEMORY_DIR/MEMORY.md\" | tr -d ' ')
            if [ \"\$total\" -gt 40 ]; then
                echo \"===TRUNCATED:\$total===\"
            fi
        else
            echo 'NONE'
        fi

        # Git info
        echo '===GIT_INFO==='
        if [ -d '${path}/.git' ]; then
            cd '${path}'
            echo \"BRANCH:\$(git rev-parse --abbrev-ref HEAD 2>/dev/null)\"
            echo \"DIRTY:\$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')\"
            echo '===GIT_LOG==='
            git log --oneline -5 2>/dev/null
            echo '===GIT_DIRTY==='
            git status --porcelain 2>/dev/null | head -10
        else
            echo 'NOGIT'
        fi
    " 2>/dev/null)

    if [[ -z "$result" ]]; then
        printf "  ${C_RED}Unreachable${C_RESET}\n"
        return 1
    fi

    # ── Parse and display memory files ──
    printf "\n  ${C_BOLD}${C_CYAN}Memory Files:${C_RESET}\n"
    local in_memory=false in_content=false in_git=false in_log=false in_dirty=false
    local branch="" dirty="0"
    local in_content_header="" log_header="" dirty_header=""

    while IFS= read -r line; do
        case "$line" in
            '===MEMORY_FILES===') in_memory=true; in_content=false; in_git=false; in_log=false; in_dirty=false; continue ;;
            '===MEMORY_CONTENT===') in_memory=false; in_content=true; continue ;;
            '===GIT_INFO===') in_content=false; in_git=true; continue ;;
            '===GIT_LOG===') in_git=false; in_log=true; continue ;;
            '===GIT_DIRTY===') in_log=false; in_dirty=true; continue ;;
        esac

        if $in_memory; then
            if [[ "$line" == "NONE" ]]; then
                printf "  ${C_DIM}(no memory directory)${C_RESET}\n"
            else
                local fname fsize
                fname="${line%%||*}"
                fsize="${line##*||}"
                printf "  %-30s %s bytes\n" "$fname" "$fsize"
            fi
        elif $in_content; then
            if [[ "$line" == "NONE" ]]; then
                :
            elif [[ "$line" == ===TRUNCATED:*=== ]]; then
                local total
                total=$(echo "$line" | sed 's/===TRUNCATED://' | sed 's/===//')
                printf "\n  ${C_DIM}... (%d more lines)${C_RESET}\n" $((total - 40))
            else
                if [[ "$in_content_header" != "shown" ]]; then
                    printf "\n  ${C_BOLD}MEMORY.md:${C_RESET}\n"
                    in_content_header="shown"
                fi
                printf "  %s\n" "$line"
            fi
        elif $in_git; then
            if [[ "$line" == "NOGIT" ]]; then
                printf "\n  ${C_BOLD}${C_CYAN}Git Status:${C_RESET}\n"
                printf "  ${C_DIM}(not a git repository)${C_RESET}\n"
            elif [[ "$line" == BRANCH:* ]]; then
                branch="${line#BRANCH:}"
            elif [[ "$line" == DIRTY:* ]]; then
                dirty="${line#DIRTY:}"
                printf "\n  ${C_BOLD}${C_CYAN}Git Status:${C_RESET}\n"
                printf "  Branch: ${C_BOLD}%s${C_RESET}  Dirty: %s\n" "$branch" "$dirty"
            fi
        elif $in_log; then
            if [[ -z "$log_header" ]]; then
                printf "\n  ${C_BOLD}Recent commits:${C_RESET}\n"
                log_header="shown"
            fi
            printf "  %s\n" "$line"
        elif $in_dirty; then
            if [[ -n "$line" ]]; then
                if [[ -z "$dirty_header" ]]; then
                    printf "\n  ${C_BOLD}Uncommitted changes:${C_RESET}\n"
                    dirty_header="shown"
                fi
                printf "  %s\n" "$line"
            fi
        fi
    done <<< "$result"
}

# Main context command
run_context() {
    local name="$1"

    if ! registry_session_exists "$name"; then
        print_error "Session '$name' not found in registry"
        return 1
    fi

    local type path host
    type=$(registry_get_field "$name" "type")
    path=$(registry_get_field "$name" "path")
    host=$(registry_get_field "$name" "host")

    echo ""
    printf "  ${C_BOLD}Context: %s${C_RESET} (%s — %s)\n" "$name" "$type" "$path"

    case "$type" in
        local|utility)
            read_local_context "$name" "$path"
            ;;
        remote)
            read_remote_context "$name" "$path" "$host"

            # Also show local clone status if local_path exists
            local local_path
            local_path=$(jq -r --arg n "$name" '.[] | select(.name == $n) | .local_path // empty' "$SESSIONS_FILE" 2>/dev/null)
            if [[ -n "$local_path" && -d "$local_path/.git" ]]; then
                printf "\n  ${C_BOLD}${C_CYAN}Local Clone:${C_RESET} %s\n" "$local_path"
                local branch dirty
                branch=$(git -C "$local_path" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "?")
                dirty=$(git -C "$local_path" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
                printf "  Branch: ${C_BOLD}%s${C_RESET}  Dirty: %s\n" "$branch" "$dirty"
                if [[ "$dirty" -gt 0 ]]; then
                    printf "  ${C_DIM}Uncommitted:${C_RESET}\n"
                    git -C "$local_path" status --porcelain 2>/dev/null | head -5 | sed 's/^/    /'
                fi
            fi
            ;;
    esac

    # ── Task History ──
    printf "\n  ${C_BOLD}${C_CYAN}Recent Tasks:${C_RESET}\n"
    if [[ -f "$TASKS_FILE" ]]; then
        local task_count
        task_count=$(jq --arg s "$name" '[.[] | select(.session == $s)] | length' "$TASKS_FILE" 2>/dev/null)
        if [[ "$task_count" -gt 0 ]]; then
            jq -r --arg s "$name" \
                '[.[] | select(.session == $s)][:5] | .[] | "  \(.dispatched_at[11:16])  \(.mode)  \(.status)  \(.task)"' \
                "$TASKS_FILE" 2>/dev/null
        else
            printf "  ${C_DIM}(no tasks dispatched via fleetmux)${C_RESET}\n"
        fi
    else
        printf "  ${C_DIM}(no task history)${C_RESET}\n"
    fi

    echo ""
}
