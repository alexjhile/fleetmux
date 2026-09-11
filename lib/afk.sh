#!/usr/bin/env bash
# shellcheck disable=SC1091
# afk.sh — `fleetmux afk` verb: overnight autonomous queue draining.
#
# Wires live dispatch around an autonomous run harness in the target repo:
# .sandcastle/loop.ts (drain the ready-for-agent queue) or
# .sandcastle/main.ts <N> (run one issue), wrapped in run_keepawake
# (caffeinate -i on macOS, a Windows execution-state request under WSL) to
# keep the machine awake. Each run records one row to tasks.json
# and a per-run JSON sidecar under .aios/afk-runs/<session>-<unix-ts>.json.
#
# Public functions:
#   afk_help                          — print usage
#   afk_run [--dry-run] <session> [<issue#>]
#                                     — drain queue or run one issue
#   afk_all [--dry-run]               — broadcast across afk_ready sessions
#   session_is_afk_ready <name>       — true iff sessions.json has afk_ready: true
[[ -n "${_AIOS_AFK_LOADED:-}" ]] && return 0; _AIOS_AFK_LOADED=1

source "$(dirname "${BASH_SOURCE[0]}")/config.sh"
source "$(dirname "${BASH_SOURCE[0]}")/registry.sh"

afk_help() {
    cat <<'EOF'
fleetmux afk — drain the ready-for-agent queue overnight (wraps Sandcastle parallel-planner).

Usage:
  fleetmux afk <session>              Drain ready-for-agent queue for one session
  fleetmux afk <session> <issue#>     Run one specific issue (debug mode)
  fleetmux afk all                    Broadcast across every afk_ready session
  fleetmux afk --help                 Show this help

Flags:
  --dry-run                       Print the command that would run; do not invoke
  --concurrency N                 (with `all`) cap parallel drains at N (default 3)

A session is eligible only if `afk_ready: true` is set on its entry in
sessions.json. Sessions without the flag are refused with a clear error.

`fleetmux afk all` skips sessions whose ready-for-agent queue is empty (probed
via `glab issue list --label ready-for-agent`). When the probe cannot
answer (no glab, network error), the drain still runs and loop.ts itself
short-circuits cleanly.
EOF
}

# session_is_afk_ready <name>
# Exit 0 iff the named session exists and has afk_ready: true.
session_is_afk_ready() {
    local name="$1"
    local val
    val=$(jq -r --arg n "$name" \
        '.[] | select(.name == $n) | .afk_ready // false' \
        "$SESSIONS_FILE" 2>/dev/null)
    [[ "$val" == "true" ]]
}

# afk_run [--dry-run] <session> [<issue#>]
afk_run() {
    local dry_run=false

    while [[ "${1:-}" == --* ]]; do
        case "$1" in
            --dry-run) dry_run=true; shift ;;
            --help|-h) afk_help; return 0 ;;
            *) echo "afk_run: unknown flag: $1" >&2; return 1 ;;
        esac
    done

    local session="${1:-}"
    local issue="${2:-}"

    if [[ -z "$session" ]]; then
        echo "afk_run: usage: fleetmux afk [--dry-run] <session> [<issue#>]" >&2
        return 1
    fi

    if ! registry_session_exists "$session"; then
        echo "session not found: '$session' is not in sessions.json" >&2
        return 1
    fi

    if ! session_is_afk_ready "$session"; then
        echo "session '$session' is missing afk_ready: true in sessions.json — refusing to run" >&2
        return 1
    fi

    if [[ "$dry_run" == true ]]; then
        if [[ -n "$issue" ]]; then
            echo "would run: npx tsx .sandcastle/main.ts ${issue} (session=${session})"
        else
            echo "would run drain via .sandcastle/loop.ts (session=${session})"
        fi
        return 0
    fi

    # Per-session lockfile prevents two drains racing on the same backlog.
    # mkdir is atomic; trap releases on normal exit and on signal.
    local lock_dir="${AIOS_DIR}/.aios/locks"
    local lock="${lock_dir}/afk-${session}.lock"
    mkdir -p "$lock_dir"
    if ! mkdir "$lock" 2>/dev/null; then
        echo "another drain already running on ${session} (lock: ${lock})" >&2
        return 1
    fi
    # shellcheck disable=SC2064
    trap "rm -rf '${lock}'" EXIT INT TERM HUP

    local session_path
    session_path=$(registry_get_field "$session" "path")
    if [[ -z "$session_path" ]]; then
        echo "afk_run: session '$session' has no path field in sessions.json" >&2
        return 1
    fi
    if [[ ! -d "$session_path" ]]; then
        echo "afk_run: session path does not exist: ${session_path}" >&2
        return 1
    fi

    local script
    if [[ -n "$issue" ]]; then
        script=".sandcastle/main.ts"
    else
        script=".sandcastle/loop.ts"
    fi
    if [[ ! -f "${session_path}/${script}" ]]; then
        echo "afk_run: ${session_path}/${script} not found — cannot dispatch" >&2
        return 1
    fi

    local npx_bin
    npx_bin=$(command -v npx || true)
    if [[ -z "$npx_bin" ]]; then
        echo "afk_run: npx not found on PATH — cannot dispatch" >&2
        return 1
    fi

    # Sidecar dir + per-run filename
    local runs_dir="${AIOS_DIR}/.aios/afk-runs"
    mkdir -p "$runs_dir"
    local ts started_at
    ts=$(date +%s)
    started_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local sidecar="${runs_dir}/${session}-${ts}.json"

    local mode
    if [[ -n "$issue" ]]; then mode="oneshot"; else mode="drain"; fi

    local start_sec end_sec duration_s exit_code=0
    start_sec=$(date +%s)

    (
        cd "$session_path" || exit 1
        export AIOS_AFK_SESSION="$session"
        export AIOS_AFK_LOG="$sidecar"
        # Keep the host awake for the whole drain (no-op where unsupported).
        if [[ -n "$issue" ]]; then
            run_keepawake "$npx_bin" tsx "$script" "$issue"
        else
            run_keepawake "$npx_bin" tsx "$script"
        fi
    ) || exit_code=$?

    end_sec=$(date +%s)
    duration_s=$((end_sec - start_sec))
    local finished_at
    finished_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    afk_record_run "$session" "$mode" "$started_at" "$finished_at" \
                   "$duration_s" "$sidecar" "$exit_code" "$issue"

    return $exit_code
}

# afk_record_run <session> <mode> <started_at> <finished_at> <duration_s>
#                <sidecar> <exit_code> [issue]
#
# Folds a finished AFK run into tasks.json (one row, mode=afk) and ensures
# the per-run JSON sidecar exists. If loop.ts wrote the sidecar with
# tickets_*/halt_reason fields, those are surfaced in the tasks.json row;
# otherwise a stub sidecar is written so the audit trail is intact.
afk_record_run() {
    local session="$1"
    local mode="$2"           # drain|oneshot
    local started_at="$3"
    local finished_at="$4"
    local duration_s="$5"
    local sidecar="$6"
    local exit_code="$7"
    local issue="${8:-}"

    local tickets_attempted=0 tickets_completed=0 tickets_stuck=0
    local halt_reason="unknown"

    if [[ -f "$sidecar" ]]; then
        tickets_attempted=$(jq -r '.tickets_attempted // 0' "$sidecar" 2>/dev/null || echo 0)
        tickets_completed=$(jq -r '.tickets_completed // 0' "$sidecar" 2>/dev/null || echo 0)
        tickets_stuck=$(jq -r '.tickets_stuck // 0' "$sidecar" 2>/dev/null || echo 0)
        halt_reason=$(jq -r '.halt_reason // "unknown"' "$sidecar" 2>/dev/null || echo "unknown")
    else
        # No sidecar — loop.ts crashed before writing, or one-shot main.ts
        # has no sidecar emission. Stub one so the audit trail is intact.
        if [[ "$mode" == "oneshot" ]]; then
            tickets_attempted=1
            if [[ "$exit_code" -eq 0 ]]; then
                tickets_completed=1
                halt_reason="oneshot-completed"
            else
                tickets_stuck=1
                halt_reason="oneshot-failed"
            fi
        else
            halt_reason="drain-no-sidecar"
        fi
        jq -n \
            --arg session "$session" \
            --arg mode "$mode" \
            --arg started_at "$started_at" \
            --arg finished_at "$finished_at" \
            --argjson duration_s "$duration_s" \
            --argjson tickets_attempted "$tickets_attempted" \
            --argjson tickets_completed "$tickets_completed" \
            --argjson tickets_stuck "$tickets_stuck" \
            --arg halt_reason "$halt_reason" \
            --arg issue "$issue" \
            '{session: $session, mode: $mode, started_at: $started_at,
              finished_at: $finished_at, duration_s: $duration_s,
              tickets_attempted: $tickets_attempted,
              tickets_completed: $tickets_completed,
              tickets_stuck: $tickets_stuck,
              halt_reason: $halt_reason, issue: $issue,
              per_ticket: []}' > "$sidecar"
    fi

    # Compose the tasks.json entry
    local task_desc
    if [[ "$mode" == "oneshot" ]]; then
        task_desc="afk: issue #${issue}"
    else
        task_desc="afk drain (${tickets_completed}/${tickets_attempted} completed, halt=${halt_reason})"
    fi
    local status
    if [[ "$exit_code" -eq 0 ]]; then status="completed"; else status="failed"; fi
    local task_id
    task_id="t_$(date +%s)_${session}_afk"

    local entry
    entry=$(jq -n \
        --arg id "$task_id" \
        --arg session "$session" \
        --arg task "$task_desc" \
        --arg mode "afk" \
        --arg status "$status" \
        --arg dispatched_at "$started_at" \
        --arg completed_at "$finished_at" \
        --arg duration_s "$duration_s" \
        --arg sidecar "$sidecar" \
        --argjson tickets_attempted "$tickets_attempted" \
        --argjson tickets_completed "$tickets_completed" \
        --argjson tickets_stuck "$tickets_stuck" \
        --arg halt_reason "$halt_reason" \
        --arg source "afk" \
        '{id: $id, session: $session, task: $task, mode: $mode,
          status: $status, dispatched_at: $dispatched_at,
          completed_at: $completed_at, duration_s: $duration_s,
          output_preview: "", source: $source,
          afk: {sidecar: $sidecar,
                started_at: $dispatched_at,
                finished_at: $completed_at,
                duration_s: ($duration_s | tonumber),
                tickets_attempted: $tickets_attempted,
                tickets_completed: $tickets_completed,
                tickets_stuck: $tickets_stuck,
                halt_reason: $halt_reason}}')

    acquire_lock 5
    local tmp_file="${TASKS_FILE}.tmp"
    jq --argjson new "$entry" --argjson max "$TASKS_MAX" \
        '[$new] + . | .[:$max]' "$TASKS_FILE" > "$tmp_file" && mv "$tmp_file" "$TASKS_FILE"
    release_lock
}

# afk_session_queue_count <session>
# Echoes "0", a positive integer, or "unknown" if the count cannot be
# determined (no glab, no repo, transport error). afk_all treats "unknown"
# as "do not skip" — let loop.ts short-circuit safely instead of guessing.
afk_session_queue_count() {
    local session="$1"
    local session_path glab_bin
    session_path=$(registry_get_field "$session" "path")
    glab_bin=$(command -v glab || true)

    if [[ -z "$glab_bin" || -z "$session_path" || ! -d "$session_path" ]]; then
        echo "unknown"
        return 0
    fi

    local raw count
    raw=$(cd "$session_path" && "$glab_bin" issue list \
        --label ready-for-agent \
        --output json 2>/dev/null) || { echo "unknown"; return 0; }
    count=$(echo "$raw" | jq 'length' 2>/dev/null)
    if ! [[ "$count" =~ ^[0-9]+$ ]]; then
        echo "unknown"
        return 0
    fi
    echo "$count"
}

# afk_all [--dry-run] [--concurrency N]
# Broadcast across every session with afk_ready: true. Capped parallel
# (default 3); each session is run via afk_run; sessions whose
# ready-for-agent queue is provably empty are skipped without a drain.
# Stdout: one JSON object {sessions: [<per-session sidecar shape>]}.
afk_all() {
    local dry_run=false
    local concurrency=3

    while [[ "${1:-}" == --* ]]; do
        case "$1" in
            --dry-run)     dry_run=true; shift ;;
            --concurrency) concurrency="$2"; shift 2 ;;
            --help|-h)     afk_help; return 0 ;;
            *) echo "afk_all: unknown flag: $1" >&2; return 1 ;;
        esac
    done

    if ! [[ "$concurrency" =~ ^[1-9][0-9]*$ ]]; then
        echo "afk_all: --concurrency must be a positive integer (got '${concurrency}')" >&2
        return 1
    fi

    # Collect afk_ready sessions (bash 3.2-compatible — macOS lacks mapfile)
    local ready_list=()
    local _line
    while IFS= read -r _line; do
        [[ -n "$_line" ]] && ready_list+=("$_line")
    done < <(jq -r '.[] | select(.afk_ready == true) | .name' \
        "$SESSIONS_FILE" 2>/dev/null)

    if [[ "$dry_run" == true ]]; then
        local joined="${ready_list[*]:-<none>}"
        echo "would run drain via .sandcastle/loop.ts across afk_ready sessions: ${joined}"
        return 0
    fi

    if [[ ${#ready_list[@]} -eq 0 ]]; then
        printf '{"sessions": []}\n'
        return 0
    fi

    # Pre-flight skip-empty pass + bucket the rest as "to_run".
    # Note: bash 3.2 + set -u — empty-array deref `"${arr[@]}"` errors as
    # unbound variable. Use the `${arr[@]+"${arr[@]}"}` idiom (expand to
    # nothing when unset) for every for-loop over a possibly-empty array.
    local to_run=() skipped=()
    local s
    for s in ${ready_list[@]+"${ready_list[@]}"}; do
        local count
        count=$(afk_session_queue_count "$s")
        if [[ "$count" == "0" ]]; then
            skipped+=("$s")
            echo "afk_all: skipping ${s} — queue is empty" >&2
        else
            to_run+=("$s")
        fi
    done

    # Spawn afk_run for each to_run session, capped at $concurrency.
    # Each child re-sources afk.sh in its own subshell so the trap doesn't
    # leak into the parent.
    local lib_path="${BASH_SOURCE[0]}"
    local pids=()
    local in_flight=0
    local exit_overall=0
    for s in ${to_run[@]+"${to_run[@]}"}; do
        (
            # shellcheck disable=SC1090
            source "$lib_path"
            afk_run "$s"
        ) &
        pids+=("$!")
        in_flight=$((in_flight + 1))
        if [[ $in_flight -ge $concurrency ]]; then
            # Wait on the oldest pid (bash 3.2 lacks `wait -n`).
            # For capped concurrency this is equivalent: we just need one
            # slot to free, and the oldest is most likely to be done first.
            if ! wait "${pids[0]}" 2>/dev/null; then
                exit_overall=1
            fi
            pids=("${pids[@]:1}")
            in_flight=$((in_flight - 1))
        fi
    done

    # Drain remaining
    local pid
    for pid in ${pids[@]+"${pids[@]}"}; do
        wait "$pid" 2>/dev/null || exit_overall=1
    done

    # Aggregate per-session sidecars into the morning briefing.
    local runs_dir="${AIOS_DIR}/.aios/afk-runs"
    local briefing='{"sessions": []}'
    for s in ${to_run[@]+"${to_run[@]}"}; do
        # Most recent sidecar for this session
        local sidecar
        sidecar=$(find "$runs_dir" -name "${s}-*.json" 2>/dev/null \
            | sort | tail -1)
        if [[ -n "$sidecar" && -f "$sidecar" ]]; then
            briefing=$(echo "$briefing" | jq --slurpfile entry "$sidecar" \
                '.sessions += [$entry[0]]')
        else
            briefing=$(echo "$briefing" | jq --arg name "$s" \
                '.sessions += [{session: $name, mode: "drain", halt_reason: "no-sidecar", tickets_attempted: 0, tickets_completed: 0, tickets_stuck: 0, per_ticket: []}]')
        fi
    done
    for s in ${skipped[@]+"${skipped[@]}"}; do
        briefing=$(echo "$briefing" | jq --arg name "$s" \
            '.sessions += [{session: $name, mode: "drain", halt_reason: "queue-empty", tickets_attempted: 0, tickets_completed: 0, tickets_stuck: 0, per_ticket: []}]')
    done

    echo "$briefing"
    return $exit_overall
}
