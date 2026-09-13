#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="${0##*/}"
ASSUME_YES=0
DOCKER_SERVICE_PRESENT=0
DOCKER_SOCKET_PRESENT=0
DOCKER_SERVICE_ACTIVE=0
DOCKER_SOCKET_ACTIVE=0
DOCKER_BRIDGES=("docker0")

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
  while read -r unit_name _; do
    if [ "$unit_name" = "$1" ]; then
      return 0
    fi
  done < <(systemctl list-unit-files --no-legend 2>/dev/null)

  return 1
}

collect_docker_bridges() {
  local network_id
  local bridge_name

  if ! command -v docker >/dev/null 2>&1; then
    return
  fi

  mapfile -t docker_network_ids < <(docker network ls --filter driver=bridge --quiet 2>/dev/null || true)
  for network_id in "${docker_network_ids[@]}"; do
    bridge_name="$(docker network inspect --format '{{index .Options "com.docker.network.bridge.name"}}' "$network_id" 2>/dev/null || true)"
    if [ -n "$bridge_name" ]; then
      DOCKER_BRIDGES+=("$bridge_name")
    fi
  done
}

is_known_docker_bridge() {
  local intf="$1"
  local bridge_name

  for bridge_name in "${DOCKER_BRIDGES[@]}"; do
    if [ "$bridge_name" = "$intf" ]; then
      return 0
    fi
  done

  return 1
}

wait_for_docker_network_rebuild() {
  local attempt

  for attempt in 1 2 3 4 5; do
    if ip link show docker0 >/dev/null 2>&1; then
      return 0
    fi

    if command -v docker >/dev/null 2>&1 && docker network inspect bridge >/dev/null 2>&1; then
      return 0
    fi

    sleep 1
  done

  warn "Timed out waiting for Docker to rebuild its default networking."
  return 1
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
  warn "This will flush firewall rules, remove Docker bridge interfaces, restart networking services, and restore Docker only if its service or socket was active before the reset."
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
  DOCKER_SERVICE_PRESENT=1
fi
if has_systemd_unit "docker.socket"; then
  DOCKER_SOCKET_PRESENT=1
fi

if [ "${DOCKER_SERVICE_PRESENT}" -eq 1 ] || [ "${DOCKER_SOCKET_PRESENT}" -eq 1 ]; then
  DOCKER_PRESENT=1
  if [ "${DOCKER_SERVICE_PRESENT}" -eq 1 ] && systemctl is-active --quiet docker.service; then
    DOCKER_SERVICE_ACTIVE=1
  fi
  if [ "${DOCKER_SOCKET_PRESENT}" -eq 1 ] && systemctl is-active --quiet docker.socket; then
    DOCKER_SOCKET_ACTIVE=1
  fi
  if [ "${DOCKER_SERVICE_ACTIVE}" -eq 1 ] || [ "${DOCKER_SOCKET_ACTIVE}" -eq 1 ]; then
    collect_docker_bridges
  fi
  if [ "${DOCKER_SERVICE_PRESENT}" -eq 1 ]; then
    log "Stopping Docker service..."
    systemctl stop docker.service || true
  fi
  if [ "${DOCKER_SOCKET_PRESENT}" -eq 1 ]; then
    log "Stopping Docker socket..."
    systemctl stop docker.socket || true
  fi
else
  warn "Docker service/socket units not found. Docker stop/start steps will be skipped."
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
    ip6tables -t mangle -F || true
    ip6tables -X
    ip6tables -t nat -X || true
    ip6tables -t mangle -X || true
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
mapfile -t docker_interfaces < <(
  ip -o link show | while IFS=: read -r _ raw_name _; do
    intf="${raw_name# }"
    intf="${intf%@*}"

    if is_known_docker_bridge "$intf" || [[ "$intf" =~ ^veth[[:xdigit:]]+$ ]]; then
      printf '%s\n' "$intf"
    fi
  done
)
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
    if [ "${DOCKER_SERVICE_PRESENT}" -eq 1 ] && [ "${DOCKER_SERVICE_ACTIVE}" -eq 1 ]; then
        log "Restarting Docker service..."
        systemctl start docker.service
    elif [ "${DOCKER_SERVICE_PRESENT}" -eq 1 ] && [ "${DOCKER_SOCKET_ACTIVE}" -eq 1 ]; then
        log "Temporarily starting Docker service to rebuild default networking..."
        systemctl start docker.service
    fi
    if [ "${DOCKER_SOCKET_PRESENT}" -eq 1 ] && [ "${DOCKER_SOCKET_ACTIVE}" -eq 1 ]; then
        log "Restoring Docker socket..."
        systemctl start docker.socket
    fi
    if [ "${DOCKER_SERVICE_PRESENT}" -eq 1 ] && [ "${DOCKER_SERVICE_ACTIVE}" -eq 0 ] && [ "${DOCKER_SOCKET_ACTIVE}" -eq 1 ]; then
        if wait_for_docker_network_rebuild; then
            log "Returning Docker to socket activation mode..."
            systemctl stop docker.service || true
        else
            warn "Leaving Docker service running because networking rebuild could not be confirmed."
        fi
    fi
fi

log "Network stack and Docker networks successfully reset to default state."
