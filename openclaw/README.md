# OpenClaw LXC

Run this on a Proxmox VE host.

```bash
bash -c "$(curl -fsSL https://github.com/pridhvi/proxmox-scripts/raw/refs/heads/main/openclaw/install.sh)"
```

The self-contained script creates an unprivileged Debian 13 AMD64 LXC and installs OpenClaw natively. It enables `nesting=1` for Debian 13 systemd user services. It does not enable `keyctl`.

Defaults:

- 8 CPU cores, 16 GiB RAM, 1 GiB swap, 32 GiB disk
- CIDR `/24`, gateway `10.10.10.1`, bridge `vmbr0`
- Storage `local-zfs`, template storage `local`
- Gateway port `18789`

The installer prompts for a static IPv4 address. The DNS prompt accepts one or two comma-separated IPv4 addresses. Leave it blank to inherit the Proxmox host's DNS settings.

Normal output shows one colored status line per section. Use `-v` to show the full command output:

```bash
bash -c "$(curl -fsSL https://github.com/pridhvi/proxmox-scripts/raw/refs/heads/main/openclaw/install.sh)" -- -v
```

The full output is also saved to `/var/log/openclaw-lxc-install-<CTID>.log`.

To inspect the commands without changing Proxmox:

```bash
OPENCLAW_IP=10.10.10.204 OPENCLAW_NAMESERVERS=10.10.10.2,10.10.10.3 bash -c "$(curl -fsSL https://github.com/pridhvi/proxmox-scripts/raw/refs/heads/main/openclaw/install.sh)" -- --dry-run --non-interactive
```

Non-interactive runs require `OPENCLAW_IP`. Other values can be overridden with environment variables such as `OPENCLAW_CTID`, `OPENCLAW_GATEWAY`, `OPENCLAW_STORAGE`, and `OPENCLAW_TEMPLATE_STORAGE`.

After installation, run onboarding as the `openclaw` user:

```bash
runuser -u openclaw -- env HOME=/home/openclaw openclaw onboard
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
