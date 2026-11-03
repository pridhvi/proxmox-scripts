#!/usr/bin/env bash
set -Eeuo pipefail

DRY_RUN=0
NON_INTERACTIVE=0
ALLOW_USED_IP=0
VERBOSE=0
CT_CREATED=0
WORK_DIR=""
SPINNER_PID=""
LOG_FILE=${PENTAGI_LOG_FILE:-}
USE_TTY=0
USE_COLOR=0
CYAN=""
GREEN=""
AMBER=""
RED=""
RESET=""

usage() {
  echo "Usage: $0 [-v|--verbose] [--dry-run] [--non-interactive] [--allow-used-ip]"
}

die() {
  echo "Error: $*" >&2
  exit 1
}

cleanup() {
  stop_spinner
  [[ -z $WORK_DIR ]] || rm -rf -- "$WORK_DIR"
}

on_error() {
  local code=$?
  if [[ $CT_CREATED -eq 1 ]]; then
    echo "Installation stopped. Container ${CTID:-unknown} was kept for inspection." >&2
    echo "Open its console with: pct enter ${CTID:-unknown}" >&2
  fi
  [[ -z ${LOG_FILE:-} || $LOG_FILE == /dev/null ]] || echo "Detailed log: $LOG_FILE" >&2
  exit "$code"
}

setup_output() {
  if [[ -n ${PENTAGI_FORCE_TTY+x} ]]; then
    USE_TTY=$PENTAGI_FORCE_TTY
  elif [[ -t 1 ]]; then
    USE_TTY=1
  else
    USE_TTY=0
  fi

  USE_COLOR=0
  CYAN=""
  GREEN=""
  AMBER=""
  RED=""
  RESET=""
  if [[ $USE_TTY -eq 1 && ! -v NO_COLOR ]]; then
    USE_COLOR=1
    CYAN=$'\033[36m'
    GREEN=$'\033[32m'
    AMBER=$'\033[33m'
    RED=$'\033[31m'
    RESET=$'\033[0m'
  fi

  if [[ -z $LOG_FILE ]]; then
    if [[ $DRY_RUN -eq 1 ]]; then
      LOG_FILE=/dev/null
    else
      LOG_FILE="/var/log/pentagi-lxc-install-${CTID:-unknown}.log"
    fi
  fi
  if [[ $LOG_FILE != /dev/null ]]; then
    mkdir -p "$(dirname "$LOG_FILE")"
  fi
  : >"$LOG_FILE"
}

start_spinner() {
  local label=$1
  if [[ $USE_TTY -ne 1 || ${PENTAGI_TESTING:-0} == 1 ]]; then
    return 0
  fi
  printf '\033[?25l'
  (
    trap 'exit 0' TERM
    local -a frames=('◐' '◓' '◑' '◒')
    local index=0
    while true; do
      printf '\r\033[K  %b%s%b %s' "$AMBER" "${frames[$index]}" "$RESET" "$label"
      index=$(((index + 1) % ${#frames[@]}))
      sleep 0.1
    done
  ) &
  SPINNER_PID=$!
}

stop_spinner() {
  if [[ -n ${SPINNER_PID:-} ]]; then
    kill "$SPINNER_PID" >/dev/null 2>&1 || true
    wait "$SPINNER_PID" 2>/dev/null || true
    SPINNER_PID=""
  fi
  if [[ ${USE_TTY:-0} -eq 1 && ${PENTAGI_TESTING:-0} != 1 ]]; then
    printf '\r\033[K\033[?25h'
  fi
}

print_success() {
  printf '  %b✓%b %s\n' "$GREEN" "$RESET" "$1"
}

print_error() {
  printf '  %b✗%b %s\n' "$RED" "$RESET" "$1" >&2
}

run_step() {
  local label=$1
  shift
  local status
  printf '\n[%s]\n' "$label" >>"$LOG_FILE"

  if [[ $VERBOSE -eq 1 || $DRY_RUN -eq 1 ]]; then
    printf '  %b›%b %s\n' "$CYAN" "$RESET" "$label"
    set +e
    "$@" > >(tee -a "$LOG_FILE") 2>&1
    status=$?
    set -e
  else
    start_spinner "$label"
    set +e
    "$@" >>"$LOG_FILE" 2>&1
    status=$?
    set -e
    stop_spinner
  fi

  if [[ $status -eq 0 ]]; then
    print_success "$label"
  else
    print_error "$label"
  fi
  return "$status"
}

validate_ctid() {
  local value=${1:-}
  [[ $value =~ ^[0-9]+$ ]] && ((10#$value >= 100 && 10#$value <= 999999999))
}

validate_ipv4() {
  local value=${1:-}
  local IFS=.
  local -a octets
  read -r -a octets <<<"$value"
  [[ ${#octets[@]} -eq 4 ]] || return 1

  local octet
  for octet in "${octets[@]}"; do
    [[ $octet =~ ^[0-9]{1,3}$ ]] || return 1
    ((10#$octet <= 255)) || return 1
  done
}

validate_cidr() {
  local value=${1:-}
  [[ $value =~ ^[0-9]+$ ]] && ((10#$value <= 32))
}

validate_port() {
  local value=${1:-}
  [[ $value =~ ^[0-9]+$ ]] && ((10#$value >= 1 && 10#$value <= 65535))
}

validate_hostname() {
  local value=${1:-}
  [[ ${#value} -ge 1 && ${#value} -le 63 ]] || return 1
  [[ $value =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ]]
}

trim_whitespace() {
  local value=${1:-}
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

normalize_nameservers() {
  local value=${1:-}
  if [[ -z $value ]]; then
    return 0
  fi
  [[ $value != ,* && $value != *, && $value != *,,* ]] || return 1

  local IFS=,
  local -a entries
  read -r -a entries <<<"$value"
  ((${#entries[@]} >= 1 && ${#entries[@]} <= 2)) || return 1

  local entry first="" normalized=""
  for entry in "${entries[@]}"; do
    entry=$(trim_whitespace "$entry")
    [[ -n $entry ]] || return 1
    validate_ipv4 "$entry" || return 1
    [[ -z $first || $entry != "$first" ]] || return 1
    [[ -n $first ]] || first=$entry
    normalized+="${normalized:+ }$entry"
  done
  printf '%s' "$normalized"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -v|--verbose) VERBOSE=1 ;;
      --dry-run) DRY_RUN=1 ;;
      --non-interactive) NON_INTERACTIVE=1 ;;
      --allow-used-ip) ALLOW_USED_IP=1 ;;
      --help|-h) usage; exit 0 ;;
      *) die "unknown option: $1" ;;
    esac
    shift
  done
}

prompt() {
  local variable=$1 label=$2 default=$3 value
  read -r -p "$label [$default]: " value
  printf -v "$variable" '%s' "${value:-$default}"
}

collect_settings() {
  local suggested_ctid
  suggested_ctid=$(pvesh get /cluster/nextid)

  CTID=${PENTAGI_CTID:-$suggested_ctid}
  HOSTNAME=${PENTAGI_HOSTNAME:-pentagi}
  CORES=${PENTAGI_CORES:-8}
  MEMORY=${PENTAGI_MEMORY:-16384}
  SWAP=${PENTAGI_SWAP:-1024}
  DISK=${PENTAGI_DISK:-64}
  IP_ADDRESS=${PENTAGI_IP:-}
  CIDR=${PENTAGI_CIDR:-24}
  GATEWAY=${PENTAGI_GATEWAY:-10.10.10.1}
  BRIDGE=${PENTAGI_BRIDGE:-vmbr0}
  STORAGE=${PENTAGI_STORAGE:-local-zfs}
  TEMPLATE_STORAGE=${PENTAGI_TEMPLATE_STORAGE:-local}
  PORT=${PENTAGI_PORT:-8443}
  NAMESERVER_INPUT=${PENTAGI_NAMESERVERS:-}
  LITELLM_URL=${PENTAGI_LITELLM_URL:-}
  LITELLM_MODEL=${PENTAGI_LITELLM_MODEL:-}
  LITELLM_KEY=${PENTAGI_LITELLM_KEY:-}

  if [[ $NON_INTERACTIVE -eq 0 ]]; then
    prompt CTID "Container ID" "$CTID"
    prompt HOSTNAME "Hostname" "$HOSTNAME"
    if [[ -n $IP_ADDRESS ]]; then
      prompt IP_ADDRESS "Static IPv4 address" "$IP_ADDRESS"
    else
      read -r -p "Static IPv4 address: " IP_ADDRESS
    fi
    prompt CIDR "IPv4 CIDR" "$CIDR"
    prompt GATEWAY "IPv4 gateway" "$GATEWAY"
    prompt BRIDGE "Bridge" "$BRIDGE"
    prompt STORAGE "Root-disk storage" "$STORAGE"
    prompt TEMPLATE_STORAGE "Template storage" "$TEMPLATE_STORAGE"
    prompt NAMESERVER_INPUT "DNS servers, comma separated; blank inherits host" "$NAMESERVER_INPUT"
    prompt LITELLM_URL "LiteLLM base URL (including /v1)" "$LITELLM_URL"
    prompt LITELLM_MODEL "LiteLLM chat model alias" "$LITELLM_MODEL"
    if [[ -z $LITELLM_KEY && $DRY_RUN -eq 0 ]]; then
      read -r -s -p "LiteLLM API key: " LITELLM_KEY
      printf '\n'
    fi
  fi
}

print_command() {
  printf '  '
  printf '%q ' "$@"
  printf '\n'
}

mutate() {
  if [[ $DRY_RUN -eq 1 ]]; then
    print_command "$@"
  else
    "$@"
  fi
}

storage_supports() {
  local storage=$1 content=$2
  pvesm status -content "$content" -enabled 1 2>/dev/null |
    awk 'NR > 1 {print $1}' |
    grep -Fxq "$storage"
}

preflight() {
  local effective_uid=$EUID
  if [[ ${PENTAGI_TESTING:-0} == 1 ]]; then
    effective_uid=${PENTAGI_TEST_EUID:-$EUID}
  fi
  [[ $effective_uid -eq 0 ]] || { echo "Error: run this installer as root on a Proxmox host" >&2; return 1; }

  local command
  for command in pct pveam pvesm pvesh ip ping; do
    command -v "$command" >/dev/null || { echo "Error: required command not found: $command" >&2; return 1; }
  done

  validate_ctid "$CTID" || { echo "Error: invalid container ID: $CTID" >&2; return 1; }
  validate_hostname "$HOSTNAME" || { echo "Error: invalid hostname: $HOSTNAME" >&2; return 1; }
  [[ -n $IP_ADDRESS ]] || { echo "Error: static IPv4 address is required" >&2; return 1; }
  validate_ipv4 "$IP_ADDRESS" || { echo "Error: invalid IPv4 address: $IP_ADDRESS" >&2; return 1; }
  validate_cidr "$CIDR" || { echo "Error: invalid IPv4 CIDR: $CIDR" >&2; return 1; }
  validate_ipv4 "$GATEWAY" || { echo "Error: invalid gateway: $GATEWAY" >&2; return 1; }
  validate_port "$PORT" || { echo "Error: invalid PentAGI port: $PORT" >&2; return 1; }
  [[ $LITELLM_URL =~ ^https?://[a-zA-Z0-9._:-]+(/[-a-zA-Z0-9._~:/]*)?$ ]] || { echo "Error: invalid LiteLLM URL" >&2; return 1; }
  [[ $LITELLM_MODEL =~ ^[a-zA-Z0-9._:/-]+$ ]] || { echo "Error: invalid LiteLLM model alias" >&2; return 1; }
  if [[ $DRY_RUN -eq 0 ]]; then
    [[ $LITELLM_KEY =~ ^[a-zA-Z0-9._-]+$ ]] || { echo "Error: LiteLLM key is missing or contains unsupported characters" >&2; return 1; }
  fi
  NAMESERVERS=$(normalize_nameservers "$NAMESERVER_INPUT") || {
    echo "Error: DNS servers must be one or two unique IPv4 addresses separated by commas" >&2
    return 1
  }
  [[ $CORES =~ ^[0-9]+$ && $CORES -gt 0 ]] || { echo "Error: invalid core count: $CORES" >&2; return 1; }
  [[ $MEMORY =~ ^[0-9]+$ && $MEMORY -gt 0 ]] || { echo "Error: invalid memory: $MEMORY" >&2; return 1; }
  [[ $SWAP =~ ^[0-9]+$ ]] || { echo "Error: invalid swap: $SWAP" >&2; return 1; }
  [[ $DISK =~ ^[0-9]+$ && $DISK -gt 0 ]] || { echo "Error: invalid disk size: $DISK" >&2; return 1; }

  if pct status "$CTID" >/dev/null 2>&1; then
    echo "Error: container ID $CTID already exists" >&2
    return 1
  fi
  ip link show "$BRIDGE" >/dev/null 2>&1 || { echo "Error: bridge not found: $BRIDGE" >&2; return 1; }
  storage_supports "$STORAGE" rootdir || { echo "Error: storage does not support container disks: $STORAGE" >&2; return 1; }
  storage_supports "$TEMPLATE_STORAGE" vztmpl || { echo "Error: storage does not support templates: $TEMPLATE_STORAGE" >&2; return 1; }

  if [[ $ALLOW_USED_IP -eq 0 ]] && ping -c 1 -W 1 "$IP_ADDRESS" >/dev/null 2>&1; then
    echo "Error: IPv4 address responds to ping: $IP_ADDRESS (use --allow-used-ip to override)" >&2
    return 1
  fi
}

resolve_template() {
  TEMPLATE=$(pveam available --section system |
    awk '$2 ~ /^debian-13-standard_.*_amd64[.]tar[.]zst$/ {print $2}' |
    sort -V |
    tail -n 1)
  [[ -n $TEMPLATE ]] || { echo "Error: no Debian 13 AMD64 standard template is available" >&2; return 1; }
  TEMPLATE_REF="$TEMPLATE_STORAGE:vztmpl/$TEMPLATE"

  if ! pveam list "$TEMPLATE_STORAGE" 2>/dev/null | grep -Fq "/$TEMPLATE"; then
    mutate pveam download "$TEMPLATE_STORAGE" "$TEMPLATE" || return $?
  fi
}

create_container() {
  local net="name=eth0,bridge=$BRIDGE,ip=$IP_ADDRESS/$CIDR,gw=$GATEWAY"
  local -a command=(
    pct create "$CTID" "$TEMPLATE_REF"
    --hostname "$HOSTNAME"
    --cores "$CORES"
    --memory "$MEMORY"
    --swap "$SWAP"
    --rootfs "$STORAGE:$DISK"
    --net0 "$net"
    --features "nesting=1,keyctl=1"
    --unprivileged 1
    --onboot 1
    --start 0
  )
  if [[ -n $NAMESERVERS ]]; then
    command+=(--nameserver "$NAMESERVERS")
  fi
  mutate "${command[@]}" || return $?
  [[ $DRY_RUN -eq 1 ]] || CT_CREATED=1
}

start_container() {
  mutate pct start "$CTID"
}

wait_for_guest() {
  [[ $DRY_RUN -eq 1 ]] && return 0
  local attempt
  for attempt in {1..30}; do
    if pct exec "$CTID" -- true >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  echo "Error: container did not become ready" >&2
  return 1
}

prepare_payloads() {
  [[ -z $WORK_DIR ]] || return 0
  WORK_DIR=$(mktemp -d)
  cat >"$WORK_DIR/override.yml" <<'PENTAGI_OVERRIDE'
services:
  ollama:
    image: ollama/ollama:latest
    restart: unless-stopped
    volumes:
      - ollama-models:/root/.ollama
    networks:
      - pentagi-network
volumes:
  ollama-models:
PENTAGI_OVERRIDE

  cat >"$WORK_DIR/update.sh" <<'PENTAGI_UPDATER'
#!/usr/bin/env bash
set -Eeuo pipefail
PENTAGI_DIR=${PENTAGI_DIR:-/opt/pentagi}
cd "$PENTAGI_DIR"
die() { echo "Error: $*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die "run as root"
[[ -f .env && -f compose.yml && -f compose.local.yml && -f .compose.sha256 ]] || die "installation files are missing"
sha256sum -c .compose.sha256 >/dev/null || die "compose.yml was modified; review the upstream update manually"
port=$(awk -F= '$1=="PENTAGI_LISTEN_PORT" {n++;v=$2} END {if(n!=1) exit 1; print v}' .env) || die "invalid port configuration"
[[ $port =~ ^[0-9]+$ ]] && ((10#$port >= 1 && 10#$port <= 65535)) || die "invalid port"
image=$(awk -F= '$1=="PENTAGI_IMAGE" {n++;v=$2} END {if(n!=1) exit 1; print v}' .env) || die "PENTAGI_IMAGE is missing or duplicated in .env"
[[ $image =~ ^vxcontrol/pentagi:[0-9]+[.][0-9]+[.][0-9]+$ ]] || die "custom PentAGI image detected; update it manually"
temp=$(mktemp -d "$PENTAGI_DIR/.update.XXXXXX")
trap 'rm -rf -- "$temp"' EXIT
response=$(curl -fsSL -H 'Accept: application/vnd.github+json' -H 'User-Agent: proxmox-scripts-pentagi' https://api.github.com/repos/vxcontrol/pentagi/releases/latest)
version=$(printf '%s' "$response" | jq -er '.tag_name | select(type == "string")')
[[ $version =~ ^v[0-9]+[.][0-9]+[.][0-9]+$ ]] || die "invalid PentAGI release tag"
curl -fsSL "https://raw.githubusercontent.com/vxcontrol/pentagi/$version/docker-compose.yml" -o "$temp/compose.yml"
awk -v image="vxcontrol/pentagi:${version#v}" '/^PENTAGI_IMAGE=/ {print "PENTAGI_IMAGE=" image; next} {print}' .env >"$temp/.env"
chmod 0600 "$temp/.env"
docker compose --project-directory "$PENTAGI_DIR" --env-file "$temp/.env" -f "$temp/compose.yml" -f "$PENTAGI_DIR/compose.local.yml" config -q
echo "Pulling PentAGI $version and service images. Back up the database before updating."
docker compose --project-directory "$PENTAGI_DIR" --env-file "$temp/.env" -f "$temp/compose.yml" -f "$PENTAGI_DIR/compose.local.yml" pull
install -m 0644 "$temp/compose.yml" compose.yml
mv "$temp/.env" .env
sha256sum compose.yml >.compose.sha256
docker compose --env-file .env -f compose.yml -f compose.local.yml up -d
for attempt in {1..90}; do
  if curl -kfsS --max-time 5 "https://127.0.0.1:$port/" >/dev/null; then
    echo "PentAGI UI is responding. Ollama model weights were preserved; run etester to verify embeddings."
    exit 0
  fi
  sleep 5
done
die "PentAGI UI did not become ready; inspect docker compose logs"
PENTAGI_UPDATER

  cat >"$WORK_DIR/install-internal.sh" <<'PENTAGI_GUEST'
#!/usr/bin/env bash
set -Eeuo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
die() { echo "Error: $*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die "run inside the LXC as root"
[[ ! -e /opt/pentagi/.env ]] || die "PentAGI is already configured; use update instead"
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ca-certificates curl jq openssl docker.io docker-cli docker-compose
systemctl enable --now docker
install -d -m 0700 /opt/pentagi
cd /opt/pentagi
install -m 0644 /tmp/pentagi-override.yml compose.local.yml
install -m 0600 /tmp/pentagi-settings .env
rm -f /tmp/pentagi-settings
install -m 0755 /tmp/pentagi-update /usr/local/sbin/pentagi-update
ln -sfn /usr/local/sbin/pentagi-update /usr/bin/update
response=$(curl -fsSL -H 'Accept: application/vnd.github+json' -H 'User-Agent: proxmox-scripts-pentagi' https://api.github.com/repos/vxcontrol/pentagi/releases/latest)
version=$(printf '%s' "$response" | jq -er '.tag_name | select(type == "string")')
[[ $version =~ ^v[0-9]+[.][0-9]+[.][0-9]+$ ]] || die "invalid PentAGI release tag"
curl -fsSL "https://raw.githubusercontent.com/vxcontrol/pentagi/$version/docker-compose.yml" -o compose.yml
sha256sum compose.yml >.compose.sha256
for file in example.custom.provider.yml example.ollama.provider.yml example.bedrock.provider.yml; do
  : >"$file"
done
install -d -m 0700 docker-ssl
secret() { openssl rand -hex 32; }
salt=$(secret)
db_password=$(secret)
scraper_password=$(secret)
[[ $salt =~ ^[0-9a-f]{64}$ && $db_password =~ ^[0-9a-f]{64}$ && $scraper_password =~ ^[0-9a-f]{64}$ ]] || die "secret generation failed"
{
  printf 'PENTAGI_IMAGE=vxcontrol/pentagi:%s\n' "${version#v}"
  printf 'COOKIE_SIGNING_SALT=%s\n' "$salt"
  printf 'PENTAGI_POSTGRES_USER=postgres\nPENTAGI_POSTGRES_DB=pentagidb\nPENTAGI_POSTGRES_PASSWORD=%s\n' "$db_password"
  printf 'LOCAL_SCRAPER_USERNAME=pentagi\nLOCAL_SCRAPER_PASSWORD=%s\n' "$scraper_password"
  printf 'SCRAPER_PRIVATE_URL=https://pentagi:%s@scraper/\n' "$scraper_password"
  printf 'EMBEDDING_PROVIDER=ollama\nEMBEDDING_URL=http://ollama:11434\nEMBEDDING_MODEL=nomic-embed-text\n'
  printf 'DOCKER_INSIDE=false\nDOCKER_NET_ADMIN=false\nDOCKER_SOCKET=\n'
} >>.env
unset salt db_password scraper_password
docker compose --env-file .env -f compose.yml -f compose.local.yml config -q
docker compose --env-file .env -f compose.yml -f compose.local.yml pull
docker compose --env-file .env -f compose.yml -f compose.local.yml up -d ollama
for attempt in {1..60}; do
  if docker compose --env-file .env -f compose.yml -f compose.local.yml exec -T ollama ollama list >/dev/null 2>&1; then break; fi
  [[ $attempt -lt 60 ]] || die "Ollama did not become ready"
  sleep 2
done
docker compose --env-file .env -f compose.yml -f compose.local.yml exec -T ollama ollama pull nomic-embed-text
docker compose --env-file .env -f compose.yml -f compose.local.yml up -d
port=$(awk -F= '$1=="PENTAGI_LISTEN_PORT" {print $2}' .env)
for attempt in {1..90}; do
  if curl -kfsS --max-time 5 "https://127.0.0.1:$port/" >/dev/null; then
    rm -rf /var/lib/apt/lists/*
    exit 0
  fi
  sleep 5
done
die "PentAGI UI did not become ready"
PENTAGI_GUEST
  chmod 0755 "$WORK_DIR/update.sh" "$WORK_DIR/install-internal.sh"
}

install_gateway() {
  prepare_payloads
  umask 077
  {
    printf 'PENTAGI_LISTEN_IP=0.0.0.0\nPENTAGI_LISTEN_PORT=%s\n' "$PORT"
    printf 'PUBLIC_URL=https://%s:%s\n' "$IP_ADDRESS" "$PORT"
    printf 'CORS_ORIGINS=https://localhost:%s,https://%s:%s\n' "$PORT" "$IP_ADDRESS" "$PORT"
    printf 'LLM_SERVER_URL=%s\nLLM_SERVER_MODEL=%s\n' "$LITELLM_URL" "$LITELLM_MODEL"
    printf 'LLM_SERVER_KEY=%s\n' "$LITELLM_KEY"
  } >"$WORK_DIR/settings"
  unset LITELLM_KEY
  mutate pct push "$CTID" "$WORK_DIR/override.yml" /tmp/pentagi-override.yml --perms 0644 || return $?
  mutate pct push "$CTID" "$WORK_DIR/update.sh" /tmp/pentagi-update --perms 0755 || return $?
  mutate pct push "$CTID" "$WORK_DIR/settings" /tmp/pentagi-settings --perms 0600 || return $?
  mutate pct push "$CTID" "$WORK_DIR/install-internal.sh" /root/install-pentagi.sh --perms 0755 || return $?
  mutate pct exec "$CTID" -- /root/install-pentagi.sh
}

verify_gateway() {
  [[ $DRY_RUN -eq 1 ]] && return 0
  pct exec "$CTID" -- curl -kfsS --max-time 5 "https://127.0.0.1:${PORT}/" >/dev/null
}

print_summary() {
  if [[ $DRY_RUN -eq 1 ]]; then
    printf '\nDry run complete. No changes were made.\n'
    return 0
  fi
  printf '\n%bPentAGI UI is responding%b\n' "$GREEN" "$RESET"
  printf 'UI: https://%s:%s/ (self-signed certificate)\n' "$IP_ADDRESS" "$PORT"
  printf 'Initial login: admin@pentagi.com / admin; change the password immediately.\n'
  printf 'Configuration: /opt/pentagi/.env (mode 0600)\n'
  printf 'Update: pct exec %s -- update\n' "$CTID"
  printf 'Verify the LiteLLM provider and embeddings with ctester and etester; see the README.\n'
  printf 'WARNING: worker callback ports may be exposed on all interfaces; restrict them at the network firewall.\n'
}

main() {
  parse_args "$@"
  collect_settings
  setup_output
  printf '\n%bPentAGI LXC%b\n' "$CYAN" "$RESET"
  printf '%bContainer %s | %s/%s | %s%b\n\n' "$CYAN" "$CTID" "$IP_ADDRESS" "$CIDR" "$STORAGE" "$RESET"
  printf 'WARNING: UI uses a known initial password; restrict network access before installation.\n'
  printf 'Workers publish callback ports 28000-29999; configure a Docker-aware firewall before running flows.\n'
  run_step "Validating Proxmox host" preflight || return $?
  run_step "Preparing Debian 13 template" resolve_template || return $?
  run_step "Creating container $CTID" create_container || return $?
  run_step "Starting container $CTID" start_container || return $?
  run_step "Waiting for container" wait_for_guest || return $?
  run_step "Installing PentAGI" install_gateway || return $?
  run_step "Verifying PentAGI UI" verify_gateway || return $?
  print_summary
}

if [[ ${BASH_SOURCE[0]-$0} == "$0" ]]; then
  trap cleanup EXIT
  trap on_error ERR
  main "$@"
fi
