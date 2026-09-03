#!/usr/bin/env bash

set -euo pipefail
umask 077

readonly DFLY_HOST="127.0.0.1"
readonly DFLY_PORT="6379"
readonly AUDIT_DIR="/var/log/dragonfly-audit"

# Detect the actual Linux user who invoked this script through sudo
OS_USER="${SUDO_USER:-$(id -un)}"

if [[ "$OS_USER" == "root" ]]; then
    echo "This command must be executed from a personal Linux account using sudo." >&2
    exit 1
fi

SOURCE_IP="local"

if [[ -n "${SSH_CONNECTION:-}" ]]; then
    SOURCE_IP="${SSH_CONNECTION%% *}"
fi

read -rp "Dragonfly username: " DFLY_USER

if [[ -z "$DFLY_USER" ]]; then
    echo "Dragonfly username cannot be empty." >&2
    exit 1
fi

# Prevent manual use of engine accounts
case "$DFLY_USER" in
    engine|fraudengine|fraudbuster_engine)
        echo "Manual login with an engine account is not allowed." >&2
        exit 1
        ;;
esac

# Read password before terminal recording starts
read -rsp "Dragonfly password: " REDISCLI_AUTH
echo

if [[ -z "$REDISCLI_AUTH" ]]; then
    echo "Dragonfly password cannot be empty." >&2
    exit 1
fi

export REDISCLI_AUTH
export REDISCLI_HISTFILE=/dev/null

install -d -o root -g root -m 0700 "$AUDIT_DIR"

TIMESTAMP="$(date -u '+%Y%m%dT%H%M%SZ')"
SESSION_ID="${TIMESTAMP}_${OS_USER}_$$"

LOG_FILE="${AUDIT_DIR}/${SESSION_ID}.log"
TIMING_FILE="${AUDIT_DIR}/${SESSION_ID}.timing"

{
    echo "===== DRAGONFLY AUDIT SESSION ====="
    echo "session_id=${SESSION_ID}"
    echo "os_user=${OS_USER}"
    echo "dragonfly_user=${DFLY_USER}"
    echo "source_ip=${SOURCE_IP}"
    echo "tty=${SUDO_TTY:-unknown}"
    echo "started_at=$(date --iso-8601=seconds)"
    echo "==================================="
} > "$LOG_FILE"

cleanup() {
    local EXIT_CODE=$?

    unset REDISCLI_AUTH

    {
        echo
        echo "ended_at=$(date --iso-8601=seconds)"
        echo "exit_code=${EXIT_CODE}"
        echo "===== SESSION FINISHED ====="
    } >> "$LOG_FILE"

    chmod 600 "$LOG_FILE" "$TIMING_FILE" 2>/dev/null || true
    chown root:root "$LOG_FILE" "$TIMING_FILE" 2>/dev/null || true

    if command -v chattr >/dev/null 2>&1; then
        chattr +a "$LOG_FILE" "$TIMING_FILE" 2>/dev/null || true
    fi
}

trap cleanup EXIT

/usr/bin/script \
    --quiet \
    --flush \
    --append \
    --timing="$TIMING_FILE" \
    --command="/usr/bin/redis-cli -h ${DFLY_HOST} -p ${DFLY_PORT} --user ${DFLY_USER} --no-auth-warning" \
    "$LOG_FILE"