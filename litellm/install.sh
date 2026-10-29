#!/usr/bin/env bash
set -Eeuo pipefail

DRY_RUN=0
NON_INTERACTIVE=0
ALLOW_USED_IP=0
VERBOSE=0
CT_CREATED=0
WORK_DIR=""

usage() {
  echo "Usage: $0 [-v|--verbose] [--dry-run] [--non-interactive] [--allow-used-ip]"
}

die() {
  echo "Error: $*" >&2
  exit 1
}

cleanup() {
  [[ -z $WORK_DIR ]] || rm -rf -- "$WORK_DIR"
}

on_error() {
  local code=$?
  if [[ $CT_CREATED -eq 1 ]]; then
    echo "Installation stopped. Container ${CTID:-unknown} was kept for inspection." >&2
    echo "Open its console with: pct enter ${CTID:-unknown}" >&2
  fi
  exit "$code"
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
  [[ $effective_uid -eq 0 ]] || die "run this installer as root on a Proxmox host"

  local command
  for command in pct pveam pvesm pvesh ip ping; do
    command -v "$command" >/dev/null || die "required command not found: $command"
  done

  validate_ctid "$CTID" || die "invalid container ID: $CTID"
  validate_hostname "$HOSTNAME" || die "invalid hostname: $HOSTNAME"
  [[ -n $IP_ADDRESS ]] || die "static IPv4 address is required"
  validate_ipv4 "$IP_ADDRESS" || die "invalid IPv4 address: $IP_ADDRESS"
  validate_cidr "$CIDR" || die "invalid IPv4 CIDR: $CIDR"
  validate_ipv4 "$GATEWAY" || die "invalid gateway: $GATEWAY"
  validate_port "$PORT" || die "invalid LiteLLM port: $PORT"
  NAMESERVERS=$(normalize_nameservers "$NAMESERVER_INPUT") || die "DNS servers must be one or two unique IPv4 addresses separated by commas"
  [[ $CORES =~ ^[0-9]+$ && $CORES -gt 0 ]] || die "invalid core count: $CORES"
  [[ $MEMORY =~ ^[0-9]+$ && $MEMORY -gt 0 ]] || die "invalid memory: $MEMORY"
  [[ $SWAP =~ ^[0-9]+$ ]] || die "invalid swap: $SWAP"
  [[ $DISK =~ ^[0-9]+$ && $DISK -gt 0 ]] || die "invalid disk size: $DISK"

  if pct status "$CTID" >/dev/null 2>&1; then
    die "container ID $CTID already exists"
  fi
  ip link show "$BRIDGE" >/dev/null 2>&1 || die "bridge not found: $BRIDGE"
  storage_supports "$STORAGE" rootdir || die "storage does not support container disks: $STORAGE"
  storage_supports "$TEMPLATE_STORAGE" vztmpl || die "storage does not support templates: $TEMPLATE_STORAGE"

  if [[ $ALLOW_USED_IP -eq 0 ]] && ping -c 1 -W 1 "$IP_ADDRESS" >/dev/null 2>&1; then
    die "IPv4 address responds to ping: $IP_ADDRESS (use --allow-used-ip to override)"
  fi
}

resolve_template() {
  TEMPLATE=$(pveam available --section system |
    awk '$2 ~ /^debian-13-standard_.*_amd64[.]tar[.]zst$/ {print $2}' |
    sort -V |
    tail -n 1)
  [[ -n $TEMPLATE ]] || die "no Debian 13 AMD64 standard template is available"
  TEMPLATE_REF="$TEMPLATE_STORAGE:vztmpl/$TEMPLATE"

  if ! pveam list "$TEMPLATE_STORAGE" 2>/dev/null | grep -Fq "/$TEMPLATE"; then
    mutate pveam download "$TEMPLATE_STORAGE" "$TEMPLATE"
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
  mutate "${command[@]}"
  [[ $DRY_RUN -eq 1 ]] || CT_CREATED=1
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
  die "container did not become ready"
}

main() {
  parse_args "$@"
  collect_settings
  preflight
  resolve_template
  create_container
  wait_for_guest
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  trap cleanup EXIT
  trap on_error ERR
  main "$@"
fi
