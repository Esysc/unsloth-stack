#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PID_DIR="${SCRIPT_DIR}/.pids"
LOG_DIR="${SCRIPT_DIR}/logs"
STUDIO_PID_FILE="${PID_DIR}/unsloth-studio.pid"
STUDIO_LOG="${LOG_DIR}/unsloth-studio.log"

mkdir -p "$PID_DIR" "$LOG_DIR"

# Load .env if present
if [[ -f "${SCRIPT_DIR}/.env" ]]; then
    set -a
    # shellcheck disable=SC1091
    source "${SCRIPT_DIR}/.env"
    set +a
fi

STUDIO_HOST="${STUDIO_HOST:-192.168.x.x}"
STUDIO_PORT="${STUDIO_PORT:-8000}"

# --- Helpers ---

ensure_unsloth_installed() {
    if command -v unsloth &>/dev/null; then
        return 0
    fi

    echo "    Unsloth CLI not found. Installing..."
    curl -fsSL https://unsloth.ai/install.sh | sh
    if ! command -v unsloth &>/dev/null; then
        echo "    ERROR: Installation failed. Install manually:"
        echo "           curl -fsSL https://unsloth.ai/install.sh | sh"
        return 1
    fi
    echo "    Unsloth installed successfully."
}

is_studio_running() {
    if [[ -f "$STUDIO_PID_FILE" ]]; then
        local pid
        pid=$(cat "$STUDIO_PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            return 0
        fi
    fi
    return 1
}

is_caddy_running() {
    docker ps --filter "name=caddy-proxy" --filter "status=running" -q 2>/dev/null | grep -q .
}

wait_for_port() {
    local host="$1" port="$2" timeout="${3:-10}" elapsed=0
    while ! (echo >/dev/tcp/"$host"/"$port") 2>/dev/null; do
        elapsed=$((elapsed + 1))
        if [[ $elapsed -ge $timeout ]]; then
            return 1
        fi
        sleep 1
    done
    return 0
}

# --- Commands ---

cmd_start() {
    echo "==> Starting Caddy proxy..."
    if is_caddy_running; then
        echo "    Caddy is already running."
    else
        docker compose -f "${SCRIPT_DIR}/docker-compose.yml" up -d
        echo "    Caddy started."
    fi

    echo "==> Starting Unsloth Studio on ${STUDIO_HOST}:${STUDIO_PORT}..."
    if is_studio_running; then
        echo "    Unsloth Studio is already running (PID $(cat "$STUDIO_PID_FILE"))."
        return 0
    fi

    ensure_unsloth_installed

    nohup unsloth studio -H "$STUDIO_HOST" -p "$STUDIO_PORT" \
        >>"$STUDIO_LOG" 2>&1 &
    local pid=$!
    echo "$pid" > "$STUDIO_PID_FILE"

    sleep 2
    if is_studio_running; then
        echo "    Unsloth Studio started (PID $pid)."
        echo "    Logs: $STUDIO_LOG"
    else
        echo "    ERROR: Unsloth Studio failed to start. Check $STUDIO_LOG"
        rm -f "$STUDIO_PID_FILE"
        return 1
    fi
}

cmd_stop() {
    echo "==> Stopping Unsloth Studio..."
    if is_studio_running; then
        local pid
        pid=$(cat "$STUDIO_PID_FILE")
        kill "$pid" 2>/dev/null || true
        # Wait up to 10s for graceful shutdown
        for _ in $(seq 1 10); do
            if ! kill -0 "$pid" 2>/dev/null; then
                break
            fi
            sleep 1
        done
        # Force kill if still alive
        if kill -0 "$pid" 2>/dev/null; then
            echo "    Force killing PID $pid..."
            kill -9 "$pid" 2>/dev/null || true
        fi
        rm -f "$STUDIO_PID_FILE"
        echo "    Unsloth Studio stopped."
    else
        echo "    Unsloth Studio is not running."
        rm -f "$STUDIO_PID_FILE"
    fi

    echo "==> Stopping Caddy proxy..."
    if is_caddy_running; then
        docker compose -f "${SCRIPT_DIR}/docker-compose.yml" down
        echo "    Caddy stopped."
    else
        echo "    Caddy is not running."
    fi
}

cmd_restart() {
    cmd_stop
    sleep 1
    cmd_start
}

cmd_status() {
    echo "==> Unsloth Stack Status"
    echo ""

    if is_caddy_running; then
        echo "  Caddy:       running"
    else
        echo "  Caddy:       stopped"
    fi

    if is_studio_running; then
        echo "  Studio:      running (PID $(cat "$STUDIO_PID_FILE"))"
    else
        echo "  Studio:      stopped"
    fi

    echo ""
    echo "  Endpoint:    http://${STUDIO_HOST}:${STUDIO_PORT}"
    echo "  Logs:        ${STUDIO_LOG}"
}

cmd_logs() {
    if [[ -f "$STUDIO_LOG" ]]; then
        tail -f "$STUDIO_LOG"
    else
        echo "No logs found at $STUDIO_LOG"
        return 1
    fi
}

# --- Main ---

usage() {
    echo "Usage: $0 {start|stop|restart|status|logs}"
    echo ""
    echo "  start    Start Caddy proxy and Unsloth Studio"
    echo "  stop     Stop both services gracefully"
    echo "  restart  Stop then start"
    echo "  status   Show running state of both services"
    echo "  logs     Tail Unsloth Studio logs"
    exit 1
}

case "${1:-}" in
    start)   cmd_start ;;
    stop)    cmd_stop ;;
    restart) cmd_restart ;;
    status)  cmd_status ;;
    logs)    cmd_logs ;;
    *)       usage ;;
esac
