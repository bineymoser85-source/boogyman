#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()   { echo -e "${GREEN}[✓]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[✗]${NC} $1"; exit 1; }

INSTALL_DIR="/opt/ovpn-bot"
SERVICE_NAME="ovpn-bot"

[[ $EUID -ne 0 ]] && error "Run as root."

echo -e "${CYAN}"
echo "  ╔═══════════════════════════════════════╗"
echo "  ║       OpenVPN SOCKS5 Bot              ║"
echo "  ║          Uninstaller                  ║"
echo "  ╚═══════════════════════════════════════╝"
echo -e "${NC}"

read -p "Are you sure you want to uninstall? [y/N]: " CONFIRM
[[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]] && echo "Aborted." && exit 0

# stop and disable service
if systemctl is-active --quiet "$SERVICE_NAME"; then
    systemctl stop "$SERVICE_NAME"
    log "Service stopped."
fi
if systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null; then
    systemctl disable "$SERVICE_NAME"
    log "Service disabled."
fi
rm -f "/etc/systemd/system/$SERVICE_NAME.service"
systemctl daemon-reload
log "Service removed."

# kill all openvpn and danted processes
pkill -9 openvpn 2>/dev/null && log "OpenVPN processes killed." || true
pkill -9 danted  2>/dev/null && log "Dante processes killed."   || true

# remove tun_XXXXX users
for user in $(grep "^tun_" /etc/passwd | cut -d: -f1); do
    userdel "$user" 2>/dev/null
    log "Removed user: $user"
done

# remove vpnuser
if id vpnuser &>/dev/null; then
    userdel vpnuser
    log "Removed vpnuser."
fi

# flush routing rules and tables
for table in $(ip rule show | grep -oP 'lookup vpn\S*' | awk '{print $2}'); do
    ip rule del table "$table" 2>/dev/null
    ip route flush table "$table" 2>/dev/null
    log "Flushed routing table: $table"
done

# remove vpn entries from rt_tables
sed -i '/vpn/d' /etc/iproute2/rt_tables
log "Cleaned rt_tables."

# remove dante configs and logs
rm -f /etc/danted_*.conf
rm -f /var/log/danted_*.log
log "Removed dante configs."

# remove install directory
rm -rf "$INSTALL_DIR"
log "Removed $INSTALL_DIR."

echo ""
log "Uninstall complete!"
