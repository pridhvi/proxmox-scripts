# OpenClaw LXC

Run this on a Proxmox VE host.

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/pridhvi/proxmox-scripts/main/openclaw/install.sh)"
```

The self-contained script creates an unprivileged Debian 13 LXC and installs OpenClaw natively.

Defaults:

- 8 CPU cores, 16 GiB RAM, 1 GiB swap, 32 GiB disk
- CIDR `/24`, gateway `10.10.10.1`, bridge `vmbr0`
- Storage `local-lvm`, template storage `local`
- Gateway port `18789`

The installer requires a static IPv4 address and prompts for it. To inspect its actions without changing Proxmox:

```bash
OPENCLAW_IP=10.0.0.67 bash -c "$(curl -fsSL https://raw.githubusercontent.com/pridhvi/proxmox-scripts/main/openclaw/install.sh)" -- --dry-run --non-interactive
```

Non-interactive runs require `OPENCLAW_IP`. Other values can be overridden with environment variables such as `OPENCLAW_CTID`, `OPENCLAW_GATEWAY`, `OPENCLAW_STORAGE`, and `OPENCLAW_TEMPLATE_STORAGE`.

After installation, finish OpenClaw setup as 'openclaw' user:

```bash
openclaw onboard
```

Useful commands inside the container:

```bash
openclaw update
apt update && apt full-upgrade
openclaw gateway status --deep
openclaw browser --json status
journalctl _UID=$(id -u openclaw) -f
```

`update` updates OpenClaw and runs its health checks. Normal Debian package update tools work, but the Proxmox Community Scripts bulk app updater cannot manage this custom installation because it has no matching app script.

The generated gateway token is stored at `/home/openclaw/.openclaw/.env` with mode `0600`. Reverse proxies, Tailscale, model servers, backups, and other agents are outside this script's scope.
