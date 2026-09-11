#!/usr/bin/env bash
# shellcheck disable=SC1091
# Model guard — graduated auto-downgrade Opus → Sonnet based on 5-hour
# session pressure. Re-evaluates every cycle — if the curve no longer
# triggers, automatically restores to Opus. No separate restore threshold.
#
# Curve: downgrade when usage >= 50% AND hours_left >= CURVE × (1 - usage%)
#
#   60% + 3.0h left → sonnet     80% + 1.5h left → sonnet
#   70% + 2.2h left → sonnet     90% + 0.8h left → sonnet
#   60% + 1.0h left → safe       80% + 0.5h left → safe (auto-restore)
#   95%+ any time   → sonnet     80% + 20min left → safe (auto-restore)
#
# "safe" means: the curve doesn't trigger, so if we previously
# downgraded, we restore to Opus. This handles the "high usage but
# reset is imminent" case automatically.
#
# Never uses Haiku. Sonnet only.
[[ -n "${_FLEETMUX_MODEL_GUARD_LOADED:-}" ]] && return 0; _FLEETMUX_MODEL_GUARD_LOADED=1

source "$(dirname "${BASH_SOURCE[0]}")/config.sh"
source "$(dirname "${BASH_SOURCE[0]}")/registry.sh"
source "$(dirname "${BASH_SOURCE[0]}")/status.sh"

MODEL_GUARD_STATE="${FLEETMUX_DIR}/model-guard-state.json"
MODEL_GUARD_CONFIG="${FLEETMUX_DIR}/model-guard-config.json"

_mg_enabled=true
_mg_curve=7.5              # hours = CURVE × (1 - usage). Bigger = more conservative.
_mg_min_usage=0.50         # Don't touch below 50%
_mg_emergency_usage=0.95   # Above this → sonnet regardless of time

_mg_load_config() {
    if [[ -f "$MODEL_GUARD_CONFIG" ]]; then
        _mg_enabled=$(jq -r '.enabled // true' "$MODEL_GUARD_CONFIG")
        _mg_curve=$(jq -r '.curve // 7.5' "$MODEL_GUARD_CONFIG")
        _mg_min_usage=$(jq -r '.min_usage // 0.50' "$MODEL_GUARD_CONFIG")
        _mg_emergency_usage=$(jq -r '.emergency_usage // 0.95' "$MODEL_GUARD_CONFIG")
    fi
}

_mg_load_state() {
    [[ -f "$MODEL_GUARD_STATE" ]] && cat "$MODEL_GUARD_STATE" || echo '{}'
}

_mg_save_state() {
    echo "$1" > "$MODEL_GUARD_STATE"
}

# Should we downgrade at this (usage, hours_left) point?
# Returns "sonnet" if yes, "" if no (safe).
_mg_should_downgrade() {
    local pct="$1" hours="$2"

    # Emergency: always sonnet
    if (( $(echo "$pct >= $_mg_emergency_usage" | bc -l) )); then
        echo "sonnet"
        return
    fi

    # Below minimum: safe
    if (( $(echo "$pct < $_mg_min_usage" | bc -l) )); then
        echo ""
        return
    fi

    # Graduated curve
    local threshold_hours
    threshold_hours=$(echo "$_mg_curve * (1.0 - $pct)" | bc -l)
    if (( $(echo "$hours >= $threshold_hours" | bc -l) )); then
        echo "sonnet"
    else
        echo ""
    fi
}

_mg_send_model() {
    local session="$1" model="$2"
    if tmux_window_exists "$session"; then
        $TMUX_CMD send-keys -t "${FLEETMUX_TMUX_SESSION}:${session}" "/model ${model}" Enter
        echo "  [model-guard] ${session} → /model ${model}"
    fi
}

# Main evaluation loop — runs after each limits probe.
model_guard_evaluate() {
    _mg_load_config
    [[ "$_mg_enabled" != "true" ]] && return 0

    local limits_file="${FLEETMUX_DIR}/limits-cache.json"
    [[ ! -f "$limits_file" ]] && return 0

    local state
    state=$(_mg_load_state)
    local changed=false

    while IFS=$'\t' read -r account pct reset_epoch; do
        [[ -z "$account" || "$pct" == "null" ]] && continue

        local now_epoch hours_remaining
        now_epoch=$(date +%s)
        hours_remaining=$(echo "($reset_epoch - $now_epoch) / 3600" | bc -l)
        (( $(echo "$hours_remaining < 0" | bc -l) )) && hours_remaining=0

        local action
        action=$(_mg_should_downgrade "$pct" "$hours_remaining")

        while IFS= read -r session; do
            local sess_account
            sess_account=$(registry_get_field "$session" "account")
            [[ "$sess_account" != "$account" ]] && continue
            ! tmux_window_exists "$session" && continue

            local current_override original_model
            current_override=$(echo "$state" | jq -r --arg s "$session" '.[$s].current_override // ""')
            original_model=$(echo "$state" | jq -r --arg s "$session" '.[$s].original_model // ""')

            if [[ -n "$action" ]]; then
                # Curve says downgrade
                if [[ "$current_override" != "$action" ]]; then
                    [[ -z "$original_model" ]] && original_model="opus"
                    _mg_send_model "$session" "$action"
                    state=$(echo "$state" | jq --arg s "$session" --arg orig "$original_model" --arg over "$action" \
                        --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
                        --arg reason "5h: $(echo "$pct * 100" | bc -l | cut -d. -f1)%, $(printf '%.1f' "$hours_remaining")h left" \
                        '.[$s] = {original_model: $orig, current_override: $over, overridden_at: $ts, reason: $reason}')
                    changed=true
                fi
            else
                # Curve says safe — restore if we previously overrode
                if [[ -n "$current_override" ]]; then
                    local restore_to="${original_model:-opus}"
                    _mg_send_model "$session" "$restore_to"
                    state=$(echo "$state" | jq --arg s "$session" 'del(.[$s])')
                    changed=true
                fi
            fi
        done < <(registry_list_names)
    done < <(jq -r '.accounts[] | select(.five_hour.used_percentage != null) | [.account, (.five_hour.used_percentage|tostring), (.five_hour.resets_at|tostring)] | @tsv' "$limits_file")

    $changed && _mg_save_state "$state"
}

model_guard_status() {
    _mg_load_config
    echo "Model Guard (enabled: $_mg_enabled)"
    echo
    echo "Curve: downgrade when hours_left >= ${_mg_curve} × (1 - usage%)"
    echo "       restore automatically when curve no longer triggers"
    echo
    echo "  Usage%   Trigger if ≥   Safe if <"
    echo "  ──────   ────────────   ─────────"
    for pct_int in 50 55 60 65 70 75 80 85 90 95; do
        local pct hours
        pct=$(echo "$pct_int / 100" | bc -l)
        hours=$(echo "$_mg_curve * (1.0 - $pct)" | bc -l | xargs printf '%.1f')
        (( pct_int >= $(echo "$_mg_emergency_usage * 100" | bc -l | cut -d. -f1) )) && { printf '  %3d%%     always          never\n' "$pct_int"; continue; }
        printf '  %3d%%     %sh left        %sh left → restore\n' "$pct_int" "$hours" "$hours"
    done
    echo
    echo "  Emergency: ≥$(echo "$_mg_emergency_usage * 100" | bc -l | cut -d. -f1)% → always sonnet"
    echo "  Below $(echo "$_mg_min_usage * 100" | bc -l | cut -d. -f1)% → never triggers"
    echo

    if [[ -f "$MODEL_GUARD_STATE" ]]; then
        local count
        count=$(jq 'length' "$MODEL_GUARD_STATE")
        if [[ "$count" -gt 0 ]]; then
            echo "Active overrides:"
            jq -r 'to_entries[] | "  \(.key): \(.value.original_model) → \(.value.current_override) (\(.value.reason // "")) since \(.value.overridden_at)"' "$MODEL_GUARD_STATE"
        else
            echo "No active overrides."
        fi
    else
        echo "No active overrides."
    fi
}

model_guard_toggle() {
    local enable="${1:-}"
    [[ ! -f "$MODEL_GUARD_CONFIG" ]] && echo '{}' > "$MODEL_GUARD_CONFIG"
    local tmp="${MODEL_GUARD_CONFIG}.tmp"
    if [[ "$enable" == "on" ]]; then
        jq '.enabled = true' "$MODEL_GUARD_CONFIG" > "$tmp" && mv "$tmp" "$MODEL_GUARD_CONFIG"
        echo "Model guard enabled."
    elif [[ "$enable" == "off" ]]; then
        jq '.enabled = false' "$MODEL_GUARD_CONFIG" > "$tmp" && mv "$tmp" "$MODEL_GUARD_CONFIG"
        echo "Model guard disabled."
    else
        echo "Usage: fleetmux model-guard [on|off]"
    fi
}

model_guard_clear() {
    local state
    state=$(_mg_load_state)
    echo "$state" | jq -r 'to_entries[] | .key + "\t" + (.value.original_model // "opus")' |
    while IFS=$'\t' read -r session model; do
        _mg_send_model "$session" "$model"
    done
    _mg_save_state '{}'
    echo "All model overrides cleared."
}
