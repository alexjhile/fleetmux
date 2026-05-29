#!/usr/bin/env bash
# shellcheck disable=SC2059
# Display formatting — table output with ANSI colors
[[ -n "${_AIOS_DISPLAY_LOADED:-}" ]] && return 0; _AIOS_DISPLAY_LOADED=1

# Colors
C_RESET="\033[0m"
C_BOLD="\033[1m"
C_DIM="\033[2m"
C_GREEN="\033[32m"
C_YELLOW="\033[33m"
C_RED="\033[31m"
C_CYAN="\033[36m"
C_BLUE="\033[34m"
C_MAGENTA="\033[35m"

color_status() {
    local status="$1"
    case "$status" in
        running)  printf "${C_GREEN}%-10s${C_RESET}" "$status" ;;
        idle)     printf "${C_YELLOW}%-10s${C_RESET}" "$status" ;;
        stopped)  printf "${C_DIM}%-10s${C_RESET}" "$status" ;;
        error)    printf "${C_RED}%-10s${C_RESET}" "$status" ;;
        *)        printf "%-10s" "$status" ;;
    esac
}

color_type() {
    local type="$1"
    case "$type" in
        local)    printf "${C_CYAN}%-8s${C_RESET}" "$type" ;;
        remote)   printf "${C_MAGENTA}%-8s${C_RESET}" "$type" ;;
        utility)  printf "${C_BLUE}%-8s${C_RESET}" "$type" ;;
        *)        printf "%-8s" "$type" ;;
    esac
}

print_header() {
    echo ""
    printf "  ${C_BOLD}%-3s %-14s %-8s %-22s %-10s %s${C_RESET}\n" "#" "Name" "Type" "Target" "Status" "Description"
    echo "  ─── ────────────── ──────── ────────────────────── ────────── ──────────────────────────"
}

print_row() {
    local num="$1" name="$2" type="$3" target="$4" status="$5" desc="$6"
    printf "  %-3s %-14s " "$num" "$name"
    color_type "$type"
    printf " %-22s " "$target"
    color_status "$status"
    printf " %s\n" "$desc"
}

print_status_header() {
    echo ""
    printf "  ${C_BOLD}%-3s %-14s %-8s %-22s %-10s %s${C_RESET}\n" "#" "Name" "Type" "Target" "Status" "Last Task"
    echo "  ─── ────────────── ──────── ────────────────────── ────────── ──────────────────────────────────"
}

print_status_row() {
    local num="$1" name="$2" type="$3" target="$4" status="$5" last_task="$6"
    printf "  %-3s %-14s " "$num" "$name"
    color_type "$type"
    printf " %-22s " "$target"
    color_status "$status"
    printf " %s\n" "$last_task"
}

print_divider() {
    echo "  ──────────────────────────────────────────────────────────────────────────────────────"
}

print_summary() {
    local total="$1" running="$2" idle="$3" stopped="$4"
    echo ""
    printf "  ${C_BOLD}%s${C_RESET} sessions: ${C_GREEN}%s running${C_RESET}, ${C_YELLOW}%s idle${C_RESET}, ${C_DIM}%s stopped${C_RESET}\n" \
        "$total" "$running" "$idle" "$stopped"
    echo ""
}

print_error() {
    printf "${C_RED}Error: %s${C_RESET}\n" "$1" >&2
}

print_success() {
    printf "${C_GREEN}%s${C_RESET}\n" "$1"
}

print_info() {
    printf "${C_CYAN}%s${C_RESET}\n" "$1"
}
