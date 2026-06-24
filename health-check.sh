#!/bin/bash
# ClawTrade Health Check - Runs every minute via cron/systemd timer
# Checks if main tunnel is alive, restarts if dead

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TUNNEL_MANAGER="$SCRIPT_DIR/tunnel-manager.sh"
LOG_FILE="$HOME/.local/share/clawtrade/logs/health-check.log"
PID_DIR="$HOME/.local/share/clawtrade/pids"

mkdir -p "$(dirname "$LOG_FILE")"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Check if ClawTrade server is running on :8746
check_server() {
    if curl -s -o /dev/null -w "%{http_code}" http://localhost:8746 | grep -q "200\|301\|302"; then
        return 0
    fi
    return 1
}

# Check if at least one tunnel is alive
check_tunnels() {
    local alive_count=0
    
    for url_file in "$PID_DIR"/*.url; do
        [ -f "$url_file" ] || continue
        local url=$(cat "$url_file")
        local pid_file="${url_file%.url}.pid"
        
        [ -f "$pid_file" ] || continue
        local pid=$(cat "$pid_file")
        
        # Check if process is alive
        if ! kill -0 "$pid" 2>/dev/null; then
            rm -f "$pid_file" "$url_file"
            continue
        fi
        
        # Try to reach the tunnel
        if curl -s -o /dev/null --connect-timeout 5 --max-time 10 "$url" 2>/dev/null; then
            ((alive_count++))
        fi
    done
    
    if [ "$alive_count" -gt 0 ]; then
        return 0
    fi
    return 1
}

# Main health check
main() {
    log "Running health check..."
    
    # First check if ClawTrade server is up
    if ! check_server; then
        log "WARNING: ClawTrade server not responding on :8746"
        # Don't restart tunnels if server is down - that's a different problem
        exit 0
    fi
    
    # Check tunnels
    if check_tunnels; then
        log "OK: At least one tunnel is alive"
        exit 0
    fi
    
    # No tunnels alive - restart them
    log "ALERT: No tunnels alive! Restarting..."
    "$TUNNEL_MANAGER" restart
    
    # Wait and verify
    sleep 10
    if check_tunnels; then
        log "SUCCESS: Tunnels restarted successfully"
    else
        log "ERROR: Failed to restart tunnels"
    fi
}

main
