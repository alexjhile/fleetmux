#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2059
# Sync — auto-detect and pull context from sessions with direct work
# Designed to run at conversation start — fast for synced sessions, pulls context for fresh ones
[[ -n "${_AIOS_SYNC_LOADED:-}" ]] && return 0; _AIOS_SYNC_LOADED=1

source "$(dirname "${BASH_SOURCE[0]}")/config.sh"
source "$(dirname "${BASH_SOURCE[0]}")/registry.sh"
source "$(dirname "${BASH_SOURCE[0]}")/status.sh"
source "$(dirname "${BASH_SOURCE[0]}")/display.sh"
source "$(dirname "${BASH_SOURCE[0]}")/brain.sh"
source "$(dirname "${BASH_SOURCE[0]}")/drift.sh"

SYNC_CACHE_DIR="${AIOS_DIR}/.sync-cache"

# Check VPS memory mtime via SSH (returns epoch timestamp)
check_vps_memory_mtime() {
    local host="$1"
    local path="$2"
    local out_file="$3"
    local encoded
    encoded=$(echo "$path" | sed 's|/$||' | sed 's|/|-|g' | sed 's|_|-|g')

    local result
    result=$(ssh -o ConnectTimeout=8 -o StrictHostKeyChecking=no "$host" \
        "stat -c '%Y' \"\$HOME/.claude/projects/${encoded}/memory/MEMORY.md\" 2>/dev/null || echo 0" 2>/dev/null)

    echo "${result:-0}" > "$out_file"
}

# Pull context summary from VPS (lightweight — just memory + git log)
pull_vps_context_summary() {
    local name="$1"
    local host="$2"
    local path="$3"
    local out_file="$4"
    local encoded
    encoded=$(echo "$path" | sed 's|/$||' | sed 's|/|-|g' | sed 's|_|-|g')

    local result
    result=$(ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no "$host" "
        MEM=\"\$HOME/.claude/projects/${encoded}/memory/MEMORY.md\"
        if [ -f \"\$MEM\" ]; then
            echo '=== MEMORY (last 15 lines) ==='
            tail -15 \"\$MEM\"
        fi
        echo '=== GIT ==='
        cd '${path}' 2>/dev/null && git log --oneline -3 2>/dev/null
        echo '=== DIRTY ==='
        cd '${path}' 2>/dev/null && git diff --stat HEAD 2>/dev/null | tail -3
    " 2>/dev/null)

    echo "$result" > "$out_file"
}

run_sync() {
    mkdir -p "$SYNC_CACHE_DIR" 2>/dev/null

    echo ""
    print_info "fleetmux Sync — checking for direct work..."
    echo ""

    local fresh_sessions=()
    local vps_pids=()
    local vps_names=()
    local tmp_dir
    tmp_dir=$(mktemp -d)

    # ── Check local sessions (instant) ──
    while IFS= read -r name; do
        local type path
        type=$(registry_get_field "$name" "type")
        path=$(registry_get_field "$name" "path")
        [[ "$type" == "remote" ]] && continue

        local status
        status=$(check_direct_work "$name" "$type" "$path")
        if [[ "$status" == "fresh" ]]; then
            fresh_sessions+=("$name")
            printf "  ${C_YELLOW}⚡${C_RESET} %-14s local — direct work detected\n" "$name"
        fi
    done < <(registry_list_names)

    # ── Check VPS sessions (parallel SSH) ──
    while IFS= read -r name; do
        local type path host
        type=$(registry_get_field "$name" "type")
        [[ "$type" != "remote" ]] && continue
        path=$(registry_get_field "$name" "path")
        host=$(registry_get_field "$name" "host")

        check_vps_memory_mtime "$host" "$path" "${tmp_dir}/${name}.mtime" &
        vps_pids+=($!)
        vps_names+=("$name")
    done < <(registry_list_names)

    # Wait for VPS checks
    for pid in "${vps_pids[@]}"; do
        wait "$pid" 2>/dev/null
    done

    # Evaluate VPS results
    for name in "${vps_names[@]}"; do
        local mtime_file="${tmp_dir}/${name}.mtime"
        [[ ! -f "$mtime_file" ]] && continue

        local memory_ts
        memory_ts=$(tr -d '[:space:]' < "$mtime_file" 2>/dev/null)
        [[ -z "$memory_ts" || "$memory_ts" == "0" ]] && continue

        # Compare to last AIOS task
        local last_task_ts=0
        if [[ -f "$TASKS_FILE" ]]; then
            local last_task_at
            last_task_at=$(jq -r --arg s "$name" \
                'first(.[] | select(.session == $s)).dispatched_at // empty' \
                "$TASKS_FILE" 2>/dev/null)
            if [[ -n "$last_task_at" ]]; then
                last_task_ts=$(iso_to_epoch "$last_task_at")
            fi
        fi

        if [[ "$memory_ts" -gt "$last_task_ts" ]]; then
            fresh_sessions+=("$name")
            printf "  ${C_YELLOW}⚡${C_RESET} %-14s remote — direct work detected\n" "$name"
        fi
    done

    # ── Pull context for fresh sessions ──
    if [[ ${#fresh_sessions[@]} -eq 0 ]]; then
        printf "  ${C_GREEN}✓${C_RESET} All sessions synced — no direct work detected\n"
        echo ""
        rm -rf "$tmp_dir"
        return
    fi

    echo ""
    printf "  Pulling context from %d session(s)...\n\n" "${#fresh_sessions[@]}"

    for name in "${fresh_sessions[@]}"; do
        local type path host
        type=$(registry_get_field "$name" "type")
        path=$(registry_get_field "$name" "path")
        host=$(registry_get_field "$name" "host")

        printf "  ${C_BOLD}── %s ──${C_RESET}\n" "$name"

        case "$type" in
            local|utility)
                local encoded
                encoded=$(echo "$path" | sed 's|/$||' | sed 's|/|-|g' | sed 's|_|-|g')
                local memory_file="$HOME/.claude/projects/${encoded}/memory/MEMORY.md"

                # Show last 15 lines of memory
                if [[ -f "$memory_file" ]]; then
                    printf "  ${C_DIM}Memory (recent):${C_RESET}\n"
                    tail -15 "$memory_file" | sed 's/^/    /'
                fi

                # Git log
                if [[ -d "${path}/.git" ]]; then
                    printf "  ${C_DIM}Recent commits:${C_RESET}\n"
                    git -C "$path" log --oneline -3 2>/dev/null | sed 's/^/    /'

                    local dirty
                    dirty=$(git -C "$path" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
                    if [[ "$dirty" -gt 0 ]]; then
                        printf "  ${C_DIM}Dirty files:${C_RESET} %s\n" "$dirty"
                    fi
                fi
                ;;
            remote)
                # Pull in background was already done, or do it now
                pull_vps_context_summary "$name" "$host" "$path" "${tmp_dir}/${name}.ctx"
                if [[ -f "${tmp_dir}/${name}.ctx" ]]; then
                    sed 's/^/    /' "${tmp_dir}/${name}.ctx"
                fi
                ;;
        esac
        echo ""
    done

    rm -rf "$tmp_dir"

    # Drift check — auto-pull local clones that are behind origin
    printf "\n"
    print_info "Drift check — syncing local clones with origin..."
    sync_drift_check

    # Auto-sync brain state and commit if changes exist
    printf "\n"
    print_info "Brain sync — backing up memory files..."
    brain_sync --quiet
    brain_commit --push 2>/dev/null || true
}
