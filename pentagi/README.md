# PentAGI LXC

Self-contained Proxmox installer for [PentAGI](https://github.com/vxcontrol/pentagi), its upstream Docker Compose stack, and a local Ollama `nomic-embed-text` embedding service. Run only against systems you are authorized to test.

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/pridhvi/proxmox-scripts/main/pentagi/install.sh)"
```

Run on a Proxmox VE host as root. The installer creates an unprivileged Debian 13 AMD64 LXC with Docker nesting. Defaults: 8 cores, 16 GiB RAM, 1 GiB swap, 64 GiB disk, `vmbr0`, `local-zfs` root storage, `local` template storage, `/24` CIDR, gateway `10.10.10.1`, and HTTPS port `8443`. It prompts for a static IP, DNS and storage settings, LiteLLM URL, chat model alias and API key. The key prompt is hidden.

Use a dedicated LiteLLM virtual key restricted to the chosen chat model. The model must support tool calling. Enter a reachable URL including `/v1`, such as `http://10.10.10.50:4000/v1`, and the exact model alias configured in LiteLLM. HTTP sends credentials and model traffic without encryption; use HTTPS or a trusted isolated network. Keys with characters other than letters, digits, `-`, `_`, and `.` are rejected to avoid unsafe Compose interpolation. Non-interactive runs can set `PENTAGI_LITELLM_KEY` in their environment; environment variables can be visible to privileged processes.

Dry run, with no key required:

```bash
PENTAGI_IP=10.10.10.60 PENTAGI_LITELLM_URL=http://10.10.10.50:4000/v1 PENTAGI_LITELLM_MODEL=my-model bash -c "$(curl -fsSL https://raw.githubusercontent.com/pridhvi/proxmox-scripts/main/pentagi/install.sh)" -- --dry-run --non-interactive
```

Other environment settings use the `PENTAGI_` prefix: `CTID`, `HOSTNAME`, `CORES`, `MEMORY` (MiB), `SWAP` (MiB), `DISK` (GiB), `IP`, `CIDR`, `GATEWAY`, `BRIDGE`, `STORAGE`, `TEMPLATE_STORAGE`, `NAMESERVERS`, `PORT`, `LITELLM_URL`, `LITELLM_MODEL`, and `LITELLM_KEY`. DNS accepts one or two comma-separated IPv4 addresses; blank inherits the host. Use `-v` for verbose logs, `--allow-used-ip` to override the ping check. The installer log is `/var/log/pentagi-lxc-install-<ctid>.log` on the host. On failure the LXC is retained for inspection.

## First Login And Security

Open `https://<container-ip>:8443/`. The initial login is `admin@pentagi.com` / `admin`. **Change the password immediately** under Settings -> Account. The default TLS certificate is self-signed; configure a trusted certificate or reverse proxy for real use. Restrict access to the UI before starting the installer: it listens on all LXC interfaces with a publicly known initial password. Do not expose it to the internet.

PentAGI launches worker containers and has access to the LXC's Docker socket. The installer sets `DOCKER_INSIDE=false`, disables `NET_ADMIN`, and does not give workers a Docker socket. This does not make the environment safe for untrusted work: an LXC is not a VM isolation boundary and the main PentAGI process controls the Docker daemon. For security-sensitive deployments, use a dedicated VM and follow the upstream [worker-node guide](https://github.com/vxcontrol/pentagi/blob/main/examples/guides/worker_node.md).

Workers publish callback ports `28000-29999` on all host interfaces by default. Restrict that range using an upstream firewall or appropriate Docker-aware firewall rules **before running flows**; ordinary UFW rules may not filter Docker-published ports. The installer does not configure a firewall. Outbound worker access is also not restricted; isolate test networks and targets explicitly.

## Verify

Inside the LXC, run PentAGI's tests after installation. `ctester` sends requests to LiteLLM and may incur provider charges:

```bash
docker exec -it pentagi /opt/pentagi/bin/ctester -type custom -verbose
docker exec -it pentagi /opt/pentagi/bin/etester test -verbose
```

The installer checks only whether the HTTPS UI responds; it does not verify tool calling, embeddings, or worker isolation. Use the PentAGI UI to verify a knowledge write and search. Ollama is on the internal Docker network without a published port; its model is stored in a Docker volume. `nomic-embed-text` runs locally on CPU, while chat traffic follows the provider configured behind LiteLLM.

PentAGI configuration and the LiteLLM key are stored in `/opt/pentagi/.env` (mode `0600`). To change the LiteLLM endpoint, key, or model, edit this file and recreate the stack:

```bash
cd /opt/pentagi
docker compose --env-file .env -f compose.yml -f compose.local.yml up -d
```

See logs with `docker compose --env-file .env -f compose.yml -f compose.local.yml logs --tail 100`. Docker Compose and host-level administrators can inspect container environment variables, including secrets.

## Updates And Backups

Inside the LXC, run `update`. It fetches the latest stable PentAGI release's Compose file, pulls the matching PentAGI image and other configured images, recreates the stack and checks the UI. Ollama runtime is refreshed, but **embedding model weights are deliberately not pulled again**: changed weights can make existing vectors incompatible. The updater refuses to replace a locally modified `compose.yml`; put customizations in `compose.local.yml` instead. It preserves `.env`, custom provider files and Docker volumes. Review upstream release notes first; changes to upstream Compose variables may require manual configuration. The updater covers the base stack, not optional Graphiti, Langfuse, observability stacks or existing worker images.

Back up `.env`, `/opt/pentagi`, all relevant Docker volumes (especially PostgreSQL, PentAGI data, SSL, and Ollama models), and any worker artifacts before updating. Use a database-consistent backup; copying `/opt/pentagi` alone does not back up Docker volumes. Updates may perform database migrations and are not automatically rolled back. If an update fails after switching Compose, inspect logs and restore from backup as needed.

To deliberately refresh or change embedding weights, back up first, pull the desired model with `docker compose --env-file .env -f compose.yml -f compose.local.yml exec ollama ollama pull nomic-embed-text`, and use PentAGI's documented `etester reindex` to regenerate stored vectors. Reindex acts on the live database. Do **not** use `etester flush` as a substitute: it deletes stored documents.

Run mocked tests with `bash pentagi/tests/run.sh`; they do not create a real LXC or test a live PentAGI deployment.
