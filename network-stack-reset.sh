#!/usr/bin/env bash
# Exit immediately if any command fails
set -e

# Ensure script is run as root
if [ "$EUID" -ne 0 ]; then
  echo "[-] Please run this script with sudo or as root."
  exit 1
fi

echo "[+] Starting complete network stack and Docker reset..."

# 1. Stop Docker to release bridge interfaces and network namespaces
echo "[+] Stopping Docker service..."
systemctl stop docker.service || true
systemctl stop docker.socket || true

# 2. Flush and reset iptables / nftables
echo "[+] Flushing firewall rules (iptables)..."
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
    echo "[+] Flushing IPv6 firewall rules..."
    ip6tables -F
    ip6tables -t nat -F
    ip6tables -t mangle -F
    ip6tables -X
    ip6tables -t nat -X
    ip6tables -t mangle -X
    ip6tables -P INPUT ACCEPT
    ip6tables -P FORWARD ACCEPT
    ip6tables -P OUTPUT ACCEPT
fi

# Flush nftables if present
if command -v nft &> /dev/null; then
    echo "[+] Flushing nftables ruleset..."
    nft flush ruleset || true
fi

# 3. Clean up Docker network artifacts and custom bridges
echo "[+] Removing Docker network interfaces (docker0, br-*, veth*)..."
ip link set docker0 down 2>/dev/null || true
ip link delete docker0 type bridge 2>/dev/null || true

# Remove any remaining docker custom bridges or orphaned veth pairs
for intf in $(ip link show | grep -oE '(br-[0-9a-f]+|veth[0-9a-f]+)'); do
    echo "[+] Deleting interface: $intf"
    ip link set "$intf" down 2>/dev/null || true
    ip link delete "$intf" 2>/dev/null || true
done

# Clear Docker network state files if they exist
rm -rf /var/lib/docker/network/files/* 2>/dev/null || true

# 4. Reset core networking services (NetworkManager / systemd-networkd / networking)
echo "[+] Restarting network managers..."
if systemctl list-units --full -all | grep -q "NetworkManager.service"; then
    systemctl restart NetworkManager
elif systemctl list-units --full -all | grep -q "systemd-networkd.service"; then
    systemctl restart systemd-networkd
elif systemctl list-units --full -all | grep -q "networking.service"; then
    systemctl restart networking
fi

# 5. Restart Docker daemon to let it rebuild default networks cleanly
echo "[+] Restarting Docker service..."
systemctl start docker.service

echo "[✓] Network stack and Docker networks successfully reset to default state."
