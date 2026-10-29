#!/usr/bin/env bash
set -Eeuo pipefail

DRY_RUN=0
NON_INTERACTIVE=0
ALLOW_USED_IP=0
VERBOSE=0
CT_CREATED=0
TEMP_TOKEN=""
WORK_DIR=""
SPINNER_PID=""
LOG_FILE=${OPENCLAW_LOG_FILE:-}
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
  [[ -z $TEMP_TOKEN ]] || rm -f -- "$TEMP_TOKEN"
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
  if [[ -n ${OPENCLAW_FORCE_TTY+x} ]]; then
    USE_TTY=$OPENCLAW_FORCE_TTY
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
      LOG_FILE="/var/log/openclaw-lxc-install-${CTID:-unknown}.log"
    fi
  fi
  if [[ $LOG_FILE != /dev/null ]]; then
    mkdir -p "$(dirname "$LOG_FILE")"
  fi
  : >"$LOG_FILE"
}

start_spinner() {
  local label=$1
  if [[ $USE_TTY -ne 1 || ${OPENCLAW_TESTING:-0} == 1 ]]; then
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
  if [[ ${USE_TTY:-0} -eq 1 && ${OPENCLAW_TESTING:-0} != 1 ]]; then
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
  value=${value#"${value%%[![:space:]]*}"}
  value=${value%"${value##*[![:space:]]}"}
  printf '%s' "$value"
}

normalize_nameservers() {
  local value
  value=$(trim_whitespace "${1:-}")
  [[ -n $value ]] || return 0
  [[ $value != ,* && $value != *, && $value != *,,* ]] || return 1

  local IFS=,
  local -a entries
  read -r -a entries <<<"$value"
  [[ ${#entries[@]} -ge 1 && ${#entries[@]} -le 2 ]] || return 1

  local entry
  local -a normalized=()
  for entry in "${entries[@]}"; do
    entry=$(trim_whitespace "$entry")
    validate_ipv4 "$entry" || return 1
    normalized+=("$entry")
  done

  printf '%s' "${normalized[0]}"
  if [[ ${#normalized[@]} -eq 2 ]]; then
    printf ' %s' "${normalized[1]}"
  fi
}

generate_gateway_token() {
  od -An -N32 -tx1 /dev/urandom | tr -d ' \n'
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

prompt() {
  local variable=$1 label=$2 default=$3 value
  read -r -p "$label [$default]: " value
  printf -v "$variable" '%s' "${value:-$default}"
}

collect_settings() {
  local suggested_ctid
  suggested_ctid=$(pvesh get /cluster/nextid)

  CTID=${OPENCLAW_CTID:-$suggested_ctid}
  HOSTNAME=${OPENCLAW_HOSTNAME:-openclaw}
  CORES=${OPENCLAW_CORES:-8}
  MEMORY=${OPENCLAW_MEMORY:-16384}
  SWAP=${OPENCLAW_SWAP:-1024}
  DISK=${OPENCLAW_DISK:-32}
  IP_ADDRESS=${OPENCLAW_IP:-}
  CIDR=${OPENCLAW_CIDR:-24}
  GATEWAY=${OPENCLAW_GATEWAY:-10.10.10.1}
  NAMESERVERS_INPUT=${OPENCLAW_NAMESERVERS:-}
  BRIDGE=${OPENCLAW_BRIDGE:-vmbr0}
  STORAGE=${OPENCLAW_STORAGE:-local-zfs}
  TEMPLATE_STORAGE=${OPENCLAW_TEMPLATE_STORAGE:-local}
  GATEWAY_PORT=${OPENCLAW_PORT:-18789}

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
    prompt NAMESERVERS_INPUT "DNS servers (comma-separated, optional)" "$NAMESERVERS_INPUT"
    prompt BRIDGE "Bridge" "$BRIDGE"
    prompt STORAGE "Root-disk storage" "$STORAGE"
    prompt TEMPLATE_STORAGE "Template storage" "$TEMPLATE_STORAGE"
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
  if [[ ${OPENCLAW_TESTING:-0} == 1 ]]; then
    effective_uid=${OPENCLAW_TEST_EUID:-$EUID}
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
  NAMESERVERS=$(normalize_nameservers "$NAMESERVERS_INPUT") || {
    echo "Error: DNS servers must be one or two IPv4 addresses separated by commas" >&2
    return 1
  }
  validate_port "$GATEWAY_PORT" || { echo "Error: invalid gateway port: $GATEWAY_PORT" >&2; return 1; }
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
  local -a create_args=(pct create "$CTID" "$TEMPLATE_REF" \
    --hostname "$HOSTNAME" \
    --cores "$CORES" \
    --memory "$MEMORY" \
    --swap "$SWAP" \
    --rootfs "$STORAGE:$DISK" \
    --net0 "$net" \
    --features nesting=1 \
    --unprivileged 1 \
    --onboot 1 \
    --start 0)
  if [[ -n $NAMESERVERS ]]; then
    create_args+=(--nameserver "$NAMESERVERS")
  fi
  mutate "${create_args[@]}" || return $?
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
  WORK_DIR=$(mktemp -d) || return $?

  cat >"$WORK_DIR/install-internal.sh" <<'OPENCLAW_GUEST_INSTALLER' || return $?
#!/usr/bin/env bash
set -Eeuo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

PORT=${OPENCLAW_GATEWAY_PORT:-18789}
TOKEN_FILE=${OPENCLAW_TOKEN_FILE:-/root/openclaw-token}
OPENCLAW_USER=openclaw
OPENCLAW_HOME=/home/openclaw
NPM_PREFIX=$OPENCLAW_HOME/.npm-global
OPENCLAW_BIN=/usr/local/bin/openclaw
WORK_DIR=""

cleanup() {
  [[ -z $WORK_DIR ]] || rm -rf "$WORK_DIR"
}
trap cleanup EXIT

die() {
  echo "Error: $*" >&2
  exit 1
}

[[ $EUID -eq 0 ]] || die "run inside the LXC as root"
[[ -s $TOKEN_FILE ]] || die "gateway token file is missing or empty"

if [[ ${OPENCLAW_DRY_RUN:-0} == 1 ]]; then
  cat <<'EOF'
create user openclaw
install Node.js 26 with checksum verification
install openclaw@latest in the openclaw user npm prefix
install Google Chrome
openclaw config set gateway.mode local
openclaw config set gateway.bind lan
openclaw config set gateway.auth.mode token
openclaw config set browser.noSandbox true
loginctl enable-linger openclaw
openclaw gateway install
openclaw gateway start
verify headless browser
install /usr/bin/update
EOF
  exit 0
fi

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  ca-certificates curl gnupg jq libatomic1 xz-utils

if ! id -u "$OPENCLAW_USER" >/dev/null 2>&1; then
  useradd --create-home --shell /bin/bash --user-group "$OPENCLAW_USER"
fi
passwd -l "$OPENCLAW_USER" >/dev/null 2>&1 || true

install_node() {
  local deb_arch node_arch archive version major minor patch
  deb_arch=$(dpkg --print-architecture)
  case "$deb_arch" in
    amd64) node_arch=x64 ;;
    arm64) node_arch=arm64 ;;
    *) die "unsupported architecture for Node.js: $deb_arch" ;;
  esac

  WORK_DIR=$(mktemp -d)
  curl -fsSL https://nodejs.org/dist/latest-v26.x/SHASUMS256.txt -o "$WORK_DIR/SHASUMS256.txt"
  archive=$(awk -v arch="$node_arch" '$2 ~ "node-v26.*-linux-" arch "[.]tar[.]xz$" {print $2}' "$WORK_DIR/SHASUMS256.txt" | sort -V | tail -n 1)
  [[ -n $archive ]] || die "could not resolve the current Node.js 26 archive"
  curl -fsSL "https://nodejs.org/dist/latest-v26.x/$archive" -o "$WORK_DIR/$archive"
  grep -F "  $archive" "$WORK_DIR/SHASUMS256.txt" >"$WORK_DIR/CHECKSUM"
  (cd "$WORK_DIR" && sha256sum -c CHECKSUM)
  tar -xJf "$WORK_DIR/$archive" -C /usr/local --strip-components=1

  version=$(node --version | sed 's/^v//')
  IFS=. read -r major minor patch <<<"$version"
  [[ $major -eq 26 ]] || die "Node.js 26 is required, found $version"
  if ((minor < 12 || (minor == 12 && patch < 1))); then
    die "Node.js 26.12.1 or newer is required, found $version"
  fi
}

install_node

install -d -m 0755 -o "$OPENCLAW_USER" -g "$OPENCLAW_USER" "$NPM_PREFIX"

as_openclaw() {
  local uid
  uid=$(id -u "$OPENCLAW_USER")
  (
    cd "$OPENCLAW_HOME"
    runuser -u "$OPENCLAW_USER" -- env \
      HOME="$OPENCLAW_HOME" \
      USER="$OPENCLAW_USER" \
      LOGNAME="$OPENCLAW_USER" \
      NPM_CONFIG_PREFIX="$NPM_PREFIX" \
      PATH="$NPM_PREFIX/bin:/usr/local/bin:/usr/bin:/bin" \
      XDG_RUNTIME_DIR="/run/user/$uid" \
      DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" \
      "$@"
  )
}

as_openclaw npm install -g openclaw@latest --allow-scripts=openclaw
ln -sfn "$NPM_PREFIX/bin/openclaw" "$OPENCLAW_BIN"

install_chrome() {
  local deb_arch key_file
  deb_arch=$(dpkg --print-architecture)
  if [[ $deb_arch == amd64 ]]; then
    key_file=$(mktemp)
    curl -fsSL https://dl.google.com/linux/linux_signing_key.pub -o "$key_file"
    gpg --dearmor --yes --output /usr/share/keyrings/google-chrome.gpg "$key_file"
    rm -f "$key_file"
    printf '%s\n' 'deb [arch=amd64 signed-by=/usr/share/keyrings/google-chrome.gpg] https://dl.google.com/linux/chrome/deb/ stable main' \
      >/etc/apt/sources.list.d/google-chrome.list
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y google-chrome-stable
    CHROME_BIN=/usr/bin/google-chrome-stable
  else
    DEBIAN_FRONTEND=noninteractive apt-get install -y chromium
    CHROME_BIN=/usr/bin/chromium
  fi
}

install_chrome

install -d -m 0700 -o "$OPENCLAW_USER" -g "$OPENCLAW_USER" "$OPENCLAW_HOME/.openclaw"
token=$(tr -d '\r\n' <"$TOKEN_FILE")
[[ $token =~ ^[A-Za-z0-9_-]{32,}$ ]] || die "gateway token has an invalid format"
umask 077
printf 'OPENCLAW_GATEWAY_TOKEN=%s\n' "$token" >"$OPENCLAW_HOME/.openclaw/.env"
chown "$OPENCLAW_USER:$OPENCLAW_USER" "$OPENCLAW_HOME/.openclaw/.env"
unset token
rm -f "$TOKEN_FILE"

as_openclaw "$OPENCLAW_BIN" config set gateway.mode local
as_openclaw "$OPENCLAW_BIN" config set gateway.bind lan
as_openclaw "$OPENCLAW_BIN" config set gateway.port "$PORT" --strict-json
as_openclaw "$OPENCLAW_BIN" config set gateway.auth.mode token
as_openclaw "$OPENCLAW_BIN" config set browser.executablePath "$CHROME_BIN"
as_openclaw "$OPENCLAW_BIN" config set browser.headless true --strict-json
as_openclaw "$OPENCLAW_BIN" config validate

loginctl enable-linger "$OPENCLAW_USER"
uid=$(id -u "$OPENCLAW_USER")
systemctl start "user@$uid.service"

start_openclaw() {
  as_openclaw "$OPENCLAW_BIN" config set browser.noSandbox true --strict-json
  as_openclaw "$OPENCLAW_BIN" gateway install --port "$PORT"
  as_openclaw "$OPENCLAW_BIN" gateway start
  as_openclaw "$OPENCLAW_BIN" browser start --headless
}

start_openclaw

install -m 0755 /root/update-openclaw.sh /usr/local/sbin/openclaw-update
ln -sfn /usr/local/sbin/openclaw-update /usr/bin/update

as_openclaw "$OPENCLAW_BIN" gateway status --deep
as_openclaw "$OPENCLAW_BIN" browser --json status
curl -fsS "http://127.0.0.1:$PORT/" -o /dev/null

rm -f /root/install-openclaw.sh /root/update-openclaw.sh
echo "OpenClaw installation complete."
OPENCLAW_GUEST_INSTALLER

  cat >"$WORK_DIR/update.sh" <<'OPENCLAW_UPDATER' || return $?
#!/usr/bin/env bash
set -Eeuo pipefail

OPENCLAW_USER=${OPENCLAW_USER:-openclaw}
OPENCLAW_HOME=${OPENCLAW_HOME:-/home/openclaw}
NPM_PREFIX=$OPENCLAW_HOME/.npm-global
OPENCLAW_BIN=${OPENCLAW_BIN:-openclaw}
PORT=${OPENCLAW_GATEWAY_PORT:-18789}

[[ $EUID -eq 0 || ${OPENCLAW_TESTING:-0} == 1 ]] || {
  echo "Run update as root." >&2
  exit 1
}

as_openclaw() {
  local uid
  (
    cd "$OPENCLAW_HOME"
    if [[ ${OPENCLAW_TESTING:-0} == 1 ]]; then
      "$@"
    else
      uid=$(id -u "$OPENCLAW_USER")
      runuser -u "$OPENCLAW_USER" -- env \
        HOME="$OPENCLAW_HOME" \
        USER="$OPENCLAW_USER" \
        LOGNAME="$OPENCLAW_USER" \
        NPM_CONFIG_PREFIX="$NPM_PREFIX" \
        PATH="$NPM_PREFIX/bin:/usr/local/bin:/usr/bin:/bin" \
        XDG_RUNTIME_DIR="/run/user/$uid" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" \
        "$@"
    fi
  )
}

as_openclaw "$OPENCLAW_BIN" update
as_openclaw "$OPENCLAW_BIN" doctor --fix
as_openclaw "$OPENCLAW_BIN" gateway status --deep
curl -fsS "http://127.0.0.1:$PORT/" -o /dev/null
as_openclaw "$OPENCLAW_BIN" browser --json status

echo "OpenClaw updated successfully."
OPENCLAW_UPDATER

  chmod 700 "$WORK_DIR/install-internal.sh" "$WORK_DIR/update.sh" || return $?
}

install_guest() {
  prepare_payloads || return $?
  if [[ $DRY_RUN -eq 1 ]]; then
    mutate pct push "$CTID" "$WORK_DIR/install-internal.sh" /root/install-openclaw.sh --perms 0755 || return $?
    mutate pct push "$CTID" "$WORK_DIR/update.sh" /root/update-openclaw.sh --perms 0755 || return $?
    mutate pct exec "$CTID" -- env OPENCLAW_GATEWAY_PORT="$GATEWAY_PORT" OPENCLAW_TOKEN_FILE=/root/openclaw-token bash /root/install-openclaw.sh || return $?
    return 0
  fi

  TEMP_TOKEN=$(mktemp) || return $?
  chmod 600 "$TEMP_TOKEN" || return $?
  generate_gateway_token >"$TEMP_TOKEN" || return $?

  pct push "$CTID" "$WORK_DIR/install-internal.sh" /root/install-openclaw.sh --perms 0755 || return $?
  pct push "$CTID" "$WORK_DIR/update.sh" /root/update-openclaw.sh --perms 0755 || return $?
  pct push "$CTID" "$TEMP_TOKEN" /root/openclaw-token --perms 0600 || return $?
  pct exec "$CTID" -- env \
    OPENCLAW_GATEWAY_PORT="$GATEWAY_PORT" \
    OPENCLAW_TOKEN_FILE=/root/openclaw-token \
    bash /root/install-openclaw.sh
}

verify_installation() {
  mutate pct exec "$CTID" -- curl -fsS "http://127.0.0.1:$GATEWAY_PORT/" -o /dev/null
}

print_summary() {
  if [[ $DRY_RUN -eq 1 ]]; then
    printf '\nDry run complete. No changes were made.\n'
    return 0
  fi
  printf '\n%bOpenClaw is installed%b\n' "$GREEN" "$RESET"
  printf 'Gateway: http://%s:%s/\n' "$IP_ADDRESS" "$GATEWAY_PORT"
  printf 'Console: pct enter %s\n' "$CTID"
  printf 'Onboard: runuser -u openclaw -- env HOME=/home/openclaw /usr/local/bin/openclaw onboard\n'
}

main() {
  parse_args "$@"
  collect_settings
  setup_output
  printf '\n%bOpenClaw LXC%b\n' "$CYAN" "$RESET"
  printf '%bContainer %s · %s/%s · %s%b\n\n' "$CYAN" "$CTID" "$IP_ADDRESS" "$CIDR" "$STORAGE" "$RESET"
  run_step "Validating Proxmox host" preflight || return $?
  run_step "Preparing Debian 13 template" resolve_template || return $?
  run_step "Creating container $CTID" create_container || return $?
  run_step "Starting container $CTID" start_container || return $?
  run_step "Waiting for container" wait_for_guest || return $?
  run_step "Installing OpenClaw" install_guest || return $?
  run_step "Verifying OpenClaw" verify_installation || return $?
  print_summary
}

if [[ -z ${BASH_SOURCE[0]:-} || ${BASH_SOURCE[0]} == "$0" ]]; then
  trap cleanup EXIT
  trap on_error ERR
  main "$@"
fi
