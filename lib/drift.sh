#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2059
# Drift detection — compare local clones vs remote clones via origin
# Hub-and-spoke model: origin is the single source of truth.
# Local and Remote are spokes that should always match origin/main.
[[ -n "${_FLEETMUX_DRIFT_LOADED:-}" ]] && return 0; _FLEETMUX_DRIFT_LOADED=1

source "$(dirname "${BASH_SOURCE[0]}")/config.sh"
source "$(dirname "${BASH_SOURCE[0]}")/registry.sh"
source "$(dirname "${BASH_SOURCE[0]}")/display.sh"

# ─── Full drift report ───────────────────────────────────────────────────────
# Compares Local HEAD vs Remote HEAD vs origin HEAD for all dual-location sessions.
# With --fix: auto-pulls Local clones behind origin, pushes Remote if behind.

run_drift() {
    local fix_mode=false
    [[ "${1:-}" == "--fix" ]] && fix_mode=true

    local tmp_dir
    tmp_dir=$(mktemp -d)

    # Collect dual-location sessions (remote with local_path)
    local -a names=() local_paths=() hosts=() vps_paths=() pids=()

    while IFS= read -r name; do
        local type local_path host vps_path
        type=$(registry_get_field "$name" "type")
        [[ "$type" != "remote" ]] && continue

        local_path=$(registry_get_field "$name" "local_path")
        [[ -z "$local_path" || "$local_path" == "null" ]] && continue

        host=$(registry_get_field "$name" "host")
        vps_path=$(registry_get_field "$name" "path")

        names+=("$name")
        local_paths+=("$local_path")
        hosts+=("$host")
        vps_paths+=("$vps_path")
    done < <(registry_list_names)

    if [[ ${#names[@]} -eq 0 ]]; then
        printf "  ${C_DIM}No dual-location sessions to check${C_RESET}\n"
        rm -rf "$tmp_dir"
        return 0
    fi

    # Phase 1: Parallel — fetch origin on Local + get Remote HEAD via SSH
    for i in "${!names[@]}"; do
        (
            set +euo pipefail
            _name="${names[$i]}"
            _lp="${local_paths[$i]}"
            _h="${hosts[$i]}"
            _vp="${vps_paths[$i]}"

            # Fetch origin on Local
            if [[ -d "${_lp}/.git" ]]; then
                git -C "$_lp" fetch origin 2>/dev/null
            fi

            # Get all three HEADs
            _local_head=$(git -C "$_lp" rev-parse --short HEAD 2>/dev/null || echo "?")
            _origin_head=$(git -C "$_lp" rev-parse --short origin/main 2>/dev/null || \
                         git -C "$_lp" rev-parse --short origin/master 2>/dev/null || echo "?")
            _vps_head=$(ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no "$_h" \
                "cd '$_vp' && git rev-parse --short HEAD" 2>/dev/null || echo "?")

            _behind=$(git -C "$_lp" rev-list HEAD..origin/main 2>/dev/null | wc -l | tr -d ' ')
            _ahead=$(git -C "$_lp" rev-list origin/main..HEAD 2>/dev/null | wc -l | tr -d ' ')

            printf '%s|%s|%s|%s|%s\n' "$_local_head" "$_vps_head" "$_origin_head" "$_behind" "$_ahead" \
                > "${tmp_dir}/${_name}.result"
        ) &
        pids+=($!)
    done

    for pid in "${pids[@]}"; do
        wait "$pid" 2>/dev/null || true
    done

    # Phase 2: Display results + optional fix
    printf "\n  ${C_BOLD}%-15s %-10s %-10s %-10s %s${C_RESET}\n" \
        "Session" "Local" "Remote" "Origin" "Status"
    printf "  ─────────────── ────────── ────────── ────────── ──────────────────────────────\n"

    local drift_count=0
    for i in "${!names[@]}"; do
        local name="${names[$i]}"
        local result_file="${tmp_dir}/${name}.result"

        if [[ ! -f "$result_file" ]]; then
            printf "  %-15s %-10s %-10s %-10s ${C_RED}check failed${C_RESET}\n" "$name" "?" "?" "?"
            drift_count=$((drift_count + 1))
            continue
        fi

        IFS='|' read -r local_head vps_head origin_head behind ahead < "$result_file"

        local status_str status_color

        if [[ "$local_head" == "$vps_head" && "$vps_head" == "$origin_head" ]]; then
            # All three match — perfect sync
            status_str="✓ in sync"
            status_color="${C_GREEN}"

        elif [[ "$vps_head" == "?" ]]; then
            status_str="Remote unreachable"
            status_color="${C_RED}"
            drift_count=$((drift_count + 1))

        elif [[ "$local_head" == "?" ]]; then
            status_str="No local .git"
            status_color="${C_RED}"
            drift_count=$((drift_count + 1))

        elif [[ "$behind" -gt 0 && "$ahead" -eq 0 ]]; then
            # Local simply behind origin — safe to auto-pull
            status_str="Local ${behind} behind — needs pull"
            status_color="${C_YELLOW}"
            drift_count=$((drift_count + 1))

            if [[ "$fix_mode" == true ]]; then
                local dirty
                dirty=$(git -C "${local_paths[$i]}" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
                if [[ "$dirty" -eq 0 ]]; then
                    if git -C "${local_paths[$i]}" pull --ff-only origin main 2>/dev/null; then
                        status_str="✓ Local pulled (was ${behind} behind)"
                        status_color="${C_GREEN}"
                        drift_count=$((drift_count - 1))
                    fi
                else
                    status_str="Local ${behind} behind + ${dirty} dirty — can't auto-pull"
                    status_color="${C_RED}"
                fi
            fi

        elif [[ "$ahead" -gt 0 && "$behind" -eq 0 ]]; then
            status_str="Local ${ahead} ahead — needs push"
            status_color="${C_YELLOW}"
            drift_count=$((drift_count + 1))

        elif [[ "$ahead" -gt 0 && "$behind" -gt 0 ]]; then
            status_str="DIVERGED — ${ahead} ahead, ${behind} behind"
            status_color="${C_RED}"
            drift_count=$((drift_count + 1))

        elif [[ "$vps_head" != "$origin_head" && "$local_head" == "$origin_head" ]]; then
            # Remote has unpushed work
            status_str="Remote not on origin — unpushed work?"
            status_color="${C_YELLOW}"
            drift_count=$((drift_count + 1))

            if [[ "$fix_mode" == true ]]; then
                if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no "${hosts[$i]}" \
                    "cd '${vps_paths[$i]}' && git push origin main" 2>/dev/null; then
                    git -C "${local_paths[$i]}" pull --ff-only origin main 2>/dev/null || true
                    status_str="✓ Remote pushed + Local pulled"
                    status_color="${C_GREEN}"
                    drift_count=$((drift_count - 1))
                fi
            fi

        else
            status_str="drifted (all three differ)"
            status_color="${C_YELLOW}"
            drift_count=$((drift_count + 1))
        fi

        printf "  %-15s %-10s %-10s %-10s %b%s${C_RESET}\n" \
            "$name" "$local_head" "$vps_head" "$origin_head" "$status_color" "$status_str"
    done

    echo ""
    if [[ $drift_count -gt 0 ]]; then
        if [[ "$fix_mode" == false ]]; then
            printf "  ${C_YELLOW}%d session(s) drifted.${C_RESET} Run ${C_BOLD}fleetmux drift --fix${C_RESET} to auto-resolve.\n\n" "$drift_count"
        else
            printf "  ${C_YELLOW}%d session(s) still need manual attention.${C_RESET}\n\n" "$drift_count"
        fi
        rm -rf "$tmp_dir"
        return 1
    else
        printf "  ${C_GREEN}All %d dual-location sessions in sync.${C_RESET}\n\n" "${#names[@]}"
        rm -rf "$tmp_dir"
        return 0
    fi
}

# ─── Lightweight drift check for fleetmux sync ────────────────────────────────────
# Auto-pulls Local clones that are behind origin (non-destructive, ff-only).
# Warns about unpushed/diverged state but doesn't auto-push.
# Runs git fetch in parallel, then checks sequentially.

sync_drift_check() {
    local -a names=() local_paths=() pids=()

    # Collect and fetch in parallel
    while IFS= read -r name; do
        local type local_path
        type=$(registry_get_field "$name" "type")
        [[ "$type" != "remote" ]] && continue

        local_path=$(registry_get_field "$name" "local_path")
        [[ -z "$local_path" || "$local_path" == "null" ]] && continue
        [[ ! -d "${local_path}/.git" ]] && continue

        names+=("$name")
        local_paths+=("$local_path")

        git -C "$local_path" fetch origin 2>/dev/null &
        pids+=($!)
    done < <(registry_list_names)

    # Wait for fetches
    for pid in "${pids[@]}"; do
        wait "$pid" 2>/dev/null || true
    done

    # Check each and auto-pull if safe
    local had_issues=false
    local had_output=false

    for i in "${!names[@]}"; do
        local name="${names[$i]}"
        local local_path="${local_paths[$i]}"

        local local_head origin_head
        local_head=$(git -C "$local_path" rev-parse HEAD 2>/dev/null || echo "")
        origin_head=$(git -C "$local_path" rev-parse origin/main 2>/dev/null || \
                     git -C "$local_path" rev-parse origin/master 2>/dev/null || echo "")

        [[ -z "$origin_head" ]] && continue
        [[ "$local_head" == "$origin_head" ]] && continue

        local behind ahead
        behind=$(git -C "$local_path" rev-list HEAD..origin/main 2>/dev/null | wc -l | tr -d ' ')
        ahead=$(git -C "$local_path" rev-list origin/main..HEAD 2>/dev/null | wc -l | tr -d ' ')

        if [[ "$behind" -gt 0 && "$ahead" -eq 0 ]]; then
            # Simply behind — auto-pull if clean
            local dirty
            dirty=$(git -C "$local_path" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
            if [[ "$dirty" -eq 0 ]]; then
                if git -C "$local_path" pull --ff-only origin main 2>/dev/null; then
                    printf "  ${C_GREEN}↓${C_RESET} %-14s Local auto-pulled %s commit(s)\n" "$name" "$behind"
                    had_output=true
                else
                    printf "  ${C_YELLOW}!${C_RESET} %-14s Local %s behind — ff-only pull failed\n" "$name" "$behind"
                    had_issues=true
                    had_output=true
                fi
            else
                printf "  ${C_YELLOW}!${C_RESET} %-14s Local %s behind + %s dirty — manual pull needed\n" "$name" "$behind" "$dirty"
                had_issues=true
                had_output=true
            fi
        elif [[ "$ahead" -gt 0 && "$behind" -eq 0 ]]; then
            printf "  ${C_YELLOW}↑${C_RESET} %-14s Local has %s unpushed commit(s)\n" "$name" "$ahead"
            had_issues=true
            had_output=true
        elif [[ "$ahead" -gt 0 && "$behind" -gt 0 ]]; then
            printf "  ${C_RED}✗${C_RESET} %-14s DIVERGED — %s ahead, %s behind\n" "$name" "$ahead" "$behind"
            had_issues=true
            had_output=true
        fi
    done

    if [[ "$had_output" == false ]]; then
        printf "  ${C_GREEN}✓${C_RESET} All Local clones in sync with origin\n"
    elif [[ "$had_issues" == true ]]; then
        printf "  ${C_DIM}Run 'fleetmux drift' for full report or 'fleetmux drift --fix' to resolve${C_RESET}\n"
    fi

    return 0
}
