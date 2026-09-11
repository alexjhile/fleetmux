#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2059
# Health — VPS health checks (parallel SSH) + local session health
[[ -n "${_AIOS_HEALTH_LOADED:-}" ]] && return 0; _AIOS_HEALTH_LOADED=1

source "$(dirname "${BASH_SOURCE[0]}")/config.sh"
source "$(dirname "${BASH_SOURCE[0]}")/registry.sh"
source "$(dirname "${BASH_SOURCE[0]}")/status.sh"
source "$(dirname "${BASH_SOURCE[0]}")/display.sh"

HEALTH_TIMEOUT=10
HEALTH_TMP_DIR=""

health_check_vps() {
    local name="$1"
    local host="$2"
    local out_file="$3"

    local ip
    ip="${host##*@}"

    # Single SSH call to gather all metrics
    local result
    result=$(ssh -o ConnectTimeout="$HEALTH_TIMEOUT" -o StrictHostKeyChecking=no "$host" \
        'echo "UPTIME:$(uptime -s 2>/dev/null || uptime | sed "s/.*up //" | sed "s/,.*//")"; echo "DISK:$(df -h / | tail -1 | awk "{print \$5, \$3\"/\"\$2}")"; echo "MEM:$(free -m 2>/dev/null | grep Mem | awk "{printf \"%d/%dMB\", \$3, \$2}")"; echo "PM2:$(pm2 jlist 2>/dev/null | jq "length" 2>/dev/null || echo "n/a")"' 2>/dev/null)

    if [[ -z "$result" ]]; then
        echo "${name}|${ip}|unreachable|-|-|-" > "$out_file"
        return
    fi

    local uptime_val disk_val mem_val pm2_val
    uptime_val=$(echo "$result" | grep "^UPTIME:" | sed 's/^UPTIME://')
    disk_val=$(echo "$result" | grep "^DISK:" | sed 's/^DISK://')
    mem_val=$(echo "$result" | grep "^MEM:" | sed 's/^MEM://')
    pm2_val=$(echo "$result" | grep "^PM2:" | sed 's/^PM2://')

    # Calculate uptime duration if we got a date
    if echo "$uptime_val" | grep -qE '^[0-9]{4}-'; then
        local boot_ts now_ts diff_s days hours
        boot_ts=$(local_datetime_to_epoch "$uptime_val")
        now_ts=$(date +%s)
        if [[ "$boot_ts" -gt 0 ]]; then
            diff_s=$((now_ts - boot_ts))
            days=$((diff_s / 86400))
            hours=$(( (diff_s % 86400) / 3600))
            uptime_val="${days}d ${hours}h"
        fi
    fi

    echo "${name}|${ip}|ok|${uptime_val:-?}|${disk_val:-?}|${mem_val:-?}|${pm2_val:-?}" > "$out_file"
}

health_check_local() {
    local name="$1"
    local path="$2"
    local out_file="$3"

    local branch="" dirty="0" status="ok"

    if [[ ! -d "$path" ]]; then
        echo "${name}|${path}|-|-|missing" > "$out_file"
        return
    fi

    # Shorten path for display
    local short_path
    if [[ "$path" == "$CLAUDE_CODE_ROOT" ]]; then
        short_path="(home)"
    else
        short_path="${path#"${CLAUDE_CODE_ROOT}/"}"
    fi

    if [[ -d "${path}/.git" ]]; then
        branch=$(git -C "$path" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "-")
        dirty=$(git -C "$path" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
    else
        branch="-"
    fi

    echo "${name}|${short_path}|${branch}|${dirty}|${status}" > "$out_file"
}

run_health_check() {
    HEALTH_TMP_DIR=$(mktemp -d)
    local pids=()

    echo ""
    print_info "fleetmux Health Check"
    echo ""

    # ── VPS Sessions (parallel) ──
    local has_remote=false
    while IFS= read -r name; do
        local type host
        type=$(registry_get_field "$name" "type")
        [[ "$type" != "remote" ]] && continue
        has_remote=true
        host=$(registry_get_field "$name" "host")
        health_check_vps "$name" "$host" "${HEALTH_TMP_DIR}/${name}.vps" &
        pids+=($!)
    done < <(registry_list_names)

    # Wait for all VPS checks
    for pid in "${pids[@]}"; do
        wait "$pid" 2>/dev/null
    done

    if [[ "$has_remote" == true ]]; then
        printf "  ${C_BOLD}Remote Sessions:${C_RESET}\n"
        printf "  ${C_BOLD}%-14s %-18s %-12s %-9s %-14s %-4s${C_RESET}\n" "Name" "IP" "Uptime" "Disk" "Memory" "PM2"
        echo "  ────────────── ────────────────── ──────────── ───────── ────────────── ────"

        while IFS= read -r name; do
            local type
            type=$(registry_get_field "$name" "type")
            [[ "$type" != "remote" ]] && continue

            local vps_file="${HEALTH_TMP_DIR}/${name}.vps"
            if [[ -f "$vps_file" ]]; then
                local line
                line=$(cat "$vps_file")
                IFS='|' read -r _name ip status uptime_val disk_val mem_val pm2_val <<< "$line"

                if [[ "$status" == "unreachable" ]]; then
                    printf "  %-14s %-18s ${C_RED}%-12s${C_RESET} %-9s %-14s %-4s\n" "$_name" "$ip" "unreachable" "-" "-" "-"
                else
                    printf "  %-14s %-18s %-12s %-9s %-14s %-4s\n" "$_name" "$ip" "$uptime_val" "$disk_val" "$mem_val" "$pm2_val"
                fi
            fi
        done < <(registry_list_names)
        echo ""
    fi

    # ── Local Sessions ──
    local has_local=false
    while IFS= read -r name; do
        local type path
        type=$(registry_get_field "$name" "type")
        [[ "$type" == "remote" ]] && continue
        has_local=true
        path=$(registry_get_field "$name" "path")
        health_check_local "$name" "$path" "${HEALTH_TMP_DIR}/${name}.local"
    done < <(registry_list_names)

    if [[ "$has_local" == true ]]; then
        printf "  ${C_BOLD}Local Sessions:${C_RESET}\n"
        printf "  ${C_BOLD}%-14s %-24s %-10s %-7s %-8s${C_RESET}\n" "Name" "Path" "Branch" "Dirty" "Status"
        echo "  ────────────── ──────────────────────── ────────── ─────── ────────"

        while IFS= read -r name; do
            local type
            type=$(registry_get_field "$name" "type")
            [[ "$type" == "remote" ]] && continue

            local local_file="${HEALTH_TMP_DIR}/${name}.local"
            if [[ -f "$local_file" ]]; then
                local line
                line=$(cat "$local_file")
                IFS='|' read -r _name short_path branch dirty status <<< "$line"

                local status_colored dirty_colored
                if [[ "$status" == "missing" ]]; then
                    status_colored=$(printf "${C_RED}%-8s${C_RESET}" "$status")
                else
                    status_colored=$(printf "${C_GREEN}%-8s${C_RESET}" "$status")
                fi

                if [[ "$dirty" -gt 0 ]]; then
                    dirty_colored=$(printf "${C_YELLOW}%-7s${C_RESET}" "$dirty")
                else
                    dirty_colored=$(printf "${C_DIM}%-7s${C_RESET}" "$dirty")
                fi

                printf "  %-14s %-24s %-10s %b %b\n" "$_name" "$short_path" "$branch" "$dirty_colored" "$status_colored"
            fi
        done < <(registry_list_names)
        echo ""
    fi

    # Cleanup
    rm -rf "$HEALTH_TMP_DIR"
}
