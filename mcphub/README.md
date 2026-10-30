# MCPHub LXC

Run this on a Proxmox VE host:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/pridhvi/proxmox-scripts/main/mcphub/install.sh)"
```

The script creates an unprivileged Debian 13 AMD64 LXC and runs [samanhappy/MCPHub](https://github.com/samanhappy/mcphub) through Docker Compose. It installs the latest stable release using its versioned Docker tag (without the release tag's leading `v`). The standard image includes Node.js, Python, and uv/uvx for running MCP servers. No separate database is required.

## Defaults

- 6 CPU cores, 8 GiB RAM, 1 GiB swap, 32 GiB disk
- CIDR `/24`, gateway `10.10.10.1`, bridge `vmbr0`
- Storage `local-zfs`, template storage `local`
- MCPHub port `3000`

The installer prompts for a static IPv4 address. The DNS prompt accepts one or two IPv4 addresses separated by a comma. Leave it blank to inherit the Proxmox host's DNS settings.

Use `-v` to show full command output:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/pridhvi/proxmox-scripts/main/mcphub/install.sh)" -- -v
```

To inspect the commands without changing Proxmox:

```bash
MCPHUB_IP=10.10.10.60 MCPHUB_NAMESERVERS=10.10.10.2,10.10.10.3 bash -c "$(curl -fsSL https://raw.githubusercontent.com/pridhvi/proxmox-scripts/main/mcphub/install.sh)" -- --dry-run --non-interactive
```

Non-interactive runs require `MCPHUB_IP`. Optional settings are `MCPHUB_CTID`, `MCPHUB_HOSTNAME`, `MCPHUB_CORES`, `MCPHUB_MEMORY` (MiB), `MCPHUB_SWAP` (MiB), `MCPHUB_DISK` (GiB), `MCPHUB_CIDR`, `MCPHUB_GATEWAY`, `MCPHUB_BRIDGE`, `MCPHUB_STORAGE`, `MCPHUB_TEMPLATE_STORAGE`, `MCPHUB_NAMESERVERS`, and `MCPHUB_PORT`.

## Access And Data

Open `http://<container-ip>:3000/` after installation. The username is `admin`. Read the generated initial password inside the LXC:

```bash
sed -n 's/^ADMIN_PASSWORD=//p' /opt/mcphub/.env
```

The credentials file has mode `0600` and also stores the persistent JWT secret. Change your password through the dashboard after logging in. `ADMIN_PASSWORD` only initializes an empty user list; changing it later does not reset an existing user's password.

Add MCP servers through the dashboard. The Streamable HTTP endpoint is `http://<container-ip>:3000/mcp`; the legacy SSE endpoint is `/sse`. Configure bearer authentication in MCPHub before connecting clients or exposing these endpoints outside your trusted network. Use an HTTPS reverse proxy for remote access; the installer itself serves HTTP.

Settings, users, and credential encryption sidecars persist in `/opt/mcphub/data`. The installer starts with no MCP servers configured. npm and uv caches use persistent Docker volumes so stdio server packages survive image updates. Back up `/opt/mcphub` securely, including `.env` and the entire data directory, not just `mcp_settings.json`.

The Docker container is not privileged and does not mount the Docker socket. MCP servers that need Docker-in-Docker or the extended image's Rust/browser tools require additional manual configuration.

## Updates And Troubleshooting

Run updates inside the LXC:

```bash
update
```

This resolves the latest stable release, updates only `MCPHUB_VERSION`, pulls the image, recreates the service, and checks `/health`. It keeps credentials and data intact. Back up your data before updating; automatic rollback is not provided.

To view application logs inside the LXC:

```bash
cd /opt/mcphub
docker compose --env-file .env -f compose.yml logs --tail 100 mcphub
```

Installer output is logged on the Proxmox host at `/var/log/mcphub-lxc-install-<ctid>.log`. Failed installations keep the LXC for inspection; use `pct enter <ctid>` on the host.

Run the mocked test suite locally with `bash mcphub/tests/run.sh`. These tests do not create a real LXC.
