#!/bin/bash
# UnderstandTech Auto-Start Setup Script
# Run this script with sudo to configure automatic startup on boot
#
# Usage: sudo ./setup-autostart.sh [OPTIONS]
#   --install    Install and enable the service (default)
#   --mdns       Install only the mDNS aliases for the satellite apps
#   --uninstall  Remove the service
#   --status     Show service status

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Configuration
SERVICE_NAME="understandtech"
INSTALL_DIR="/home/understand-tech/utTest"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
MDNS_SERVICE_NAME="ut-mdns-alias"
MDNS_SERVICE_FILE="/etc/systemd/system/${MDNS_SERVICE_NAME}.service"
MDNS_HELPER="/usr/local/bin/ut-mdns-alias"

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()  { echo -e "${CYAN}[STEP]${NC} $1"; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root (use sudo)"
        exit 1
    fi
}

check_prerequisites() {
    log_step "Checking prerequisites..."
    
    # Check Docker
    if ! command -v docker &> /dev/null; then
        log_error "Docker is not installed"
        exit 1
    fi
    
    # Check Docker Compose
    if ! docker compose version &> /dev/null; then
        log_error "Docker Compose V2 is not available"
        exit 1
    fi
    
    # Check if install directory exists
    if [[ ! -d "$INSTALL_DIR" ]]; then
        log_error "Install directory not found: $INSTALL_DIR"
        echo ""
        echo "Please ensure your UnderstandTech files are in $INSTALL_DIR"
        echo "Required files:"
        echo "  - compose.yaml"
        echo "  - .env"
        echo "  - Caddyfile"
        exit 1
    fi
    
    # Check for compose.yaml
    if [[ ! -f "$INSTALL_DIR/compose.yaml" ]]; then
        log_error "compose.yaml not found in $INSTALL_DIR"
        exit 1
    fi
    
    log_info "Prerequisites satisfied"
}

install_mdns_alias() {
    log_step "Installing mDNS alias publisher..."

    cat > "$MDNS_HELPER" << 'HELPER_EOF'
#!/bin/sh
# Publish extra mDNS names for the satellite apps behind Caddy.
#
# Avahi answers for this machine's own host name only, so a name one level
# down like llms.understand.local needs a record of its own. Each name is
# published as an A record pointing at this host's primary address; the
# reverse (PTR) entry is skipped so the host's own reverse lookup is untouched.
#
# The address is re-derived on every start, so when it changes we exit and let
# systemd restart us — the restart is the republish.
set -eu

# Fixed routes of the appliance, not per-install configuration — edit this
# list to add a name, then: sudo systemctl restart ut-mdns-alias
ALIASES="llms.understand.local assistants.understand.local admin.understand.local"

primary_ip() {
    ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p'
}

ip_addr="$(primary_ip)"
if [ -z "$ip_addr" ]; then
    echo "no routable IPv4 address yet — will retry" >&2
    exit 1
fi

# --no-reverse keeps the host's own PTR record intact, but it is not in every
# avahi-utils build — only pass it when this one advertises it. --no-fail waits
# for the daemon instead of giving up when we start before it does.
no_reverse=""
if avahi-publish --help 2>&1 | grep -q -- "--no-reverse"; then
    no_reverse="-R"
fi

pids=""
for alias in $ALIASES; do
    echo "publishing $alias -> $ip_addr"
    avahi-publish -a -f $no_reverse "$alias" "$ip_addr" &
    pids="$pids $!"
done

terminate() {
    for pid in $pids; do kill "$pid" 2>/dev/null || true; done
    exit 0
}
trap terminate TERM INT

# Watch for an address change or a dead publisher; either way, exit and let
# systemd start us again.
while :; do
    sleep 30
    if [ "$(primary_ip)" != "$ip_addr" ]; then
        echo "primary address changed — republishing"
        terminate
    fi
    for pid in $pids; do
        if ! kill -0 "$pid" 2>/dev/null; then
            echo "publisher $pid exited — republishing" >&2
            terminate
        fi
    done
done
HELPER_EOF
    chmod +x "$MDNS_HELPER"
    log_info "Helper installed: $MDNS_HELPER"

    cat > "$MDNS_SERVICE_FILE" << 'SYSTEMD_EOF'
[Unit]
Description=UnderstandTech mDNS aliases for satellite apps
Documentation=https://github.com/understand-tech
After=avahi-daemon.service network-online.target
Wants=avahi-daemon.service network-online.target
# Never give up: a slow boot must not leave the aliases permanently unpublished.
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStart=/usr/local/bin/ut-mdns-alias
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SYSTEMD_EOF

    log_info "Service file created: $MDNS_SERVICE_FILE"

    systemctl daemon-reload
    systemctl enable "$MDNS_SERVICE_NAME" 2>/dev/null

    if ! command -v avahi-publish &> /dev/null; then
        log_warn "avahi-publish not found — the aliases cannot be published yet."
        log_warn "Install it, then start the service:"
        echo "  sudo apt-get install -y avahi-daemon avahi-utils"
        echo "  sudo systemctl start $MDNS_SERVICE_NAME"
        return 0
    fi

    systemctl restart "$MDNS_SERVICE_NAME"
    log_info "mDNS aliases published (edit $MDNS_HELPER to change them)"
    echo ""
    echo -e "${GREEN}Published names:${NC}"
    echo "  https://llms.understand.local"
    echo "  https://assistants.understand.local"
    echo "  https://admin.understand.local"
}

do_install() {
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  UnderstandTech Auto-Start Installation${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    check_root
    check_prerequisites
    
    log_step "Creating systemd service file..."
    
    cat > "$SERVICE_FILE" << 'SYSTEMD_EOF'
[Unit]
Description=UnderstandTech Docker Compose Stack
Documentation=https://github.com/understand-tech
After=docker.service network-online.target
Wants=network-online.target
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/home/understand-tech/utTest
EnvironmentFile=-/home/understand-tech/utTest/.env

# Wait for Docker to be fully ready
ExecStartPre=/bin/sleep 5

# Start the stack
ExecStart=/usr/bin/docker compose up -d --remove-orphans

# Stop the stack gracefully
ExecStop=/usr/bin/docker compose down

# Restart configuration
Restart=on-failure
RestartSec=30

# Timeouts (LLM service can take time to start)
TimeoutStartSec=600
TimeoutStopSec=120

[Install]
WantedBy=multi-user.target
SYSTEMD_EOF
    
    log_info "Service file created: $SERVICE_FILE"
    
    log_step "Reloading systemd daemon..."
    systemctl daemon-reload
    
    log_step "Enabling service for boot..."
    systemctl enable "$SERVICE_NAME"
    
    install_mdns_alias
    
    echo ""
    log_info "Installation complete!"
    echo ""
    echo -e "${GREEN}Service Commands:${NC}"
    echo "  Start now:     sudo systemctl start $SERVICE_NAME"
    echo "  Stop:          sudo systemctl stop $SERVICE_NAME"
    echo "  Restart:       sudo systemctl restart $SERVICE_NAME"
    echo "  Status:        sudo systemctl status $SERVICE_NAME"
    echo "  View logs:     sudo journalctl -u $SERVICE_NAME -f"
    echo ""
    echo -e "${GREEN}The stack will now start automatically on every boot.${NC}"
    echo ""
    
    read -p "Start the service now? (Y/n): " start_now
    if [[ ! "$start_now" =~ ^[Nn]$ ]]; then
        log_step "Starting UnderstandTech..."
        systemctl start "$SERVICE_NAME"
        echo ""
        systemctl status "$SERVICE_NAME" --no-pager
    fi
}

do_uninstall() {
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  UnderstandTech Auto-Start Removal${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    check_root
    
    if [[ ! -f "$SERVICE_FILE" && ! -f "$MDNS_SERVICE_FILE" ]]; then
        log_warn "Service file not found - nothing to remove"
        exit 0
    fi
    
    log_step "Stopping service..."
    systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    
    log_step "Disabling service..."
    systemctl disable "$SERVICE_NAME" 2>/dev/null || true
    
    log_step "Removing service file..."
    rm -f "$SERVICE_FILE"
    
    if [[ -f "$MDNS_SERVICE_FILE" ]]; then
        log_step "Removing mDNS alias service..."
        systemctl stop "$MDNS_SERVICE_NAME" 2>/dev/null || true
        systemctl disable "$MDNS_SERVICE_NAME" 2>/dev/null || true
        rm -f "$MDNS_SERVICE_FILE" "$MDNS_HELPER"
    fi
    
    log_step "Reloading systemd daemon..."
    systemctl daemon-reload
    
    echo ""
    log_info "Service removed successfully"
    echo ""
    echo "Note: Your containers may still be running."
    echo "To stop them: cd $INSTALL_DIR && docker compose down"
}

do_status() {
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  UnderstandTech Service Status${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    if [[ ! -f "$SERVICE_FILE" ]]; then
        log_warn "Service is not installed"
        echo ""
        echo "Run: sudo $0 --install"
        exit 0
    fi
    
    echo -e "${GREEN}Systemd Service:${NC}"
    systemctl status "$SERVICE_NAME" --no-pager 2>/dev/null || true
    echo ""
    
    if [[ -f "$MDNS_SERVICE_FILE" ]]; then
        echo -e "${GREEN}mDNS Alias Service:${NC}"
        systemctl status "$MDNS_SERVICE_NAME" --no-pager 2>/dev/null || true
        echo ""
    fi
    
    echo -e "${GREEN}Docker Containers:${NC}"
    if command -v docker &> /dev/null; then
        docker ps --filter "name=ut-" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || echo "  Unable to query Docker"
    fi
    echo ""
    
    echo -e "${GREEN}Recent Service Logs:${NC}"
    journalctl -u "$SERVICE_NAME" -n 10 --no-pager 2>/dev/null || echo "  No logs available"
}

show_help() {
    echo "UnderstandTech Auto-Start Setup"
    echo ""
    echo "Usage: sudo $0 [OPTION]"
    echo ""
    echo "Options:"
    echo "  --install    Install and enable auto-start (default)"
    echo "  --mdns       Install only the mDNS aliases for the satellite apps"
    echo "  --uninstall  Remove the auto-start service"
    echo "  --status     Show service and container status"
    echo "  --help       Show this help message"
    echo ""
}

# Main
case "${1:-}" in
    --install|-i|"")
        do_install
        ;;
    --mdns|-m)
        check_root
        install_mdns_alias
        ;;
    --uninstall|-u|--remove)
        do_uninstall
        ;;
    --status|-s)
        do_status
        ;;
    --help|-h)
        show_help
        ;;
    *)
        log_error "Unknown option: $1"
        show_help
        exit 1
        ;;
esac