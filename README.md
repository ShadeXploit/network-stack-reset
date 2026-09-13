# Network Stack Reset

`network-stack-reset.sh` is a Linux recovery script for resetting Docker-created networking artifacts and restoring the local network stack to a clean baseline.

## What it does

The script:

- stops Docker so bridge interfaces and namespaces can be released
- flushes IPv4 firewall rules with `iptables`
- flushes IPv6 firewall rules when `ip6tables` is available
- flushes the `nftables` ruleset when `nft` is available
- removes `docker0`, Docker bridge interfaces discovered from Docker metadata, and Docker-style `veth<hex>` interfaces
- clears Docker network state files
- restarts the detected network manager
- restores Docker service and socket activation only when they were active before the reset

## Important warning

This script is destructive by design.

Running it will remove active firewall rules and reset Docker networking state on the current machine. Only use it on systems where you understand the impact, especially remote hosts, production machines, or systems that rely on custom firewall policies.

## Requirements

- Linux system with `systemd`
- Bash 4+ (`mapfile` is used)
- root or `sudo` access
- `ip`
- `iptables`
- `grep`
- `rm`
- `systemctl`
- Docker installed as a `systemd` service or socket if you want it restored automatically when it was already active

## Usage

Make the script executable if needed:

```bash
chmod +x ./network-stack-reset.sh
```

Show help:

```bash
sudo ./network-stack-reset.sh --help
```

Run with confirmation:

```bash
sudo ./network-stack-reset.sh
```

Run without confirmation:

```bash
sudo ./network-stack-reset.sh --yes
```

## When to use it

Use this script when Docker networking is broken and you need to force a clean rebuild of the local bridge and firewall state, for example:

- containers cannot reach the network
- orphaned `br-*` or `veth*` interfaces remain after Docker changes
- Docker bridge rules are corrupted
- firewall state needs to be reset before rebuilding Docker networking

## Expected result

After a successful run:

- stale Docker bridge interfaces should be removed
- firewall chains should be reset to `ACCEPT`
- if Docker was active before the reset, it should recreate its default networking when its service or socket is restored

## Troubleshooting

- If the script says a required command is missing, install that package first and run again.
- If Docker is not installed as a `systemd` service, the Docker restart steps are skipped.
- If you are connected over SSH and depend on custom firewall rules, re-apply them after running the script.

## File overview

- `./network-stack-reset.sh` — main reset script
