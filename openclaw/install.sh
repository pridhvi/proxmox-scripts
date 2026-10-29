#!/usr/bin/env bash
set -Eeuo pipefail

DRY_RUN=0
NON_INTERACTIVE=0
ALLOW_USED_IP=0
CT_CREATED=0
TEMP_TOKEN=""
WORK_DIR=""

usage() {
  echo "Usage: $0 [--dry-run] [--non-interactive] [--allow-used-ip]"
}

die() {
  echo "Error: $*" >&2
  exit 1
}

cleanup() {
  [[ -z $TEMP_TOKEN ]] || rm -f "$TEMP_TOKEN"
  [[ -z $WORK_DIR ]] || rm -rf "$WORK_DIR"
}

on_error() {
  local code=$?
  if [[ $CT_CREATED -eq 1 ]]; then
    echo "Installation stopped. Container $CTID was kept for inspection." >&2
    echo "Open its console with: pct enter $CTID" >&2
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
  NAMESERVERS=$(normalize_nameservers "$NAMESERVERS_INPUT") || die "invalid DNS servers: $NAMESERVERS_INPUT"
  validate_port "$GATEWAY_PORT" || die "invalid gateway port: $GATEWAY_PORT"
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
  mutate "${create_args[@]}"
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

prepare_payloads() {
  [[ -z $WORK_DIR ]] || return 0
  WORK_DIR=$(mktemp -d)

  cat >"$WORK_DIR/install-internal.sh" <<'OPENCLAW_GUEST_INSTALLER'
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

  cat >"$WORK_DIR/update.sh" <<'OPENCLAW_UPDATER'
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

  chmod 700 "$WORK_DIR/install-internal.sh" "$WORK_DIR/update.sh"
}

install_guest() {
  if [[ $DRY_RUN -eq 1 ]]; then
    mutate pct push "$CTID" "$WORK_DIR/install-internal.sh" /root/install-openclaw.sh --perms 0755
    mutate pct push "$CTID" "$WORK_DIR/update.sh" /root/update-openclaw.sh --perms 0755
    mutate pct exec "$CTID" -- env OPENCLAW_GATEWAY_PORT="$GATEWAY_PORT" OPENCLAW_TOKEN_FILE=/root/openclaw-token bash /root/install-openclaw.sh
    return
  fi

  TEMP_TOKEN=$(mktemp)
  chmod 600 "$TEMP_TOKEN"
  generate_gateway_token >"$TEMP_TOKEN"

  pct push "$CTID" "$WORK_DIR/install-internal.sh" /root/install-openclaw.sh --perms 0755
  pct push "$CTID" "$WORK_DIR/update.sh" /root/update-openclaw.sh --perms 0755
  pct push "$CTID" "$TEMP_TOKEN" /root/openclaw-token --perms 0600
  pct exec "$CTID" -- env \
    OPENCLAW_GATEWAY_PORT="$GATEWAY_PORT" \
    OPENCLAW_TOKEN_FILE=/root/openclaw-token \
    bash /root/install-openclaw.sh
}

verify_installation() {
  mutate pct exec "$CTID" -- curl -fsS "http://127.0.0.1:$GATEWAY_PORT/" -o /dev/null
}

main() {
  trap cleanup EXIT
  trap on_error ERR
  parse_args "$@"

  collect_settings
  preflight
  prepare_payloads
  resolve_template

  if [[ $DRY_RUN -eq 1 ]]; then
    echo "Dry run:"
  fi
  create_container
  wait_for_guest
  install_guest
  verify_installation

  if [[ $DRY_RUN -eq 0 ]]; then
    echo "OpenClaw is installed at http://$IP_ADDRESS:$GATEWAY_PORT/"
    echo "Enter the container with: pct enter $CTID"
    echo "Finish setup with: runuser -u openclaw -- env HOME=/home/openclaw /usr/local/bin/openclaw onboard"
  fi
}

if [[ -z ${BASH_SOURCE[0]:-} || ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
