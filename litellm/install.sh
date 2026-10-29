#!/usr/bin/env bash
set -Eeuo pipefail

DRY_RUN=0
NON_INTERACTIVE=0
ALLOW_USED_IP=0
VERBOSE=0
CT_CREATED=0
WORK_DIR=""
SPINNER_PID=""
LOG_FILE=${LITELLM_LOG_FILE:-}
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
  if [[ -n ${LITELLM_FORCE_TTY+x} ]]; then
    USE_TTY=$LITELLM_FORCE_TTY
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
      LOG_FILE="/var/log/litellm-lxc-install-${CTID:-unknown}.log"
    fi
  fi
  if [[ $LOG_FILE != /dev/null ]]; then
    mkdir -p "$(dirname "$LOG_FILE")"
  fi
  : >"$LOG_FILE"
}

start_spinner() {
  local label=$1
  if [[ $USE_TTY -ne 1 || ${LITELLM_TESTING:-0} == 1 ]]; then
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
  if [[ ${USE_TTY:-0} -eq 1 && ${LITELLM_TESTING:-0} != 1 ]]; then
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

  CTID=${LITELLM_CTID:-$suggested_ctid}
  HOSTNAME=${LITELLM_HOSTNAME:-litellm}
  CORES=${LITELLM_CORES:-8}
  MEMORY=${LITELLM_MEMORY:-16384}
  SWAP=${LITELLM_SWAP:-1024}
  DISK=${LITELLM_DISK:-32}
  IP_ADDRESS=${LITELLM_IP:-}
  CIDR=${LITELLM_CIDR:-24}
  GATEWAY=${LITELLM_GATEWAY:-10.10.10.1}
  BRIDGE=${LITELLM_BRIDGE:-vmbr0}
  STORAGE=${LITELLM_STORAGE:-local-zfs}
  TEMPLATE_STORAGE=${LITELLM_TEMPLATE_STORAGE:-local}
  PORT=${LITELLM_PORT:-4000}
  NAMESERVER_INPUT=${LITELLM_NAMESERVERS:-}

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
  if [[ ${LITELLM_TESTING:-0} == 1 ]]; then
    effective_uid=${LITELLM_TEST_EUID:-$EUID}
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
  validate_port "$PORT" || { echo "Error: invalid LiteLLM port: $PORT" >&2; return 1; }
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

  cat >"$WORK_DIR/compose.yml" <<'LITELLM_COMPOSE'
services:
  litellm:
    image: ghcr.io/berriai/litellm:${LITELLM_VERSION}
    restart: unless-stopped
    ports:
      - "${LITELLM_PORT:-4000}:4000"
    environment:
      LITELLM_MASTER_KEY: ${LITELLM_MASTER_KEY:?set in .env}
      LITELLM_SALT_KEY: ${LITELLM_SALT_KEY:?set in .env}
      DATABASE_URL: postgresql://litellm:${POSTGRES_PASSWORD:?set in .env}@db:5432/litellm
      STORE_MODEL_IN_DB: "True"
    depends_on:
      db:
        condition: service_healthy

  db:
    image: postgres:16
    restart: unless-stopped
    environment:
      POSTGRES_USER: litellm
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD:?set in .env}
      POSTGRES_DB: litellm
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U litellm -d litellm"]
      interval: 5s
      timeout: 5s
      retries: 20
    volumes:
      - postgres_data:/var/lib/postgresql/data

volumes:
  postgres_data:
LITELLM_COMPOSE

  cat >"$WORK_DIR/update.sh" <<'LITELLM_UPDATER'
#!/usr/bin/env bash
set -Eeuo pipefail

LITELLM_DIR=${LITELLM_DIR:-/opt/litellm}
ENV_FILE="$LITELLM_DIR/.env"
COMPOSE_FILE="$LITELLM_DIR/compose.yml"
TEMP_ENV=""

cleanup() {
  [[ -z $TEMP_ENV ]] || rm -f -- "$TEMP_ENV"
}
trap cleanup EXIT

die() {
  echo "Error: $*" >&2
  exit 1
}

resolve_latest_litellm_version() {
  local response version
  response=$(curl -fsSL \
    -H 'Accept: application/vnd.github+json' \
    -H 'User-Agent: proxmox-scripts-litellm' \
    https://api.github.com/repos/BerriAI/litellm/releases/latest)
  version=$(printf '%s' "$response" | jq -er '.tag_name | select(type == "string")')
  [[ $version =~ ^v[0-9]+[.][0-9]+[.][0-9]+$ ]] || die "GitHub returned an invalid LiteLLM release tag"
  printf '%s\n' "$version"
}

read_single_value() {
  local key=$1
  awk -F= -v key="$key" '
    $1 == key { count++; sub(/^[^=]*=/, ""); value=$0 }
    END { if (count != 1) exit 1; print value }
  ' "$ENV_FILE"
}

wait_for_litellm() {
  local port=$1 attempt
  for attempt in {1..90}; do
    if curl -fsS --max-time 5 "http://127.0.0.1:${port}/health/readiness" >/dev/null; then
      return 0
    fi
    sleep 5
  done
  die "LiteLLM did not become ready"
}

[[ $EUID -eq 0 ]] || die "run as root"
[[ -f $ENV_FILE ]] || die "credentials file not found: $ENV_FILE"
[[ -f $COMPOSE_FILE ]] || die "Compose file not found: $COMPOSE_FILE"

next_version=$(resolve_latest_litellm_version)
port=$(read_single_value LITELLM_PORT) || die "LITELLM_PORT is missing or duplicated in .env"
[[ $port =~ ^[0-9]+$ ]] && ((port >= 1 && port <= 65535)) || die "invalid LITELLM_PORT in .env"
read_single_value LITELLM_VERSION >/dev/null || die "LITELLM_VERSION is missing or duplicated in .env"

TEMP_ENV=$(mktemp "$LITELLM_DIR/.env.XXXXXX")
awk -v version="$next_version" '
  /^LITELLM_VERSION=/ { print "LITELLM_VERSION=" version; next }
  { print }
' "$ENV_FILE" >"$TEMP_ENV"
chmod 0600 "$TEMP_ENV"
mv -f "$TEMP_ENV" "$ENV_FILE"
TEMP_ENV=""

printf 'Updating LiteLLM to %s\n' "$next_version"
cd "$LITELLM_DIR"
docker compose --env-file .env -f compose.yml pull
docker compose --env-file .env -f compose.yml up -d
wait_for_litellm "$port"
printf 'LiteLLM is ready.\n'
LITELLM_UPDATER

  cat >"$WORK_DIR/install-internal.sh" <<'LITELLM_GUEST_INSTALLER'
#!/usr/bin/env bash
set -Eeuo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

PORT=${LITELLM_PORT:-4000}

die() {
  echo "Error: $*" >&2
  exit 1
}

resolve_latest_litellm_version() {
  local response version
  response=$(curl -fsSL \
    -H 'Accept: application/vnd.github+json' \
    -H 'User-Agent: proxmox-scripts-litellm' \
    https://api.github.com/repos/BerriAI/litellm/releases/latest)
  version=$(printf '%s' "$response" | jq -er '.tag_name | select(type == "string")')
  [[ $version =~ ^v[0-9]+[.][0-9]+[.][0-9]+$ ]] || die "GitHub returned an invalid LiteLLM release tag"
  printf '%s\n' "$version"
}

wait_for_litellm() {
  local attempt
  for attempt in {1..90}; do
    if curl -fsS --max-time 5 "http://127.0.0.1:${PORT}/health/readiness" >/dev/null; then
      return 0
    fi
    sleep 5
  done
  die "LiteLLM did not become ready"
}

generate_hex_secret() {
  local secret
  secret=$(openssl rand -hex 32) || die "could not generate a secure random value"
  [[ $secret =~ ^[0-9a-f]{64}$ ]] || die "generated random value has an invalid format"
  printf '%s\n' "$secret"
}

[[ $EUID -eq 0 ]] || die "run inside the LXC as root"
[[ $PORT =~ ^[0-9]+$ ]] && ((PORT >= 1 && PORT <= 65535)) || die "invalid LiteLLM port"

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ca-certificates curl jq openssl docker.io docker-compose
systemctl enable --now docker

install -d -m 0755 /opt/litellm
install -m 0644 /tmp/litellm-compose.yml /opt/litellm/compose.yml
install -m 0755 /tmp/litellm-update /usr/local/sbin/litellm-update
ln -sfn /usr/local/sbin/litellm-update /usr/bin/update

version=$(resolve_latest_litellm_version)
master_key=$(generate_hex_secret)
salt_key=$(generate_hex_secret)
postgres_password=$(generate_hex_secret)
umask 077
env_file=$(mktemp /opt/litellm/.env.XXXXXX)
{
  printf 'LITELLM_VERSION=%s\n' "$version"
  printf 'LITELLM_PORT=%s\n' "$PORT"
  printf 'LITELLM_MASTER_KEY=sk-%s\n' "$master_key"
  printf 'LITELLM_SALT_KEY=sk-%s\n' "$salt_key"
  printf 'POSTGRES_PASSWORD=%s\n' "$postgres_password"
} >"$env_file"
mv "$env_file" /opt/litellm/.env
chmod 0600 /opt/litellm/.env
unset master_key salt_key postgres_password

cd /opt/litellm
docker compose --env-file .env -f compose.yml pull
docker compose --env-file .env -f compose.yml up -d
wait_for_litellm

rm -rf /var/lib/apt/lists/*
LITELLM_GUEST_INSTALLER

  chmod 0755 "$WORK_DIR/install-internal.sh" "$WORK_DIR/update.sh"
}

install_gateway() {
  prepare_payloads
  mutate pct push "$CTID" "$WORK_DIR/compose.yml" /tmp/litellm-compose.yml --perms 0644 || return $?
  mutate pct push "$CTID" "$WORK_DIR/update.sh" /tmp/litellm-update --perms 0755 || return $?
  mutate pct push "$CTID" "$WORK_DIR/install-internal.sh" /root/install-litellm.sh --perms 0755 || return $?
  mutate pct exec "$CTID" -- env "LITELLM_PORT=$PORT" /root/install-litellm.sh
}

verify_gateway() {
  [[ $DRY_RUN -eq 1 ]] && return 0
  pct exec "$CTID" -- curl -fsS --max-time 5 "http://127.0.0.1:${PORT}/health/readiness" >/dev/null
}

print_summary() {
  if [[ $DRY_RUN -eq 1 ]]; then
    printf '\nDry run complete. No changes were made.\n'
    return 0
  fi
  printf '\n%bLiteLLM is ready%b\n' "$GREEN" "$RESET"
  printf 'UI: http://%s:%s/ui/\n' "$IP_ADDRESS" "$PORT"
  printf 'Username: admin\n'
  printf 'Credentials: /opt/litellm/.env\n'
  printf "Password: pct exec %q -- sed -n 's/^LITELLM_MASTER_KEY=//p' /opt/litellm/.env\n" "$CTID"
  printf 'Update: pct exec %s -- update\n' "$CTID"
}

main() {
  parse_args "$@"
  collect_settings
  setup_output
  printf '\n%bLiteLLM LXC%b\n' "$CYAN" "$RESET"
  printf '%bContainer %s · %s/%s · %s%b\n\n' "$CYAN" "$CTID" "$IP_ADDRESS" "$CIDR" "$STORAGE" "$RESET"
  run_step "Validating Proxmox host" preflight || return $?
  run_step "Preparing Debian 13 template" resolve_template || return $?
  run_step "Creating container $CTID" create_container || return $?
  run_step "Starting container $CTID" start_container || return $?
  run_step "Waiting for container" wait_for_guest || return $?
  run_step "Installing LiteLLM gateway" install_gateway || return $?
  run_step "Verifying LiteLLM gateway" verify_gateway || return $?
  print_summary
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  trap cleanup EXIT
  trap on_error ERR
  main "$@"
fi
