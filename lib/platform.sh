#!/usr/bin/env bash
# Platform shims — hide GNU (Linux / WSL) vs BSD (macOS) differences in
# date/stat, and detect WSL for the Windows-host integrations.
#
# Always call these instead of raw `date -j`, `date -d`, `stat -f` or
# `stat -c`: each of those flags means something different (or nothing) on
# the other platform, and the failures are silent.
[[ -n "${_AIOS_PLATFORM_LOADED:-}" ]] && return 0; _AIOS_PLATFORM_LOADED=1

# GNU date/stat answer --version; the BSD ones reject it. Probe once.
if date --version >/dev/null 2>&1; then _AIOS_GNU_DATE=1; else _AIOS_GNU_DATE=0; fi
if stat --version >/dev/null 2>&1; then _AIOS_GNU_STAT=1; else _AIOS_GNU_STAT=0; fi

# iso_to_epoch <YYYY-MM-DDTHH:MM:SSZ>
# UTC ISO-8601 timestamp (the format tasks.json uses) → epoch seconds.
# Prints 0 for empty/malformed input so callers can keep `-gt 0` checks.
iso_to_epoch() {
    local ts="${1:-}" out="" re='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'
    if [[ "$ts" =~ $re ]]; then
        if [[ "$_AIOS_GNU_DATE" == 1 ]]; then
            out=$(date -u -d "$ts" +%s 2>/dev/null)
        else
            out=$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$ts" +%s 2>/dev/null)
        fi
    fi
    echo "${out:-0}"
}

# local_datetime_to_epoch <YYYY-MM-DD HH:MM:SS>
# Wall-clock time in the current TZ (e.g. `uptime -s` output) → epoch seconds.
# Prints 0 for empty/malformed input.
local_datetime_to_epoch() {
    local dt="${1:-}" out="" re='^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}$'
    if [[ "$dt" =~ $re ]]; then
        if [[ "$_AIOS_GNU_DATE" == 1 ]]; then
            out=$(date -d "$dt" +%s 2>/dev/null)
        else
            out=$(date -j -f "%Y-%m-%d %H:%M:%S" "$dt" +%s 2>/dev/null)
        fi
    fi
    echo "${out:-0}"
}

# epoch_fmt <epoch> <+format>
# Format epoch seconds in local time. Prints nothing on failure.
epoch_fmt() {
    local epoch="$1" fmt="$2"
    if [[ "$_AIOS_GNU_DATE" == 1 ]]; then
        date -d "@${epoch}" "$fmt" 2>/dev/null
    else
        date -r "$epoch" "$fmt" 2>/dev/null
    fi
}

# file_mtime <path>
# Modification time as epoch seconds; 0 if the file is missing/unreadable.
file_mtime() {
    local out
    if [[ "$_AIOS_GNU_STAT" == 1 ]]; then
        out=$(stat -c %Y "$1" 2>/dev/null)
    else
        out=$(stat -f %m "$1" 2>/dev/null)
    fi
    echo "${out:-0}"
}

# platform_is_wsl
# True when running inside WSL (i.e. fleetmux on a Windows host).
# AIOS_PLATFORM=wsl|linux|macos overrides detection (tests, odd kernels).
platform_is_wsl() {
    case "${AIOS_PLATFORM:-}" in
        wsl) return 0 ;;
        ?*)  return 1 ;;
    esac
    [[ -n "${WSL_DISTRO_NAME:-}" ]] && return 0
    grep -qi microsoft /proc/sys/kernel/osrelease 2>/dev/null
}

# platform_normalize_path <path>
# Windows paths (C:\code\api, C:/code/api) → WSL paths (/mnt/c/code/api)
# when wslpath is available; anything else is printed unchanged.
platform_normalize_path() {
    local p="$1" re='^[A-Za-z]:[\/]'
    if [[ "$p" =~ $re ]] && command -v wslpath >/dev/null 2>&1; then
        wslpath -u "$p" 2>/dev/null && return 0
    fi
    printf '%s\n' "$p"
}

# run_keepawake <cmd> [args...]
# Run a command while keeping the host from idle-sleeping:
#   macOS → caffeinate -i
#   WSL   → a Windows-side PowerShell execution-state request (see below)
#   else  → run the command as-is
run_keepawake() {
    local caffeinate_bin
    caffeinate_bin=$(command -v caffeinate || true)
    if [[ -n "$caffeinate_bin" ]]; then
        "$caffeinate_bin" -i "$@"
        return
    fi
    if platform_is_wsl && command -v powershell.exe >/dev/null 2>&1; then
        _wsl_keepawake "$@"
        return
    fi
    "$@"
}

# PowerShell that pins ES_CONTINUOUS|ES_SYSTEM_REQUIRED (0x80000001) on its
# own thread, then blocks reading stdin. No double quotes anywhere: they don't
# survive the WSL→Windows argv hop reliably, so [char]34 builds the C# ones.
_wsl_keepawake_ps() {
    cat <<'PS'
$q = [char]34; $sig = '[DllImport(' + $q + 'kernel32.dll' + $q + ')] public static extern uint SetThreadExecutionState(uint f);'; $k = Add-Type -MemberDefinition $sig -Name Power -Namespace FleetmuxKeepAwake -PassThru; [void]$k::SetThreadExecutionState([uint32]2147483649); [void][Console]::In.ReadToEnd()
PS
}

# The request lives exactly as long as PowerShell's stdin stays open. The only
# writer of that pipe is the left-hand subshell, which exits when the command
# does (or dies with it); the command itself gets the real stdout via fd 8, so
# neither it nor anything it spawns can hold the pipe open and keep the host
# awake after the run.
_wsl_keepawake() {
    local rc=0
    {
        { "$@" >&8 8>&-; } | powershell.exe -NoProfile -NonInteractive -Command "$(_wsl_keepawake_ps)" >/dev/null 2>&1
        rc=${PIPESTATUS[0]}
    } 8>&1 || true
    return "$rc"
}
