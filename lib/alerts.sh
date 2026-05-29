#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2059
# Alerts — smart monitoring across the fleet
# Checks VPS health, stuck tasks, and idle sessions
[[ -n "${_AIOS_ALERTS_LOADED:-}" ]] && return 0; _AIOS_ALERTS_LOADED=1

source "$(dirname "${BASH_SOURCE[0]}")/config.sh"
source "$(dirname "${BASH_SOURCE[0]}")/registry.sh"
source "$(dirname "${BASH_SOURCE[0]}")/display.sh"

ALERTS_FILE="${AIOS_DIR}/alerts.json"

# Check VPS reachability and resource usage
# Usage: check_vps_alerts <name> <host> <out_file>
check_vps_alerts() {
    local name="$1"
    local host="$2"
    local out_file="$3"
    local alerts=""

    local result
    result=$(ssh -n -o ConnectTimeout=10 -o StrictHostKeyChecking=no "$host" \
        'echo "DISK:$(df -h / | tail -1 | awk "{print \$5}" | tr -d "%")"; echo "MEM:$(free -m 2>/dev/null | grep Mem | awk "{printf \"%d %d\", \$3, \$2}")"; echo "UP:yes"' 2>/dev/null)

    if [[ -z "$result" ]]; then
        echo "${name}|unreachable|remote host ${host} is unreachable" > "$out_file"
        return
    fi

    local disk_pct="" mem_used="" mem_total=""

    while IFS= read -r line; do
        case "$line" in
            DISK:*) disk_pct="${line#DISK:}" ;;
            MEM:*)
                mem_used="${line#MEM:}"
                mem_total="${mem_used#* }"
                mem_used="${mem_used%% *}"
                ;;
            UP:*) ;; # parsed but not needed for alerts
        esac
    done <<< "$result"

    if [[ -n "$disk_pct" && "$disk_pct" -ge 80 ]]; then
        alerts="${alerts}${name}|disk|Disk usage at ${disk_pct}% (threshold: 80%)\n"
    fi

    if [[ -n "$mem_used" && -n "$mem_total" && "$mem_total" -gt 0 ]]; then
        local mem_pct=$(( (mem_used * 100) / mem_total ))
        if [[ "$mem_pct" -ge 90 ]]; then
            alerts="${alerts}${name}|memory|Memory usage at ${mem_pct}% (${mem_used}/${mem_total}MB)\n"
        fi
    fi

    if [[ -n "$alerts" ]]; then
        printf '%b' "$alerts" > "$out_file"
    else
        : > "$out_file"
    fi
}

# Check for tasks stuck in "dispatched" state for too long
check_stuck_tasks() {
    local threshold_minutes="${1:-60}"
    local now
    now=$(date +%s)
    local threshold_seconds=$((threshold_minutes * 60))
    local stuck_alerts=""

    if [[ ! -f "$TASKS_FILE" ]]; then
        return
    fi

    while IFS=$'\t' read -r session dispatched_at task; do
        [[ -z "$session" ]] && continue
        local task_ts
        task_ts=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$dispatched_at" "+%s" 2>/dev/null || echo "0")
        local age=$((now - task_ts))

        if [[ "$age" -ge "$threshold_seconds" ]]; then
            local age_min=$((age / 60))
            stuck_alerts="${stuck_alerts}${session}|stuck_task|Task stuck in dispatched for ${age_min}m: ${task}\n"
        fi
    done < <(jq -r '.[] | select(.status == "dispatched") | [.session, .dispatched_at, .task] | @tsv' "$TASKS_FILE" 2>/dev/null)

    if [[ -n "$stuck_alerts" ]]; then
        printf '%b' "$stuck_alerts"
    fi
}

# Run all alert checks
run_alerts() {
    echo ""
    print_info "fleetmux Alerts"
    echo ""

    local all_alerts=""
    local tmp_dir
    tmp_dir=$(mktemp -d)
    local vps_pids=()
    local vps_names=()

    # Check VPS health (parallel)
    while IFS= read -r name; do
        local type host
        type=$(registry_get_field "$name" "type")
        [[ "$type" != "remote" ]] && continue
        host=$(registry_get_field "$name" "host")

        check_vps_alerts "$name" "$host" "${tmp_dir}/${name}.alerts" &
        vps_pids+=($!)
        vps_names+=("$name")
    done < <(registry_list_names)

    # Wait for VPS checks
    for pid in "${vps_pids[@]}"; do
        wait "$pid" 2>/dev/null
    done

    # Collect VPS alerts
    for name in "${vps_names[@]}"; do
        local alert_file="${tmp_dir}/${name}.alerts"
        if [[ -f "$alert_file" && -s "$alert_file" ]]; then
            all_alerts="${all_alerts}$(cat "$alert_file")\n"
        fi
    done

    # Check stuck tasks
    local stuck
    stuck=$(check_stuck_tasks 60)
    if [[ -n "$stuck" ]]; then
        all_alerts="${all_alerts}${stuck}\n"
    fi

    # Display alerts
    if [[ -z "$all_alerts" || "$all_alerts" == "\n" ]]; then
        printf "  ${C_GREEN}✓${C_RESET} No alerts — all systems healthy\n"
    else
        local alert_count=0
        while IFS='|' read -r session alert_type message; do
            [[ -z "$session" ]] && continue
            ((alert_count++))
            local icon
            case "$alert_type" in
                unreachable) icon="${C_RED}✗" ;;
                disk|memory)  icon="${C_YELLOW}⚠" ;;
                stuck_task)   icon="${C_YELLOW}⏳" ;;
                *)            icon="${C_YELLOW}!" ;;
            esac
            printf "  %b${C_RESET} %-14s %s\n" "$icon" "$session" "$message"
        done < <(printf '%b' "$all_alerts" | grep -v '^$')

        printf "\n  ${C_BOLD}%d alert(s)${C_RESET}\n" "$alert_count"

        # Save to alerts.json (transient, not git-tracked)
        printf '%b' "$all_alerts" | grep -v '^$' | while IFS='|' read -r session alert_type message; do
            [[ -z "$session" ]] && continue
            jq -n --arg s "$session" --arg t "$alert_type" --arg m "$message" --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
                '{session: $s, type: $t, message: $m, timestamp: $ts}'
        done | jq -s '.' > "$ALERTS_FILE" 2>/dev/null
    fi

    echo ""
    rm -rf "$tmp_dir"
}
