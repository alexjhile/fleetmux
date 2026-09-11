#!/usr/bin/env bash
# shellcheck disable=SC1091
# Account limits probe — fetches real-time Claude subscription usage
# (5-hour session + 7-day weekly + 7-day Opus) by making a minimal
# Haiku API call per account and parsing anthropic-ratelimit-unified-*
# response headers.
#
# Costs roughly $0.00005 per probe (9 tokens). Cached to limits-cache.json.
[[ -n "${_FLEETMUX_LIMITS_LOADED:-}" ]] && return 0; _FLEETMUX_LIMITS_LOADED=1

source "$(dirname "${BASH_SOURCE[0]}")/config.sh"
source "$(dirname "${BASH_SOURCE[0]}")/account.sh"
source "$(dirname "${BASH_SOURCE[0]}")/model-guard.sh"

LIMITS_CACHE_FILE="${FLEETMUX_DIR}/limits-cache.json"
LIMITS_PROBE_BIN="$(dirname "${BASH_SOURCE[0]}")/../bin/fleetmux-limits-probe"

# Probe one account. Returns JSON.
limits_probe_one() {
    local name="$1"
    [[ -x "$LIMITS_PROBE_BIN" ]] || { echo "{\"account\":\"$name\",\"error\":\"probe binary missing\"}"; return; }
    [[ -r "${ACCOUNTS_LOCAL_DIR}/${name}.token" ]] || { echo "{\"account\":\"$name\",\"error\":\"token missing locally\"}"; return; }
    "$LIMITS_PROBE_BIN" "$name" 2>/dev/null || echo "{\"account\":\"$name\",\"error\":\"probe failed\"}"
}

# Probe all known accounts in parallel, rebuild cache.
limits_refresh() {
    local accounts=()
    while IFS= read -r a; do
        [[ -n "$a" ]] && accounts+=("$a")
    done < <(account_list)

    if [[ ${#accounts[@]} -eq 0 ]]; then
        echo '{"refreshed_at":"'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'","accounts":[]}' > "$LIMITS_CACHE_FILE"
        echo "No accounts to probe."
        return
    fi

    local tmp_dir
    tmp_dir=$(mktemp -d)
    # Trap uses default expansion to stay safe under `set -u` at script exit.
    trap '[[ -n "${tmp_dir:-}" && -d "${tmp_dir:-}" ]] && rm -rf "$tmp_dir"' EXIT

    for a in "${accounts[@]}"; do
        (limits_probe_one "$a" > "${tmp_dir}/${a}.json") &
    done
    wait

    local out='[]'
    for a in "${accounts[@]}"; do
        local entry
        entry=$(cat "${tmp_dir}/${a}.json" 2>/dev/null)
        [[ -z "$entry" ]] && entry='{"account":"'"$a"'","error":"no output"}'
        out=$(jq --argjson e "$entry" '. + [$e]' <<<"$out")
    done

    local tmp="${LIMITS_CACHE_FILE}.tmp"
    jq -n --argjson accounts "$out" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{refreshed_at: $ts, accounts: $accounts}' > "$tmp" && mv "$tmp" "$LIMITS_CACHE_FILE"

    echo "Probed ${#accounts[@]} account(s) → $LIMITS_CACHE_FILE"

    # Auto-evaluate model guard after each probe
    model_guard_evaluate
}

# Read cached limits (refreshes if missing).
limits_read_cache() {
    [[ -f "$LIMITS_CACHE_FILE" ]] || limits_refresh >/dev/null
    cat "$LIMITS_CACHE_FILE" 2>/dev/null || echo '{"refreshed_at":null,"accounts":[]}'
}

# Pretty-print limits report.
limits_report() {
    local cache
    cache=$(limits_read_cache)
    local refreshed_at
    refreshed_at=$(jq -r '.refreshed_at // "never"' <<<"$cache")

    echo "Claude Subscription Limits (checked ${refreshed_at})"
    echo "──────────────────────────────────────────────────────────────"
    printf '%-12s %-6s %-8s %-8s %-12s %s\n' "ACCOUNT" "5H" "7D" "7D-OPUS" "LIMITING" "RESETS (5h)"
    jq -r '.accounts[] | [
        .account,
        ((.five_hour.used_percentage // null) | if . == null then "—" else ((. * 100) | floor | tostring + "%") end),
        ((.seven_day.used_percentage // null) | if . == null then "—" else ((. * 100) | floor | tostring + "%") end),
        ((.seven_day_opus.used_percentage // null) | if . == null then "—" else ((. * 100) | floor | tostring + "%") end),
        (.representative // "—"),
        ((.five_hour.resets_at // null) | if . == null then "—" else (. | todate) end),
        (.error // "")
    ] | @tsv' <<<"$cache" |
    while IFS=$'\t' read -r name five seven opus rep reset err; do
        if [[ -n "$err" && "$err" != "null" ]]; then
            printf '%-12s error: %s\n' "$name" "$err"
        else
            printf '%-12s %-6s %-8s %-8s %-12s %s\n' "$name" "$five" "$seven" "$opus" "$rep" "$reset"
        fi
    done
    echo "──────────────────────────────────────────────────────────────"
    echo "Probe cost: ~9 Haiku tokens per account per refresh (~\$0.00005 each)"
}
