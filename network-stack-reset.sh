#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
ASSUME_YES=0

usage() {
  cat <<EOF
Usage: sudo ./${SCRIPT_NAME} [--yes]

Safely resets Docker networking artifacts and the local Linux network stack.

Options:
  -y, --yes   Skip the confirmation prompt
  -h, --help  Show this help message
EOF
}

log() {
  echo "[+] $1"
}

warn() {
  echo "[!] $1"
}

die() {
  echo "[-] $1" >&2
  exit 1
}

has_systemd_unit() {
  systemctl list-unit-files --type=service --no-legend 2>/dev/null | grep -q "^$1"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    -y|--yes)
      ASSUME_YES=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
  shift
done

if [ "${EUID}" -ne 0 ]; then
  die "Please run this script with sudo or as root."
fi

for cmd in ip iptables systemctl grep rm; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    die "Required command not found: $cmd"
  fi
done

if [ "${ASSUME_YES}" -ne 1 ]; then
  warn "This will flush firewall rules, remove Docker bridge interfaces, restart networking services, and restart Docker if it is installed."
  read -r -p "Continue? [y/N] " reply
  case "$reply" in
    [yY]|[yY][eE][sS])
      ;;
    *)
      echo "Aborted."
      exit 0
      ;;
  esac
fi

log "Starting complete network stack and Docker reset..."

DOCKER_PRESENT=0
if has_systemd_unit "docker.service"; then
  DOCKER_PRESENT=1
  log "Stopping Docker service..."
  systemctl stop docker.service || true
  systemctl stop docker.socket || true
else
  warn "Docker service not found. Docker stop/start steps will be skipped."
fi

# 2. Flush and reset iptables / nftables
log "Flushing firewall rules (iptables)..."
iptables -F
iptables -t nat -F
iptables -t mangle -F
iptables -X
iptables -t nat -X
iptables -t mangle -X

# Set default policies back to ACCEPT
iptables -P INPUT ACCEPT
iptables -P FORWARD ACCEPT
iptables -P OUTPUT ACCEPT

# Repeat for IPv6 if ip6tables is available
if command -v ip6tables &> /dev/null; then
    log "Flushing IPv6 firewall rules..."
    ip6tables -F
    ip6tables -t nat -F || true
    ip6tables -t mangle -F
    ip6tables -X
    ip6tables -t nat -X || true
    ip6tables -t mangle -X
    ip6tables -P INPUT ACCEPT
    ip6tables -P FORWARD ACCEPT
    ip6tables -P OUTPUT ACCEPT
fi

# Flush nftables if present
if command -v nft &> /dev/null; then
    log "Flushing nftables ruleset..."
    nft flush ruleset || true
fi

# 3. Clean up Docker network artifacts and custom bridges
log "Removing Docker network interfaces (docker0, br-*, veth*)..."
ip link set docker0 down 2>/dev/null || true
ip link delete docker0 type bridge 2>/dev/null || true

# Remove any remaining docker custom bridges or orphaned veth pairs
mapfile -t docker_interfaces < <(ip -o link show | grep -oE '(br-[0-9a-f]+|veth[0-9a-f]+)' || true)
for intf in "${docker_interfaces[@]}"; do
    log "Deleting interface: $intf"
    ip link set "$intf" down 2>/dev/null || true
    ip link delete "$intf" 2>/dev/null || true
done

# Clear Docker network state files if they exist
rm -rf /var/lib/docker/network/files/* 2>/dev/null || true

# 4. Reset core networking services (NetworkManager / systemd-networkd / networking)
log "Restarting network managers..."
if systemctl list-units --full -all | grep -q "NetworkManager.service"; then
    systemctl restart NetworkManager
elif systemctl list-units --full -all | grep -q "systemd-networkd.service"; then
    systemctl restart systemd-networkd
elif systemctl list-units --full -all | grep -q "networking.service"; then
    systemctl restart networking
fi

# 5. Restart Docker daemon to let it rebuild default networks cleanly
if [ "${DOCKER_PRESENT}" -eq 1 ]; then
    log "Restarting Docker service..."
    systemctl start docker.service
fi

echo "[✓] Network stack and Docker networks successfully reset to default state."
