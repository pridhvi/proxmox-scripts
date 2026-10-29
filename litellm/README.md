# LiteLLM LXC

Run this on a Proxmox VE host:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/pridhvi/proxmox-scripts/main/litellm/install.sh)"
```

The script creates an unprivileged Debian 13 AMD64 LXC and runs LiteLLM with PostgreSQL through Docker Compose.

Defaults:

- 8 CPU cores, 16 GiB RAM, 1 GiB swap, 32 GiB disk
- CIDR `/24`, gateway `10.10.10.1`, bridge `vmbr0`
- Storage `local-zfs`, template storage `local`
- LiteLLM port `4000`

The installer prompts for a static IPv4 address. The DNS prompt accepts one or two IPv4 addresses separated by a comma. Leave it blank to inherit the Proxmox host's DNS settings.

Use `-v` to show full command output:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/pridhvi/proxmox-scripts/main/litellm/install.sh)" -- -v
```

To inspect the commands without changing Proxmox:

```bash
LITELLM_IP=10.10.10.50 LITELLM_NAMESERVERS=10.10.10.2,10.10.10.3 bash -c "$(curl -fsSL https://raw.githubusercontent.com/pridhvi/proxmox-scripts/main/litellm/install.sh)" -- --dry-run --non-interactive
```

Non-interactive runs require `LITELLM_IP`. Other values can use the same `LITELLM_` prefix, including `LITELLM_CTID`, `LITELLM_GATEWAY`, `LITELLM_STORAGE`, and `LITELLM_TEMPLATE_STORAGE`.

Open `http://<container-ip>:4000/ui/` after installation. The username is `admin`. The password is the `LITELLM_MASTER_KEY` in `/opt/litellm/.env`, which has mode `0600`.

Run updates inside the container:

```bash
update
```
