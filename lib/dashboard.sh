#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2059
# Dashboard — tmux menu and split-pane status display
[[ -n "${_FLEETMUX_DASHBOARD_LOADED:-}" ]] && return 0; _FLEETMUX_DASHBOARD_LOADED=1

_DASH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_DASH_DIR}/config.sh"
source "${_DASH_DIR}/registry.sh"
source "${_DASH_DIR}/status.sh"
source "${_DASH_DIR}/display.sh"

DASH_PANE_FILE="${FLEETMUX_DIR}/.dash-pane"

# ─── Helpers ──────────────────────────────────────────────────────────────

# Require tmux environment
_require_tmux() {
    if [[ -z "${TMUX:-}" ]]; then
        print_error "Must be run inside tmux"
        return 1
    fi
}

# Relative time string from ISO timestamp
_relative_time() {
    local ts="$1"
    [[ -z "$ts" || "$ts" == "null" ]] && return

    local task_ts now_ts diff_s
    task_ts=$(iso_to_epoch "$ts")
    [[ "$task_ts" -eq 0 ]] && return
    now_ts=$(date +%s)
    diff_s=$((now_ts - task_ts))

    if [[ $diff_s -lt 60 ]]; then echo "now"
    elif [[ $diff_s -lt 3600 ]]; then echo "$((diff_s / 60))m"
    elif [[ $diff_s -lt 86400 ]]; then echo "$((diff_s / 3600))h"
    else echo "$((diff_s / 86400))d"
    fi
}

# ─── Menu ─────────────────────────────────────────────────────────────────

# Show interactive tmux popup menu with all sessions
show_menu() {
    _require_tmux || return 1

    local -a args=(-T " fleetmux Sessions " -x C -y C)
    local idx=0
    local keys=(1 2 3 4 5 6 7 8 9 0)

    while IFS= read -r name; do
        local type key icon label cmd
        type=$(registry_get_field "$name" "type")
        key="${keys[$idx]:-}"

        if [[ "$type" == "remote" ]]; then
            type="rem"
        else
            type="loc"
        fi

        if tmux_window_exists "$name"; then
            icon="●"
            cmd="select-window -t ${FLEETMUX_TMUX_SESSION}:${name}"
        else
            icon="○"
            cmd="run-shell 'fleetmux start ${name} 2>&1'"
        fi

        label=$(printf "%s %-14s [%s]" "$icon" "$name" "$type")
        args+=("$label" "$key" "$cmd")
        idx=$((idx + 1))
    done < <(registry_list_names)

    # Separator + bulk actions
    args+=("" "" "")
    args+=("Start All" "S" "run-shell 'fleetmux startall --all 2>&1'")
    args+=("Stop All"  "X" "run-shell 'fleetmux stopall 2>&1'")
    args+=("" "" "")
    args+=("Dashboard" "D" "run-shell 'fleetmux dash 2>&1'")

    $TMUX_CMD display-menu "${args[@]}"
}

# ─── Dashboard Status Loop ───────────────────────────────────────────────

# Extract live effort level from a session's tmux pane.
# Priority:
#   1. Most recent "/effort <level>" or "Effort set to <level>" command
#   2. Startup banner: "...with <level> effort..."
#   3. Fallback to settings.json effortLevel
_dash_session_effort() {
    local name="$1"
    if ! tmux_window_exists "$name"; then
        return 0
    fi
    local pane
    pane=$(_dash_capture_panes "$name")
    # Most recent explicit /effort setting (a command response).
    local set_effort
    set_effort=$(echo "$pane" | grep -oE "[Ee]ffort (set to|to) (xhigh|high|medium|low)" | tail -1 | grep -oE "(xhigh|high|medium|low)$")
    if [[ -n "$set_effort" ]]; then
        echo "$set_effort"
        return 0
    fi
    # Banner: "with high effort", "with xhigh effort", etc.
    local banner_effort
    banner_effort=$(echo "$pane" | grep -oE "with (xhigh|high|medium|low) effort" | tail -1 | sed -E 's/with //; s/ effort//')
    if [[ -n "$banner_effort" ]]; then
        echo "$banner_effort"
        return 0
    fi
    # Status line (Claude Code >= 2.1): "● high · /effort"
    local line_effort
    line_effort=$(echo "$pane" | grep -oE "(xhigh|high|medium|low) · /effort" | tail -1 | grep -oE "^(xhigh|high|medium|low)")
    if [[ -n "$line_effort" ]]; then
        echo "$line_effort"
        return 0
    fi
    # Fallback: settings.json
    local cfg_effort
    cfg_effort=$(jq -r '.effortLevel // ""' "$HOME/.claude/settings.json" 2>/dev/null)
    if [[ -n "$cfg_effort" ]]; then
        echo "$cfg_effort*"
    fi
}

# Capture the scrollback of every pane in a session's window.
# homebase keeps Claude in pane 1 (the dashboard owns pane 0), so capturing
# only the active pane missed it.
_dash_capture_panes() {
    local name="$1" idx out=""
    while IFS= read -r idx; do
        [[ -z "$idx" ]] && continue
        out+=$($TMUX_CMD capture-pane -t "${FLEETMUX_TMUX_SESSION}:${name}.${idx}" -p -S -10000 2>/dev/null)
        out+=$'\n'
    done < <($TMUX_CMD list-panes -t "${FLEETMUX_TMUX_SESSION}:${name}" -F '#{pane_index}' 2>/dev/null)
    printf '%s' "$out"
}

# Model recorded in the session's pinned conversation log. tmux scrollback is
# capped (2000 lines by default), so a busy session has long since scrolled its
# startup banner away; the log always carries the last turn's model.
_dash_session_model_log() {
    local name="$1" path conv slug dir file model ver
    path=$(registry_get_field "$name" "path")
    conv=$(registry_get_field "$name" "conversation_id")
    [[ -z "$path" ]] && return 0
    slug=$(printf '%s' "$path" | sed 's|[/_.]|-|g')
    dir="${CLAUDE_CODE_PROJECTS:-$HOME/.claude/projects}/${slug}"
    [[ -d "$dir" ]] || return 0
    file="${dir}/${conv}.jsonl"
    if [[ -z "$conv" || ! -f "$file" ]]; then
        # shellcheck disable=SC2012  # BSD find has no -printf; ls -t is portable here
        file=$(ls -t "${dir}"/*.jsonl 2>/dev/null | head -1)
    fi
    [[ -n "$file" && -f "$file" ]] || return 0
    # Skip sidechain (subagent) turns — they can run a different model.
    model=$(tail -200 "$file" 2>/dev/null \
        | jq -r 'select((.isSidechain // false) | not) | .message.model? // empty' 2>/dev/null \
        | grep -v '^<' | tail -1)
    [[ -z "$model" ]] && return 0
    case "$model" in
        claude-opus-*)   ver="${model#claude-opus-}";   model="Opus" ;;
        claude-sonnet-*) ver="${model#claude-sonnet-}"; model="Sonnet" ;;
        claude-haiku-*)  ver="${model#claude-haiku-}";  model="Haiku" ;;
        *) return 0 ;;
    esac
    ver="${ver%%[*}"                                  # drop a [1m] context tag
    ver="${ver%%-2[0-9][0-9][0-9][0-9][0-9][0-9][0-9]}"  # drop a trailing date
    ver=$(printf '%s' "$ver" | tr '-' '.')
    printf '%s %s\n' "$model" "$ver"
}

# Extract live model from a session's tmux pane.
# Looks at scrollback for either:
#  - "Set model to <Name> X.Y" (most recent /model command — wins)
#  - Startup banner: "Opus 4.7 (...) with high effort · Claude Max"
# Echoes empty string if session not running or model not detectable.
_dash_session_model() {
    local name="$1"
    if ! tmux_window_exists "$name"; then
        return 0
    fi
    # The conversation log is authoritative; the pane is only a fallback.
    local from_log
    from_log=$(_dash_session_model_log "$name")
    if [[ -n "$from_log" ]]; then
        echo "$from_log"
        return 0
    fi
    local pane
    pane=$(_dash_capture_panes "$name")
    # Most recent explicit /model setting wins.
    local set_model
    set_model=$(echo "$pane" | grep -oE "Set model to (Opus|Sonnet|Haiku)[ -][0-9]+(\.[0-9]+)?" | tail -1 | sed -E 's/Set model to //')
    if [[ -n "$set_model" ]]; then
        echo "$set_model"
        return 0
    fi
    # Startup banner search.
    local banner
    banner=$(echo "$pane" | grep -iE "effort|Claude Code v|Claude Max|Claude Pro" | tail -5)
    local model
    model=$(echo "$banner" | grep -oE "(Opus|Sonnet|Haiku)[ -]+[0-9]+(\.[0-9]+)?" | tail -1)
    if [[ -n "$model" ]]; then
        echo "$model"
        return 0
    fi
    # Last resort: fall back to the global settings.json model.
    # Maps "claude-opus-4-7" → "Opus 4.7", "opus" → "Opus*" (unknown version).
    local cfg_model
    cfg_model=$(jq -r '.model // ""' "$HOME/.claude/settings.json" 2>/dev/null)
    if [[ -n "$cfg_model" ]]; then
        case "$cfg_model" in
            claude-opus-*)   echo "Opus ${cfg_model#claude-opus-}" | sed 's/-/./' ;;
            claude-sonnet-*) echo "Sonnet ${cfg_model#claude-sonnet-}" | sed 's/-/./' ;;
            claude-haiku-*)  echo "Haiku ${cfg_model#claude-haiku-}" | sed 's/-/./' ;;
            opus)            echo "Opus*" ;;
            sonnet)          echo "Sonnet*" ;;
            haiku)           echo "Haiku*" ;;
        esac
    fi
}

# Compact status display (runs in the top pane)
dash_status_loop() {
    local interval="${1:-30}"

    # Re-source in case we're a fresh bash process
    source "${_DASH_DIR}/config.sh" 2>/dev/null || true
    source "${_DASH_DIR}/registry.sh" 2>/dev/null || true
    source "${_DASH_DIR}/status.sh" 2>/dev/null || true

    while true; do
        printf '\033[2J\033[H'  # clear screen + cursor home

        local running=0 total=0 active=0
        local -a rows=()

        while IFS= read -r name; do
            total=$((total + 1))
            local type icon status_str type_label task_icon

            type=$(registry_get_field "$name" "type")
            [[ "$type" == "remote" ]] && type_label="\033[35mVPS\033[0m" || type_label="\033[36mM1 \033[0m"

            local model_str="" effort_str=""
            if tmux_window_exists "$name"; then
                icon="\033[32m●\033[0m"
                status_str="\033[32mrun\033[0m"
                running=$((running + 1))
                local mdl
                mdl=$(_dash_session_model "$name")
                if [[ -n "$mdl" ]]; then
                    # Color: Opus = cyan, Sonnet = magenta, Haiku = yellow
                    case "$mdl" in
                        Opus*)   model_str="\033[36m${mdl}\033[0m" ;;
                        Sonnet*) model_str="\033[35m${mdl}\033[0m" ;;
                        Haiku*)  model_str="\033[33m${mdl}\033[0m" ;;
                        *)       model_str="$mdl" ;;
                    esac
                else
                    model_str="\033[90m—\033[0m"
                fi
                local eff
                eff=$(_dash_session_effort "$name")
                if [[ -n "$eff" ]]; then
                    case "$eff" in
                        xhigh*) effort_str="\033[91m${eff}\033[0m" ;;  # bright red
                        high*)  effort_str="\033[31m${eff}\033[0m" ;;  # red
                        medium*) effort_str="\033[33m${eff}\033[0m" ;; # yellow
                        low*)   effort_str="\033[32m${eff}\033[0m" ;;  # green
                        *)      effort_str="$eff" ;;
                    esac
                else
                    effort_str="\033[90m—\033[0m"
                fi
            else
                icon="\033[90m○\033[0m"
                status_str="\033[90moff\033[0m"
                model_str="\033[90m—\033[0m"
                effort_str="\033[90m—\033[0m"
            fi

            # Get last task with full context: task text, status, age
            local task_text="" task_status="" task_ts="" task_age=""
            local task_info
            task_info=$(jq -r --arg s "$name" \
                '[.[] | select(.session == $s)] | first | "\(.task // "")|\(.status // "")|\(.completed_at // .dispatched_at // "")"' \
                "$TASKS_FILE" 2>/dev/null)

            task_text="${task_info%%|*}"
            local rest="${task_info#*|}"
            task_status="${rest%%|*}"
            task_ts="${rest##*|}"

            [[ "$task_text" == "null" || -z "$task_text" ]] && task_text=""
            task_text="${task_text:0:28}"

            # Task status indicator
            case "$task_status" in
                dispatched)
                    task_icon="\033[33m⟳\033[0m"  # yellow — actively working
                    active=$((active + 1))
                    ;;
                completed)
                    task_icon="\033[32m✓\033[0m"  # green — done
                    ;;
                failed)
                    task_icon="\033[31m✗\033[0m"  # red — failed
                    ;;
                *)
                    task_icon=" "
                    ;;
            esac

            # Relative time
            task_age=$(_relative_time "$task_ts")
            [[ -z "$task_age" ]] && task_age="  "

            if [[ -n "$task_text" ]]; then
                rows+=("$(printf "  %b %-13s %b %b %-18b %-15b %b %-28s \033[90m%s\033[0m" \
                    "$icon" "$name" "$type_label" "$status_str" "$model_str" "$effort_str" "$task_icon" "$task_text" "$task_age")")
            else
                rows+=("$(printf "  %b %-13s %b %b %-18b %-15b   \033[90m—\033[0m" \
                    "$icon" "$name" "$type_label" "$status_str" "$model_str" "$effort_str")")
            fi
        done < <(registry_list_names)

        # Header
        local header_extra=""
        [[ $active -gt 0 ]] && header_extra=" │ \033[33m${active} active\033[0m"
        printf "  \033[1mfleetmux\033[0m │ %d sessions │ \033[32m%d running\033[0m%b │ %s\n" \
            "$total" "$running" "$header_extra" "$(date +%H:%M:%S)"
        printf "  ─────┼──────────────┼──────────────────────┼──────────\n"

        # Column labels
        printf "  \033[2m     Session       Where Status Model        Effort        Task                          Age\033[0m\n"

        # Session rows
        for row in "${rows[@]}"; do
            printf '%b\n' "$row"
        done

        # Footer
        printf "  ──────────────────────────────────────────────────────────────\n"
        printf "  \033[2m⟳ = working   ✓ = done   ✗ = failed   [Ctrl+b g] menu   [Ctrl+b a] toggle\033[0m\n"

        sleep "$interval"
    done
}

# ─── Dashboard Layout ────────────────────────────────────────────────────

# Start dashboard (split pane with live status at top)
dash_start() {
    _require_tmux || return 1

    # Check if already running
    if [[ -f "$DASH_PANE_FILE" ]]; then
        local existing
        existing=$(cat "$DASH_PANE_FILE")
        if tmux list-panes -a -F "#{pane_id}" 2>/dev/null | grep -qx "$existing"; then
            print_info "Dashboard already running (prefix+a to toggle)"
            return 0
        fi
        rm -f "$DASH_PANE_FILE"
    fi

    # Split: new pane at top, 30% height
    local pane_id
    pane_id=$($TMUX_CMD split-window -b -v -l 30% -P -F "#{pane_id}" \
        "exec bash -c 'source \"${FLEETMUX_DIR}/lib/dashboard.sh\" && dash_status_loop 30'")

    printf '%s' "$pane_id" > "$DASH_PANE_FILE"

    # Install keybindings
    install_keybindings

    print_info "Dashboard on — prefix+g menu, prefix+a toggle"
}

# Toggle dashboard pane on/off
dash_toggle() {
    _require_tmux || return 1

    if [[ -f "$DASH_PANE_FILE" ]]; then
        local pane_id
        pane_id=$(cat "$DASH_PANE_FILE")
        if tmux list-panes -a -F "#{pane_id}" 2>/dev/null | grep -qx "$pane_id"; then
            $TMUX_CMD kill-pane -t "$pane_id" 2>/dev/null
            rm -f "$DASH_PANE_FILE"
            return 0
        fi
        rm -f "$DASH_PANE_FILE"
    fi

    dash_start
}

# ─── Keybindings ──────────────────────────────────────────────────────────

# Install tmux keybindings for menu and dashboard
install_keybindings() {
    $TMUX_CMD bind-key g run-shell "fleetmux menu" 2>/dev/null
    $TMUX_CMD bind-key a run-shell "fleetmux dash toggle" 2>/dev/null
}
