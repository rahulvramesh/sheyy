#!/usr/bin/env bash
#
# SheyyBot Doctor - Health check and auto-recovery
# Runs periodically via systemd timer. Monitors the bot process,
# detects failures, restarts if needed, and notifies the admin.
#

set -euo pipefail

SERVICE_NAME="sheyybot"
WORK_DIR="/var/lib/sheyybot"
MAX_MEMORY_KB=204800  # 200MB
MAX_CONSECUTIVE_ERRORS=5
DOCTOR_LOG="/var/log/sheyybot-doctor.log"

# ── Load config ───────────────────────────────────────────────────

load_config() {
    if [ ! -f "$WORK_DIR/auth.json" ]; then
        echo "ERROR: auth.json not found" >> "$DOCTOR_LOG"
        exit 1
    fi

    BOT_TOKEN=$(python3 -c "import json; print(json.load(open('$WORK_DIR/auth.json'))['telegram_bot_token'])" 2>/dev/null || true)

    if [ -f "$WORK_DIR/allowed_users.json" ]; then
        ADMIN_CHAT_ID=$(python3 -c "import json; users=json.load(open('$WORK_DIR/allowed_users.json')); print(users[0] if users else '')" 2>/dev/null || true)
    fi

    if [ -z "${BOT_TOKEN:-}" ] || [ -z "${ADMIN_CHAT_ID:-}" ]; then
        echo "$(date -Iseconds) ERROR: Could not load bot token or admin chat ID" >> "$DOCTOR_LOG"
        exit 1
    fi
}

# ── Telegram notification ─────────────────────────────────────────

notify() {
    local message="$1"
    local formatted="[Doctor] $message"
    curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
        -d chat_id="${ADMIN_CHAT_ID}" \
        -d text="${formatted}" \
        -d parse_mode="HTML" \
        --max-time 10 > /dev/null 2>&1 || true
}

# ── Health checks ─────────────────────────────────────────────────

check_process_alive() {
    if ! systemctl is-active --quiet "$SERVICE_NAME"; then
        echo "DEAD"
        return
    fi
    echo "OK"
}

check_memory() {
    local pid
    pid=$(systemctl show "$SERVICE_NAME" --property=MainPID --value 2>/dev/null)
    if [ -z "$pid" ] || [ "$pid" = "0" ]; then
        echo "NO_PID"
        return
    fi

    local rss_kb
    rss_kb=$(ps -p "$pid" -o rss= 2>/dev/null | tr -d ' ')
    if [ -z "$rss_kb" ]; then
        echo "NO_PID"
        return
    fi

    if [ "$rss_kb" -gt "$MAX_MEMORY_KB" ]; then
        echo "HIGH:${rss_kb}"
        return
    fi
    echo "OK:${rss_kb}"
}

check_error_loop() {
    # Count HEALTH_CRITICAL messages in the last 3 minutes
    local count
    count=$(journalctl -u "$SERVICE_NAME" --since "3 minutes ago" --no-pager 2>/dev/null \
        | grep -c "HEALTH_CRITICAL" || true)
    count="${count:-0}"
    count=$(echo "$count" | tr -d '[:space:]')

    if [ "$count" -ge "$MAX_CONSECUTIVE_ERRORS" ]; then
        echo "CRITICAL:${count}"
        return
    fi
    echo "OK:${count}"
}

check_telegram_api() {
    local response
    response=$(curl -s --max-time 10 "https://api.telegram.org/bot${BOT_TOKEN}/getMe" 2>/dev/null)
    if echo "$response" | python3 -c "import sys,json; d=json.load(sys.stdin); assert d['ok']" 2>/dev/null; then
        echo "OK"
    else
        echo "UNREACHABLE"
    fi
}

# ── Recovery actions ──────────────────────────────────────────────

restart_service() {
    local reason="$1"
    echo "$(date -Iseconds) RESTART: $reason" >> "$DOCTOR_LOG"
    systemctl restart "$SERVICE_NAME" 2>/dev/null
    sleep 3

    if systemctl is-active --quiet "$SERVICE_NAME"; then
        notify "Restarted bot: ${reason}. Service is back up."
        echo "$(date -Iseconds) RESTART_OK" >> "$DOCTOR_LOG"
    else
        notify "ALERT: Restart failed! Reason: ${reason}. Manual intervention needed."
        echo "$(date -Iseconds) RESTART_FAILED" >> "$DOCTOR_LOG"
    fi
}

# ── Main doctor routine ──────────────────────────────────────────

main() {
    load_config

    local needs_restart=""
    local reason=""

    # Check 1: Is the process alive?
    local alive
    alive=$(check_process_alive)
    if [ "$alive" = "DEAD" ]; then
        needs_restart="yes"
        reason="Process not running"
    fi

    # Check 2: Memory usage
    if [ -z "$needs_restart" ]; then
        local mem
        mem=$(check_memory)
        case "$mem" in
            HIGH:*)
                local mem_kb="${mem#HIGH:}"
                local mem_mb=$((mem_kb / 1024))
                needs_restart="yes"
                reason="Memory too high: ${mem_mb}MB (limit: $((MAX_MEMORY_KB / 1024))MB)"
                ;;
        esac
    fi

    # Check 3: Error loop detection
    if [ -z "$needs_restart" ]; then
        local errors
        errors=$(check_error_loop)
        case "$errors" in
            CRITICAL:*)
                needs_restart="yes"
                reason="Poll error loop detected (${errors#CRITICAL:} HEALTH_CRITICAL in 3min)"
                ;;
        esac
    fi

    # Check 4: Telegram API reachable (informational only)
    local tg_status
    tg_status=$(check_telegram_api)
    if [ "$tg_status" = "UNREACHABLE" ]; then
        echo "$(date -Iseconds) WARN: Telegram API unreachable" >> "$DOCTOR_LOG"
        # Don't restart for this — it's not the bot's fault
    fi

    # Act
    if [ -n "$needs_restart" ]; then
        restart_service "$reason"
    else
        # Silent success — only log every 30 minutes to avoid noise
        local minute
        minute=$(date +%M)
        if [ "$((minute % 30))" -lt 2 ]; then
            local mem_info
            mem_info=$(check_memory)
            echo "$(date -Iseconds) HEALTHY: mem=${mem_info#OK:}KB" >> "$DOCTOR_LOG"
        fi
    fi
}

main "$@"
