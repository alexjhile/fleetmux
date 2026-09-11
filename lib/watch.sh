#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2059
# Watch — live terminal dashboard with auto-refresh
# VPS health cached every 60s, session state every cycle
[[ -n "${_AIOS_WATCH_LOADED:-}" ]] && return 0; _AIOS_WATCH_LOADED=1

source "$(dirname "${BASH_SOURCE[0]}")/config.sh"
source "$(dirname "${BASH_SOURCE[0]}")/registry.sh"
source "$(dirname "${BASH_SOURCE[0]}")/status.sh"

HEALTH_CACHE_DIR=""
HEALTH_CACHE_AGE=0
HEALTH_CACHE_INTERVAL=60

# Get last meaningful line from a tmux pane
get_last_line() {
    local name="$1"
    local max_chars="${2:-60}"

    if ! tmux_window_exists "$name"; then
        echo "-"
        return
    fi

    local content
    content=$(tmux capture-pane -t "${AIOS_TMUX_SESSION}:${name}" -p -S -5 2>/dev/null)

    if [[ -z "$content" ]]; then
        echo "-"
        return
    fi

    local last_line
    last_line=$(echo "$content" | grep -v '^$' | tail -1 | sed 's/\x1b\[[0-9;]*m//g' | head -c "$max_chars")

    if [[ -z "$last_line" ]]; then
        echo "-"
    else
        echo "$last_line"
    fi
}

# Refresh VPS health cache (background SSH calls)
refresh_health_cache() {
    local now
    now=$(date +%s)

    # Only refresh if cache is stale
    if [[ $((now - HEALTH_CACHE_AGE)) -lt $HEALTH_CACHE_INTERVAL ]] && [[ -d "$HEALTH_CACHE_DIR" ]]; then
        return
    fi

    [[ -z "$HEALTH_CACHE_DIR" ]] && HEALTH_CACHE_DIR=$(mktemp -d)
    HEALTH_CACHE_AGE=$now

    # Launch parallel SSH checks
    while IFS= read -r name; do
        local type host
        type=$(registry_get_field "$name" "type")
        [[ "$type" != "remote" ]] && continue
        host=$(registry_get_field "$name" "host")

        (
            local result
            result=$(ssh -n -o ConnectTimeout=8 -o StrictHostKeyChecking=no "$host" \
                'echo "DISK:$(df -h / | tail -1 | awk "{print \$5}")"; echo "MEM:$(free -m 2>/dev/null | grep Mem | awk "{printf \"%d/%dMB\", \$3, \$2}")"; echo "PM2:$(pm2 jlist 2>/dev/null | jq "length" 2>/dev/null || echo "?")"' 2>/dev/null)

            if [[ -n "$result" ]]; then
                local disk mem pm2
                disk=$(echo "$result" | grep "^DISK:" | sed 's/^DISK://')
                mem=$(echo "$result" | grep "^MEM:" | sed 's/^MEM://')
                pm2=$(echo "$result" | grep "^PM2:" | sed 's/^PM2://')
                echo "${disk}|${mem}|${pm2}" > "${HEALTH_CACHE_DIR}/${name}.health"
            else
                echo "?|?|?" > "${HEALTH_CACHE_DIR}/${name}.health"
            fi
        ) &
    done < <(registry_list_names)
}

# Get cached health for a VPS session (non-blocking)
get_cached_health() {
    local name="$1"
    local cache_file="${HEALTH_CACHE_DIR}/${name}.health"
    if [[ -f "$cache_file" ]]; then
        cat "$cache_file"
    else
        echo "...|...|..."
    fi
}

# Draw the dashboard
draw_dashboard() {
    local cols
    cols=$(tput cols 2>/dev/null || echo 120)
    local now
    now=$(date +"%H:%M:%S")
    local health_age=$(($(date +%s) - HEALTH_CACHE_AGE))

    # Header
    printf "\033[1m"
    printf "  fleetmux Dashboard"
    printf "%*s" $((cols - 32)) "↻ ${now}"
    printf "\033[0m\n"
    printf "  %${cols}s\n" | tr ' ' '─'

    # ── Sessions table ──
    printf "  \033[1m%-3s %-13s %-8s %-18s %-9s %-14s %s\033[0m\n" \
        "#" "Name" "Type" "Target" "State" "Health" "Last Task / Output"
    printf "  %${cols}s\n" | tr ' ' '─'

    local i=1
    local running=0 idle=0 stopped=0
    while IFS= read -r name; do
        local type path host target state
        type=$(registry_get_field "$name" "type")
        path=$(registry_get_field "$name" "path")
        host=$(registry_get_field "$name" "host")
        target=$(get_display_target "$type" "$path" "$host")
        state=$(detect_session_state "$name")
        target=$(echo "$target" | head -c 18)

        # Health info for VPS, git info for local
        local health_str=""
        if [[ "$type" == "remote" ]]; then
            local health_data
            health_data=$(get_cached_health "$name")
            IFS='|' read -r disk mem pm2 <<< "$health_data"
            health_str="${disk} ${mem%%/*}M"
        elif [[ -d "${path}/.git" ]]; then
            local dirty
            dirty=$(git -C "$path" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
            if [[ "$dirty" -gt 0 ]]; then
                health_str="${dirty} dirty"
            else
                health_str="clean"
            fi
        fi

        # Last activity: task from history, or last output line if active
        local activity=""
        if [[ -f "$TASKS_FILE" ]]; then
            local task_info
            task_info=$(jq -r --arg s "$name" 'first(.[] | select(.session == $s)) | .task' "$TASKS_FILE" 2>/dev/null)
            if [[ -n "$task_info" && "$task_info" != "null" ]]; then
                activity="$task_info"
            fi
        fi
        if [[ "$state" != "stopped" && -z "$activity" ]]; then
            activity=$(get_last_line "$name" 30)
        fi
        # Truncate activity
        if [[ ${#activity} -gt 35 ]]; then
            activity="${activity:0:32}..."
        fi

        # Colors
        local state_color type_color
        case "$state" in
            running) state_color="\033[32m"; running=$((running + 1)) ;;
            idle)    state_color="\033[33m"; idle=$((idle + 1)) ;;
            stopped) state_color="\033[2m";  stopped=$((stopped + 1)) ;;
            *)       state_color="" ;;
        esac
        case "$type" in
            local)   type_color="\033[36m" ;;
            remote)  type_color="\033[35m" ;;
            utility) type_color="\033[34m" ;;
            *)       type_color="" ;;
        esac

        printf "  %-3s %-13s ${type_color}%-8s\033[0m %-18s ${state_color}%-9s\033[0m %-14s %s\n" \
            "$i" "$name" "$type" "$target" "$state" "$health_str" "$activity"

        i=$((i + 1))
    done < <(registry_list_names)

    # ── Footer ──
    printf "  %${cols}s\n" | tr ' ' '─'

    local total=$((running + idle + stopped))
    printf "  \033[1m%s\033[0m sessions: " "$total"
    printf "\033[32m%s running\033[0m, " "$running"
    printf "\033[33m%s idle\033[0m, " "$idle"
    printf "\033[2m%s stopped\033[0m" "$stopped"

    if tmux_session_exists; then
        local wcount
        wcount=$(tmux list-windows -t "$AIOS_TMUX_SESSION" 2>/dev/null | wc -l | tr -d ' ')
        printf "    │  tmux: %s windows" "$wcount"
    fi

    printf "    │  remote health: %ds ago" "$health_age"

    # ── Recent tasks ──
    if [[ -f "$TASKS_FILE" ]] && [[ "$(jq 'length' "$TASKS_FILE" 2>/dev/null)" != "0" ]]; then
        printf "\n\n  \033[1mRecent Tasks:\033[0m\n"
        jq -r '.[:5] | .[] | "  \(.dispatched_at[11:16])  \(.session)  \(.mode)  \(.status)  \(.task[:40])"' \
            "$TASKS_FILE" 2>/dev/null
    fi

    printf "\n\n  \033[2mCtrl-C to exit  │  remote health refreshes every %ds\033[0m\n" "$HEALTH_CACHE_INTERVAL"
}

# Main watch loop
run_watch() {
    local interval="${1:-3}"

    # Hide cursor
    tput civis 2>/dev/null

    # Restore cursor and cleanup on exit
    trap 'tput cnorm 2>/dev/null; [[ -n "$HEALTH_CACHE_DIR" ]] && rm -rf "$HEALTH_CACHE_DIR"; echo; exit 0' INT TERM

    while true; do
        # Refresh health cache if stale (non-blocking — launches background jobs)
        refresh_health_cache

        # Clear screen and move to top
        tput clear 2>/dev/null || printf "\033[2J\033[H"

        draw_dashboard

        sleep "$interval"
    done
}
