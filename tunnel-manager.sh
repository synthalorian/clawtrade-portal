#!/bin/bash
# ClawTrade Tunnel Manager - Spawns and manages multiple tunnel services
# Usage: ./tunnel-manager.sh [start|stop|status|restart]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PID_DIR="$HOME/.local/share/clawtrade/pids"
LOG_DIR="$HOME/.local/share/clawtrade/logs"
CONFIG_FILE="$HOME/.config/clawtrade/tunnels.conf"

# Ensure directories exist
mkdir -p "$PID_DIR" "$LOG_DIR" "$(dirname "$CONFIG_FILE")"

# Default configuration
cat > "$CONFIG_FILE" << 'EOF' 2>/dev/null || true
# ClawTrade Tunnel Configuration
# Format: TYPE:PORT:SUBDOMAIN:PRIORITY

# LocalTunnel instances (free, persistent with systemd)
localtunnel:8746:clawtrade84:1
localtunnel:8746:clawtrade-backup:2

# Cloudflare Quick Tunnel (free, random URL each time)
cloudflare:8746::3

# ngrok (free, requires auth token for static domains)
ngrok:8746::4
EOF

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log() {
    echo -e "${CYAN}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

success() {
    echo -e "${GREEN}[OK]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

# Check if a command exists
check_command() {
    if ! command -v "$1" &> /dev/null; then
        return 1
    fi
    return 0
}

# Install missing tools
install_tools() {
    log "Checking required tools..."
    
    # Check for localtunnel
    if ! check_command lt && ! check_command localtunnel; then
        log "Installing localtunnel..."
        if check_command npm; then
            npm install -g localtunnel
        else
            error "npm not found. Cannot install localtunnel."
            exit 1
        fi
    fi
    
    # Check for cloudflared
    if ! check_command cloudflared; then
        log "Installing cloudflared..."
        if check_command pacman; then
            sudo pacman -S --noconfirm cloudflared 2>/dev/null || {
                # Fallback to manual install
                curl -L --output /tmp/cloudflared https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
                chmod +x /tmp/cloudflared
                sudo mv /tmp/cloudflared /usr/local/bin/
            }
        elif check_command apt; then
            wget -q https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb -O /tmp/cloudflared.deb
            sudo dpkg -i /tmp/cloudflared.deb
        else
            curl -L --output /tmp/cloudflared https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
            chmod +x /tmp/cloudflared
            sudo mv /tmp/cloudflared /usr/local/bin/
        fi
    fi
    
    # Check for ngrok
    if ! check_command ngrok; then
        log "Installing ngrok..."
        if check_command pacman; then
            sudo pacman -S --noconfirm ngrok 2>/dev/null || {
                warning "ngrok not in repos. Download from https://ngrok.com/download"
            }
        else
            warning "Please install ngrok manually from https://ngrok.com/download"
        fi
    fi
    
    success "Tool check complete"
}

# Start a localtunnel instance
start_localtunnel() {
    local port=$1
    local subdomain=$2
    local pid_file="$PID_DIR/lt_${subdomain}.pid"
    local log_file="$LOG_DIR/lt_${subdomain}.log"
    
    if [ -f "$pid_file" ] && kill -0 "$(cat "$pid_file")" 2>/dev/null; then
        warning "LocalTunnel $subdomain already running (PID: $(cat "$pid_file"))"
        return 0
    fi
    
    log "Starting LocalTunnel: $subdomain -> :$port"
    
    nohup lt --port "$port" --subdomain "$subdomain" > "$log_file" 2>&1 &
    local pid=$!
    echo $pid > "$pid_file"
    
    # Wait for tunnel to establish
    sleep 3
    
    if kill -0 "$pid" 2>/dev/null; then
        success "LocalTunnel $subdomain started (PID: $pid)"
        # Extract URL from log
        local url=$(grep -o 'https://[^[:space:]]*' "$log_file" | head -1)
        if [ -n "$url" ]; then
            log "URL: $url"
            echo "$url" > "$PID_DIR/lt_${subdomain}.url"
        fi
    else
        error "LocalTunnel $subdomain failed to start"
        rm -f "$pid_file"
        return 1
    fi
}

# Start a cloudflare tunnel
start_cloudflare() {
    local port=$1
    local pid_file="$PID_DIR/cf.pid"
    local log_file="$LOG_DIR/cf.log"
    
    if [ -f "$pid_file" ] && kill -0 "$(cat "$pid_file")" 2>/dev/null; then
        warning "Cloudflare tunnel already running (PID: $(cat "$pid_file"))"
        return 0
    fi
    
    log "Starting Cloudflare Quick Tunnel -> :$port"
    
    nohup cloudflared tunnel --url "http://localhost:$port" > "$log_file" 2>&1 &
    local pid=$!
    echo $pid > "$pid_file"
    
    # Wait for tunnel to establish
    sleep 5
    
    if kill -0 "$pid" 2>/dev/null; then
        success "Cloudflare tunnel started (PID: $pid)"
        # Extract URL from log
        local url=$(grep -o 'https://[a-zA-Z0-9-]*\.trycloudflare\.com' "$log_file" | head -1)
        if [ -n "$url" ]; then
            log "URL: $url"
            echo "$url" > "$PID_DIR/cf.url"
        fi
    else
        error "Cloudflare tunnel failed to start"
        rm -f "$pid_file"
        return 1
    fi
}

# Start an ngrok tunnel
start_ngrok() {
    local port=$1
    local pid_file="$PID_DIR/ngrok.pid"
    local log_file="$LOG_DIR/ngrok.log"
    
    if [ -f "$pid_file" ] && kill -0 "$(cat "$pid_file")" 2>/dev/null; then
        warning "ngrok already running (PID: $(cat "$pid_file"))"
        return 0
    fi
    
    if ! check_command ngrok; then
        warning "ngrok not installed, skipping"
        return 0
    fi
    
    log "Starting ngrok tunnel -> :$port"
    
    nohup ngrok http "$port" --log=stdout > "$log_file" 2>&1 &
    local pid=$!
    echo $pid > "$pid_file"
    
    # Wait for tunnel to establish - ngrok needs more time
    sleep 8
    
    if kill -0 "$pid" 2>/dev/null; then
        success "ngrok started (PID: $pid)"
        # Try to get URL from ngrok API
        sleep 3
        local url=$(curl -s http://localhost:4040/api/tunnels 2>/dev/null | grep -o 'https://[^"]*ngrok-free\.dev' | head -1)
        if [ -n "$url" ]; then
            log "URL: $url"
            echo "$url" > "$PID_DIR/ngrok.url"
        fi
    else
        error "ngrok failed to start"
        rm -f "$pid_file"
        return 1
    fi
}

# Stop all tunnels
stop_all() {
    log "Stopping all tunnels..."
    
    for pid_file in "$PID_DIR"/*.pid; do
        [ -f "$pid_file" ] || continue
        local pid=$(cat "$pid_file")
        local name=$(basename "$pid_file" .pid)
        
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
            success "Stopped $name (PID: $pid)"
        fi
        
        rm -f "$pid_file"
    done
    
    # Also kill any lingering processes
    pkill -f "lt --port 8746" 2>/dev/null || true
    pkill -f "cloudflared tunnel" 2>/dev/null || true
    pkill -f "ngrok http 8746" 2>/dev/null || true
    
    success "All tunnels stopped"
}

# Update tunnel URLs JSON and push to git
update_tunnel_json() {
    local json_file="$SCRIPT_DIR/tunnels.json"
    local timestamp=$(date -Iseconds)
    
    # Build JSON from current tunnel status
    cat > "$json_file" << EOF
{
  "updated": "$timestamp",
  "tunnels": [
EOF

    local first=true
    for url_file in "$PID_DIR"/*.url; do
        [ -f "$url_file" ] || continue
        local name=$(basename "$url_file" .url)
        local url=$(cat "$url_file")
        local pid_file="${url_file%.url}.pid"
        local type="unknown"
        local priority=99
        local status="offline"
        
        # Determine type and priority from name
        case "$name" in
            lt_clawtrade84)
                type="localtunnel"
                priority=1
                ;;
            lt_clawtrade-backup)
                type="localtunnel"
                priority=2
                ;;
            cf)
                type="cloudflare"
                priority=3
                ;;
            ngrok)
                type="ngrok"
                priority=4
                ;;
        esac
        
        # Check if process is alive
        if [ -f "$pid_file" ]; then
            local pid=$(cat "$pid_file")
            if kill -0 "$pid" 2>/dev/null; then
                status="online"
            fi
        fi
        
        # Add comma if not first
        if [ "$first" = true ]; then
            first=false
        else
            echo "," >> "$json_file"
        fi
        
        cat >> "$json_file" << EOF
    {
      "name": "$name",
      "url": "$url",
      "type": "$type",
      "priority": $priority,
      "status": "$status"
    }
EOF
    done

    cat >> "$json_file" << EOF

  ],
  "dashboard_url": "http://localhost:8746",
  "version": "1.0.0"
}
EOF

    # Push to git if configured
    if [ -d "$SCRIPT_DIR/.git" ]; then
        cd "$SCRIPT_DIR" || return
        git add tunnels.json >/dev/null 2>&1
        git commit -m "Auto-update tunnel URLs: $timestamp" >/dev/null 2>&1 || true
        
        # Push to both main and gh-pages
        git push origin main >/dev/null 2>&1 || true
        
        # Update gh-pages branch
        git checkout gh-pages >/dev/null 2>&1 || true
        git merge main --no-edit >/dev/null 2>&1 || true
        git push origin gh-pages >/dev/null 2>&1 || true
        git checkout main >/dev/null 2>&1 || true
        
        log "Updated tunnel URLs and pushed to GitHub Pages"
    fi
}

# Show status of all tunnels
show_status() {
    log "Tunnel Status:"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    local any_running=false
    
    for pid_file in "$PID_DIR"/*.pid; do
        [ -f "$pid_file" ] || continue
        local pid=$(cat "$pid_file")
        local name=$(basename "$pid_file" .pid)
        local url_file="${pid_file%.pid}.url"
        local url=""
        
        [ -f "$url_file" ] && url=$(cat "$url_file")
        
        if kill -0 "$pid" 2>/dev/null; then
            any_running=true
            success "$name: RUNNING"
            [ -n "$url" ] && echo "  URL: $url"
            echo "  PID: $pid"
        else
            error "$name: STOPPED"
            rm -f "$pid_file" "$url_file"
        fi
        echo ""
    done
    
    if [ "$any_running" = false ]; then
        warning "No tunnels are currently running"
    fi
    
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# Start all tunnels from config
start_all() {
    log "Starting all configured tunnels..."
    
    # Read config and start each tunnel
    while IFS=':' read -r type port subdomain priority; do
        [ -z "$type" ] && continue
        [[ "$type" == \#* ]] && continue
        
        case "$type" in
            localtunnel)
                start_localtunnel "$port" "$subdomain"
                ;;
            cloudflare)
                start_cloudflare "$port"
                ;;
            ngrok)
                start_ngrok "$port"
                ;;
            *)
                warning "Unknown tunnel type: $type"
                ;;
        esac
    done < "$CONFIG_FILE"
    
    success "All tunnels started!"
    update_tunnel_json
    show_status
}

# Health check - restart dead tunnels
health_check() {
    local restart_needed=false
    
    for pid_file in "$PID_DIR"/*.pid; do
        [ -f "$pid_file" ] || continue
        local pid=$(cat "$pid_file")
        local name=$(basename "$pid_file" .pid)
        
        if ! kill -0 "$pid" 2>/dev/null; then
            warning "$name is dead, needs restart"
            restart_needed=true
            rm -f "$pid_file"
        fi
    done
    
    if [ "$restart_needed" = true ]; then
        log "Restarting dead tunnels..."
        start_all
    fi
}

# Main command handler
case "${1:-status}" in
    start)
        install_tools
        start_all
        ;;
    stop)
        stop_all
        ;;
    restart)
        stop_all
        sleep 2
        install_tools
        start_all
        ;;
    status)
        show_status
        ;;
    health)
        health_check
        ;;
    *)
        echo "Usage: $0 [start|stop|restart|status|health]"
        echo ""
        echo "Commands:"
        echo "  start   - Start all configured tunnels"
        echo "  stop    - Stop all tunnels"
        echo "  restart - Restart all tunnels"
        echo "  status  - Show tunnel status"
        echo "  health  - Check and restart dead tunnels"
        exit 1
        ;;
esac
