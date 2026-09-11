#!/usr/bin/env bash
# shellcheck disable=SC1091
# Usage — per-session token consumption aggregated from Claude Code JSONL files.
#
# Parses $HOME/.claude/projects/<slug>/*.jsonl (local) or the equivalent on a
# VPS via SSH. Each assistant message has a usage block with input_tokens,
# cache_creation_input_tokens, cache_read_input_tokens, output_tokens. We sum
# those across every conversation file to produce a per-session total.
#
# Results are cached in AIOS/usage-cache.json so the dashboard can read
# instantly. Refreshed by `fleetmux usage refresh` or on `fleetmux sync`.
[[ -n "${_AIOS_USAGE_LOADED:-}" ]] && return 0; _AIOS_USAGE_LOADED=1

source "$(dirname "${BASH_SOURCE[0]}")/config.sh"
source "$(dirname "${BASH_SOURCE[0]}")/registry.sh"

USAGE_CACHE_FILE="${AIOS_DIR}/usage-cache.json"
USAGE_PARSER_LOCAL="${HOME}/.aios-usage-parser"
USAGE_ZERO='{"turns":0,"input_tokens":0,"cache_creation_tokens":0,"cache_read_tokens":0,"output_tokens":0,"total_tokens":0,"tokens_5m":0,"tokens_15m":0,"tokens_24h":0,"tokens_48h":0,"tokens_7d":0,"turns_5m":0,"turns_15m":0,"turns_24h":0,"turns_48h":0,"turns_7d":0,"conversations":0,"last_activity":null}'

_usage_jq_agg='[.[] | select(.type == "assistant" and .message.usage) | .message.usage] | {output_tokens: (map(.output_tokens // 0) | add // 0), input_tokens: (map(.input_tokens // 0) | add // 0), total_tokens: (map((.input_tokens // 0) + (.output_tokens // 0)) | add // 0)}'

# Slugify a Claude Code project path into the dir name under ~/.claude/projects.
# Claude Code replaces '/', '_', '.' with '-'.
usage_slug() {
    local path="$1"
    printf '%s' "$path" | tr '/_.' '---'
}

# Parse a local AIOS session by shelling out to the deployed parser script.
usage_for_local_session() {
    local session="$1"
    local path slug
    path=$(registry_get_field "$session" "path")
    [[ -z "$path" ]] && { echo "$USAGE_ZERO"; return; }
    slug=$(usage_slug "$path")
    if [[ ! -x "$USAGE_PARSER_LOCAL" ]]; then
        echo "$USAGE_ZERO"
        return
    fi
    "$USAGE_PARSER_LOCAL" "$slug" 2>/dev/null || echo "$USAGE_ZERO"
}

# Parse a remote session via SSH (runs parser script on the VPS).
usage_for_remote_session() {
    local session="$1"
    local host path slug
    host=$(registry_get_field "$session" "host")
    path=$(registry_get_field "$session" "path")
    [[ -z "$host" || -z "$path" ]] && { echo "$USAGE_ZERO"; return; }
    slug=$(usage_slug "$path")
    # -n prevents ssh from consuming our stdin (which is the while-loop's
    # registry_list_names feed). Without -n it silently eats unread input.
    # shellcheck disable=SC2088
    ssh -n -o ConnectTimeout=5 -o BatchMode=yes "$host" \
        "~/.aios-usage-parser $(printf '%q' "$slug")" 2>/dev/null || echo "$USAGE_ZERO"
}

# Refresh the usage cache for every session.
# Remote sessions are probed in parallel via background SSH.
usage_refresh() {
    local tmp_dir
    tmp_dir=$(mktemp -d)

    # Phase 1: kick off all remote probes in parallel
    while IFS= read -r session; do
        local type
        type=$(registry_get_field "$session" "type")
        if [[ "$type" == "remote" ]]; then
            (usage_for_remote_session "$session" > "${tmp_dir}/${session}.json" 2>/dev/null) &
        fi
    done < <(registry_list_names)

    # Phase 2: run local sessions sequentially (fast, no network)
    local out='[]'
    while IFS= read -r session; do
        local type data account
        type=$(registry_get_field "$session" "type")
        case "$type" in
            local|utility)
                data=$(usage_for_local_session "$session")
                ;;
            remote)
                # Will be collected below after wait
                continue
                ;;
            *)
                data='null'
                ;;
        esac
        [[ -z "$data" || "$data" == "null" ]] && data="$USAGE_ZERO"
        account=$(registry_get_field "$session" "account")
        local row
        row=$(jq -n --arg name "$session" --arg type "$type" --arg account "$account" --argjson usage "$data" \
            '{name: $name, type: $type, account: $account, usage: $usage}')
        out=$(jq --argjson r "$row" '. + [$r]' <<<"$out")
    done < <(registry_list_names)

    # Phase 3: wait for all remote probes, collect results
    wait
    while IFS= read -r session; do
        local type
        type=$(registry_get_field "$session" "type")
        [[ "$type" != "remote" ]] && continue
        local data account row
        data=$(cat "${tmp_dir}/${session}.json" 2>/dev/null)
        [[ -z "$data" || "$data" == "null" ]] && data="$USAGE_ZERO"
        account=$(registry_get_field "$session" "account")
        row=$(jq -n --arg name "$session" --arg type "$type" --arg account "$account" --argjson usage "$data" \
            '{name: $name, type: $type, account: $account, usage: $usage}')
        out=$(jq --argjson r "$row" '. + [$r]' <<<"$out")
    done < <(registry_list_names)

    rm -rf "$tmp_dir"

    local tmp="${USAGE_CACHE_FILE}.tmp"
    jq -n --argjson sessions "$out" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{refreshed_at: $ts, sessions: $sessions}' > "$tmp" && mv "$tmp" "$USAGE_CACHE_FILE"

    echo "Refreshed usage cache → $USAGE_CACHE_FILE"
}

# Read cached usage data (refreshes if missing).
usage_read_cache() {
    [[ ! -f "$USAGE_CACHE_FILE" ]] && usage_refresh >/dev/null
    cat "$USAGE_CACHE_FILE"
}

# Format a token count for human display (k/M). Coerces null/empty to 0.
_fmt_tok() {
    local n="${1:-0}"
    [[ "$n" == "null" || -z "$n" || ! "$n" =~ ^[0-9]+$ ]] && n=0
    if (( n >= 1000000 )); then
        awk -v n="$n" 'BEGIN{printf "%.1fM", n/1000000}'
    elif (( n >= 1000 )); then
        awk -v n="$n" 'BEGIN{printf "%.1fk", n/1000}'
    else
        echo "$n"
    fi
}

# CLI: fleetmux usage [--refresh]
usage_report() {
    local refresh=false
    while [[ "${1:-}" == --* ]]; do
        case "$1" in
            --refresh) refresh=true; shift ;;
            *) break ;;
        esac
    done
    $refresh && usage_refresh >/dev/null

    local cache
    cache=$(usage_read_cache)
    local refreshed_at
    refreshed_at=$(jq -r '.refreshed_at' <<<"$cache")

    echo "Token Usage (cached ${refreshed_at})"
    echo "──────────────────────────────────────────────────────────────────────────────────────────────────"
    printf '%-28s %-7s %-7s %7s %7s %7s %8s %8s %8s %8s\n' "SESSION" "TYPE" "ACCOUNT" "CONVS" "5M" "15M" "24H" "7D" "TOTAL" "LAST"
    jq -r '.sessions[] | [
        .name,
        .type,
        (if ((.account // "") == "") then "-" else .account end),
        ((.usage.conversations // 0)|tostring),
        ((.usage.tokens_5m // 0)|tostring),
        ((.usage.tokens_15m // 0)|tostring),
        ((.usage.tokens_24h // 0)|tostring),
        ((.usage.tokens_7d // 0)|tostring),
        ((.usage.total_tokens // 0)|tostring),
        (.usage.last_activity // "-")
    ] | @tsv' <<<"$cache" |
    sort -t$'\t' -k5 -rn |
    while IFS=$'\t' read -r name type account convs t5m t15m t24 t7 total last; do
        local last_short="-"
        if [[ "$last" != "-" && "$last" != "null" ]]; then
            last_short="${last:5:11}"
        fi
        printf '%-28s %-7s %-7s %7s %7s %7s %8s %8s %8s %8s\n' \
            "$name" "$type" "$account" "$convs" \
            "$(_fmt_tok "${t5m:-0}")" \
            "$(_fmt_tok "${t15m:-0}")" \
            "$(_fmt_tok "${t24:-0}")" \
            "$(_fmt_tok "${t7:-0}")" \
            "$(_fmt_tok "${total:-0}")" \
            "$last_short"
    done
    echo "──────────────────────────────────────────────────────────────────────────────────────────────────"
    local grand_5m grand_15m grand_24h grand_7d grand_total
    grand_5m=$(jq '[.sessions[].usage.tokens_5m // 0] | add // 0' <<<"$cache")
    grand_15m=$(jq '[.sessions[].usage.tokens_15m // 0] | add // 0' <<<"$cache")
    grand_24h=$(jq '[.sessions[].usage.tokens_24h] | add // 0' <<<"$cache")
    grand_7d=$(jq '[.sessions[].usage.tokens_7d] | add // 0' <<<"$cache")
    grand_total=$(jq '[.sessions[].usage.total_tokens] | add // 0' <<<"$cache")
    printf '%-28s %-7s %-7s %7s %7s %7s %8s %8s %8s\n' "TOTAL" "" "" "" \
        "$(_fmt_tok "$grand_5m")" "$(_fmt_tok "$grand_15m")" \
        "$(_fmt_tok "$grand_24h")" "$(_fmt_tok "$grand_7d")" "$(_fmt_tok "$grand_total")"
    echo
    echo "Refresh: fleetmux usage --refresh    Top conversations: fleetmux usage top [N]"
}

# CLI: fleetmux usage top [--session NAME] [N]
# Shows the N highest-burn conversations.
usage_top() {
    local session=""
    local n=10
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --session) session="$2"; shift 2 ;;
            *) n="$1"; shift ;;
        esac
    done

    local base_dir
    if [[ -n "$session" ]]; then
        local type
        type=$(registry_get_field "$session" "type")
        if [[ "$type" == "remote" ]]; then
            echo "Remote top-conversation view not yet implemented (only local sessions)." >&2
            return 1
        fi
        local path slug
        path=$(registry_get_field "$session" "path")
        slug=$(usage_slug "$path")
        base_dir="${HOME}/.claude/projects/${slug}"
    else
        base_dir="${HOME}/.claude/projects"
    fi

    [[ ! -d "$base_dir" ]] && { echo "No conversations at $base_dir"; return 0; }

    echo "Top $n conversations by output tokens:"
    printf '%-10s %-40s %s\n' "OUTPUT" "CONVERSATION" "FIRST PROMPT"
    find "$base_dir" -name '*.jsonl' -type f -not -path '*subagents*' 2>/dev/null |
    while read -r file; do
        local stats first out
        stats=$(jq -s "${_usage_jq_agg}" "$file" 2>/dev/null)
        out=$(jq -r '.output_tokens' <<<"$stats")
        [[ -z "$out" || "$out" == "0" ]] && continue
        first=$(jq -r 'select(.type=="user") | (.message.content // "") | if type=="array" then (.[0].text // "") else . end' "$file" 2>/dev/null | head -1 | tr '\n' ' ' | cut -c1-60)
        local conv_id
        conv_id=$(basename "$file" .jsonl | cut -c1-8)
        printf '%s\t%s\t%s\n' "$out" "$conv_id" "$first"
    done | sort -rn | head -"$n" |
    while IFS=$'\t' read -r out conv first; do
        printf '%-10s %-40s %s\n' "$(_fmt_tok "$out")" "$conv" "$first"
    done
}
