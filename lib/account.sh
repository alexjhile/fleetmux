#!/usr/bin/env bash
# shellcheck disable=SC1091
# Account profiles — multi-account OAuth token management.
#
# Tokens are generated once via `claude setup-token` (long-lived) and stored
# centrally under $FLEETMUX_SECRETS_DIR/claude-accounts/<name>.token. fleetmux
# distributes them to $HOME/.fleetmux-accounts/<name>.token on every managed
# machine (local + remote) and installs the ~/.fleetmux-claude wrapper which reads
# $FLEETMUX_ACCOUNT at launch time to pick the right token.
[[ -n "${_FLEETMUX_ACCOUNT_LOADED:-}" ]] && return 0; _FLEETMUX_ACCOUNT_LOADED=1

source "$(dirname "${BASH_SOURCE[0]}")/config.sh"
source "$(dirname "${BASH_SOURCE[0]}")/registry.sh"

# Central (source-of-truth) accounts dir — lives under the secrets dir.
ACCOUNTS_SECRETS_DIR="${ACCOUNTS_SECRETS_DIR:-${SECRETS_DIR}/claude-accounts}"
# Local deploy dir (on this machine, and mirrored to every remote host).
ACCOUNTS_LOCAL_DIR="${HOME}/.fleetmux-accounts"
# Wrapper binary (committed to fleetmux/bin, deployed to $HOME/.fleetmux-claude).
ACCOUNTS_WRAPPER_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bin/fleetmux-claude"
ACCOUNTS_WRAPPER_DEST="${HOME}/.fleetmux-claude"
# Usage parser script (emits per-session JSON usage totals).
USAGE_PARSER_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bin/fleetmux-usage-parser"
USAGE_PARSER_DEST="${HOME}/.fleetmux-usage-parser"
# Metadata manifest — email, subscription tier, timestamps per account.
ACCOUNTS_META_FILE="${ACCOUNTS_SECRETS_DIR}/accounts.json"

_account_meta_init() {
    mkdir -p "$ACCOUNTS_SECRETS_DIR"
    [[ -f "$ACCOUNTS_META_FILE" ]] || echo '{}' > "$ACCOUNTS_META_FILE"
}

# Detect email + subscription by running the wrapper with FLEETMUX_ACCOUNT set,
# capturing claude auth status JSON. Returns JSON or empty on failure.
_account_detect() {
    local name="$1"
    [[ -x "$ACCOUNTS_WRAPPER_DEST" ]] || return 1
    [[ -r "${ACCOUNTS_LOCAL_DIR}/${name}.token" ]] || return 1
    FLEETMUX_ACCOUNT="$name" "$ACCOUNTS_WRAPPER_DEST" auth status 2>/dev/null || return 1
}

# Save metadata (email, subscription) for an account name.
_account_save_meta() {
    local name="$1" email="$2" subscription="$3"
    _account_meta_init
    local tmp="${ACCOUNTS_META_FILE}.tmp"
    jq --arg n "$name" --arg e "$email" --arg s "$subscription" \
       --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
       '.[$n] = ((.[$n] // {}) + {email: $e, subscription: $s, updated_at: $ts})' \
       "$ACCOUNTS_META_FILE" > "$tmp" && mv "$tmp" "$ACCOUNTS_META_FILE"
}

# Get a metadata field for an account. Prints empty string if missing.
_account_get_meta() {
    local name="$1" field="$2"
    _account_meta_init
    jq -r --arg n "$name" --arg f "$field" '.[$n][$f] // ""' "$ACCOUNTS_META_FILE"
}

# Detect + persist metadata for an account. Silent on failure.
account_detect_meta() {
    local name="$1"
    local status email subscription
    status=$(_account_detect "$name") || return 1
    email=$(jq -r '.email // ""' <<<"$status" 2>/dev/null)
    subscription=$(jq -r '.subscriptionType // .subscription_type // ""' <<<"$status" 2>/dev/null)
    if [[ -n "$email" || -n "$subscription" ]]; then
        _account_save_meta "$name" "$email" "$subscription"
        return 0
    fi
    return 1
}

# List all known accounts (from the secrets dir).
account_list() {
    [[ -d "$ACCOUNTS_SECRETS_DIR" ]] || return 0
    find "$ACCOUNTS_SECRETS_DIR" -maxdepth 1 -type f -name '*.token' -print0 2>/dev/null |
        xargs -0 -n1 basename 2>/dev/null | sed 's/\.token$//' | sort
}

# Check if an account exists in the secrets dir.
account_exists() {
    local name="$1"
    [[ -f "${ACCOUNTS_SECRETS_DIR}/${name}.token" ]]
}

# Read token content (used for deploy). Trims whitespace.
account_read_token() {
    local name="$1"
    local file="${ACCOUNTS_SECRETS_DIR}/${name}.token"
    [[ -r "$file" ]] || return 1
    tr -d '[:space:]' < "$file"
}

# Add a new account. Reads token from stdin if not passed as arg.
# Usage: account_add <name> [token] [email] [subscription]
account_add() {
    local name="$1"
    local token="${2:-}"
    local email="${3:-}"
    local subscription="${4:-}"

    if [[ -z "$name" ]]; then
        echo "Error: account name required" >&2
        return 1
    fi

    if account_exists "$name"; then
        echo "Error: account '$name' already exists (use 'fleetmux account remove' first)" >&2
        return 1
    fi

    if [[ -z "$token" ]]; then
        if [[ -t 0 ]]; then
            echo "Paste the OAuth token (from 'claude setup-token') and press Enter:"
            read -r token
        else
            token=$(cat)
        fi
    fi

    token=$(echo "$token" | tr -d '[:space:]')
    if [[ -z "$token" ]]; then
        echo "Error: empty token" >&2
        return 1
    fi

    if [[ ! "$token" =~ ^sk-ant- ]]; then
        echo "Warning: token doesn't look like a Claude OAuth token (expected 'sk-ant-...' prefix)" >&2
    fi

    mkdir -p "$ACCOUNTS_SECRETS_DIR"
    umask 077
    printf '%s\n' "$token" > "${ACCOUNTS_SECRETS_DIR}/${name}.token"
    chmod 600 "${ACCOUNTS_SECRETS_DIR}/${name}.token"

    # Prompt for email/subscription if not provided (setup-token auth doesn't
    # expose email via `claude auth status`, so we track it ourselves).
    if [[ -z "$email" && -t 0 ]]; then
        read -r -p "Email address for this account (for display, optional): " email
    fi
    if [[ -z "$subscription" && -t 0 ]]; then
        read -r -p "Subscription tier (max/pro/team, optional): " subscription
    fi
    _account_save_meta "$name" "$email" "$subscription"

    echo "Added account '$name' (${#token} chars) to ${ACCOUNTS_SECRETS_DIR}"
    [[ -n "$email" ]] && echo "  Email:        $email"
    [[ -n "$subscription" ]] && echo "  Subscription: $subscription"
    echo "Run 'fleetmux account sync' to deploy to all sessions."
}

# Manually set email/subscription metadata for an account (without re-adding).
account_set_meta() {
    local name="$1" email="$2" subscription="${3:-}"
    if ! account_exists "$name"; then
        echo "Error: account '$name' not found" >&2
        return 1
    fi
    # Preserve existing subscription if not provided
    [[ -z "$subscription" ]] && subscription=$(_account_get_meta "$name" subscription)
    _account_save_meta "$name" "$email" "$subscription"
    echo "Updated account '$name': email=$email subscription=${subscription:-unknown}"
}

# Remove an account from the secrets dir + every deployed machine.
account_remove() {
    local name="$1"

    if ! account_exists "$name"; then
        echo "Error: account '$name' not found" >&2
        return 1
    fi

    # Check if any session still references this account
    local refs
    refs=$(jq -r --arg n "$name" '.[] | select(.account == $n) | .name' "$SESSIONS_FILE" 2>/dev/null)
    if [[ -n "$refs" ]]; then
        echo "Error: account '$name' is still referenced by session(s):" >&2
        # shellcheck disable=SC2001
        echo "$refs" | sed 's/^/  /' >&2
        echo "Unset them first: fleetmux account unset <session>" >&2
        return 1
    fi

    rm -f "${ACCOUNTS_SECRETS_DIR}/${name}.token"
    rm -f "${ACCOUNTS_LOCAL_DIR}/${name}.token"

    while IFS= read -r session; do
        local host
        host=$(registry_get_field "$session" "host")
        [[ -z "$host" ]] && continue
        ssh -n -o ConnectTimeout=5 "$host" "rm -f ~/.fleetmux-accounts/${name}.token" 2>/dev/null &
    done < <(jq -r '.[] | select(.type == "remote") | .name' "$SESSIONS_FILE" 2>/dev/null)
    wait

    echo "Removed account '$name' from secrets + all machines."
}

# Deploy the wrapper script + tokens to the local machine and every remote host.
account_sync() {
    local targets="${1:-all}"   # all | local | remote

    if [[ ! -x "$ACCOUNTS_WRAPPER_SRC" ]]; then
        echo "Error: wrapper source not found at $ACCOUNTS_WRAPPER_SRC" >&2
        return 1
    fi

    local tokens=()
    while IFS= read -r name; do
        [[ -n "$name" ]] && tokens+=("$name")
    done < <(account_list)

    # --- Local ---
    if [[ "$targets" == "all" || "$targets" == "local" ]]; then
        echo "→ Local"
        mkdir -p "$ACCOUNTS_LOCAL_DIR"
        chmod 700 "$ACCOUNTS_LOCAL_DIR"
        cp "$ACCOUNTS_WRAPPER_SRC" "$ACCOUNTS_WRAPPER_DEST"
        chmod +x "$ACCOUNTS_WRAPPER_DEST"
        if [[ -f "$USAGE_PARSER_SRC" ]]; then
            cp "$USAGE_PARSER_SRC" "$USAGE_PARSER_DEST"
            chmod +x "$USAGE_PARSER_DEST"
        fi
        for name in "${tokens[@]}"; do
            cp "${ACCOUNTS_SECRETS_DIR}/${name}.token" "${ACCOUNTS_LOCAL_DIR}/${name}.token"
            chmod 600 "${ACCOUNTS_LOCAL_DIR}/${name}.token"
        done
        echo "  wrapper: $ACCOUNTS_WRAPPER_DEST"
        echo "  parser:  $USAGE_PARSER_DEST"
        echo "  tokens:  ${#tokens[@]} (${tokens[*]:-none})"
    fi

    # --- Remote ---
    if [[ "$targets" == "all" || "$targets" == "remote" ]]; then
        local hosts=()
        while IFS= read -r host; do
            [[ -n "$host" ]] && hosts+=("$host")
        done < <(jq -r '[.[] | select(.type == "remote") | .host] | unique[]' "$SESSIONS_FILE" 2>/dev/null)

        for host in "${hosts[@]}"; do
            (
                echo "→ $host"
                ssh -o ConnectTimeout=8 -o BatchMode=yes "$host" 'mkdir -p ~/.fleetmux-accounts && chmod 700 ~/.fleetmux-accounts' 2>&1 |
                    sed "s/^/  /"
                scp -q -o ConnectTimeout=8 "$ACCOUNTS_WRAPPER_SRC" "${host}:.fleetmux-claude"
                ssh -o ConnectTimeout=8 "$host" 'chmod +x ~/.fleetmux-claude'
                if [[ -f "$USAGE_PARSER_SRC" ]]; then
                    scp -q -o ConnectTimeout=8 "$USAGE_PARSER_SRC" "${host}:.fleetmux-usage-parser"
                    ssh -o ConnectTimeout=8 "$host" 'chmod +x ~/.fleetmux-usage-parser'
                fi
                for name in "${tokens[@]}"; do
                    scp -q -o ConnectTimeout=8 "${ACCOUNTS_SECRETS_DIR}/${name}.token" "${host}:.fleetmux-accounts/${name}.token"
                    ssh -o ConnectTimeout=8 "$host" "chmod 600 ~/.fleetmux-accounts/${name}.token"
                done
                echo "  $host ok"
            ) &
        done
        wait
    fi

    echo "Sync complete."
}

# Show account info for a specific name (metadata only, never the token).
account_show() {
    local name="$1"
    if ! account_exists "$name"; then
        echo "Error: account '$name' not found" >&2
        return 1
    fi
    local file="${ACCOUNTS_SECRETS_DIR}/${name}.token"
    local len email subscription updated
    len=$(tr -d '[:space:]' < "$file" | wc -c | tr -d ' ')
    email=$(_account_get_meta "$name" email)
    subscription=$(_account_get_meta "$name" subscription)
    updated=$(_account_get_meta "$name" updated_at)
    echo "Name:         $name"
    # shellcheck disable=SC2016
    echo "Email:        ${email:-(not detected — run 'fleetmux account refresh $name')}"
    echo "Subscription: ${subscription:-unknown}"
    echo "File:         $file"
    echo "Size:         ${len} chars"
    echo "Modified:     $(date -r "$file" +'%Y-%m-%d %H:%M')"
    [[ -n "$updated" ]] && echo "Meta updated: $updated"
    echo
    echo "Sessions using this account:"
    local users
    users=$(jq -r --arg n "$name" '.[] | select(.account == $n) | "  \(.name) (\(.type))"' "$SESSIONS_FILE" 2>/dev/null)
    if [[ -z "$users" ]]; then
        echo "  (none)"
    else
        echo "$users"
    fi
}

# Rename an account (token file + metadata + update any session references).
account_rename() {
    local old="$1" new="$2"
    if ! account_exists "$old"; then
        echo "Error: account '$old' not found" >&2
        return 1
    fi
    if account_exists "$new"; then
        echo "Error: account '$new' already exists" >&2
        return 1
    fi
    mv "${ACCOUNTS_SECRETS_DIR}/${old}.token" "${ACCOUNTS_SECRETS_DIR}/${new}.token"

    # Rename metadata key
    _account_meta_init
    local tmp="${ACCOUNTS_META_FILE}.tmp"
    jq --arg old "$old" --arg new "$new" \
       '(.[$new] = .[$old]) | del(.[$old])' \
       "$ACCOUNTS_META_FILE" > "$tmp" && mv "$tmp" "$ACCOUNTS_META_FILE"

    # Update session references
    local tmp2="${SESSIONS_FILE}.tmp"
    jq --arg old "$old" --arg new "$new" \
       '[.[] | if .account == $old then .account = $new else . end]' \
       "$SESSIONS_FILE" > "$tmp2" && mv "$tmp2" "$SESSIONS_FILE"

    echo "Renamed account: '$old' → '$new'"
    echo "Run 'fleetmux account sync' to propagate to remote hosts."
}

# Assign an account to a session.
account_set_session() {
    local session="$1"
    local account_name="$2"

    if ! registry_session_exists "$session"; then
        echo "Error: session '$session' not found" >&2
        return 1
    fi
    if [[ -n "$account_name" ]] && ! account_exists "$account_name"; then
        echo "Error: account '$account_name' not found (fleetmux account list)" >&2
        return 1
    fi

    local tmp="${SESSIONS_FILE}.tmp"
    jq --arg s "$session" --arg a "$account_name" \
       '[.[] | if .name == $s then .account = $a else . end]' \
       "$SESSIONS_FILE" > "$tmp" && mv "$tmp" "$SESSIONS_FILE"

    if [[ -z "$account_name" ]]; then
        echo "Cleared account on session '$session' (will use default auth on next start)"
    else
        echo "Set session '$session' → account '$account_name'"
    fi
    echo "Restart session to apply: fleetmux stop $session && fleetmux start $session"
}

# Clear account from a session (use default auth).
account_unset_session() {
    account_set_session "$1" ""
}
