#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

make_stub() {
  local name=$1
  shift
  {
    echo '#!/usr/bin/env bash'
    printf '%s\n' "$@"
  } >"$TMP/bin/$name"
  chmod +x "$TMP/bin/$name"
}

setup_stubs() {
  rm -rf "$TMP/bin"
  mkdir -p "$TMP/bin"
  : >"$TMP/mutations"

  make_stub pvesh 'echo 205'
  make_stub pvesm '
if [[ "$*" == *"rootdir"* ]]; then
  printf "Name Type Status Total Used Available %%\nlocal-zfs zfspool active 1 0 1 0\n"
elif [[ "$*" == *"vztmpl"* ]]; then
  printf "Name Type Status Total Used Available %%\nlocal dir active 1 0 1 0\n"
else
  exit 1
fi'
  make_stub pveam '
if [[ "${1:-}" == "available" ]]; then
  printf "system debian-13-standard_13.6-1_amd64.tar.zst\nsystem debian-13-standard_13.6-1_arm64.tar.zst\n"
elif [[ "${1:-}" == "list" ]]; then
  exit 1
elif [[ "${1:-}" == "download" ]]; then
  printf "pveam" >>"$TEST_MUTATIONS"
  printf " %q" "$@" >>"$TEST_MUTATIONS"
  printf "\n" >>"$TEST_MUTATIONS"
fi'
  make_stub pct '
if [[ "${1:-}" == "status" ]]; then
  [[ ${TEST_CT_EXISTS:-0} == 1 ]] && exit 0
  exit 1
fi
if [[ "${1:-}" == "exec" && "${3:-}" == "--" && "${4:-}" == "true" ]]; then
  exit 0
fi
printf "pct" >>"$TEST_MUTATIONS"
printf " %q" "$@" >>"$TEST_MUTATIONS"
printf "\n" >>"$TEST_MUTATIONS"'
  make_stub ip '
if [[ "${1:-}" == "link" ]]; then
  [[ ${TEST_BRIDGE_MISSING:-0} == 1 ]] && exit 1
  exit 0
fi
exit 0'
  make_stub ping '[[ ${TEST_IP_USED:-0} == 1 ]]'
  make_stub sleep 'exit 0'
}

run_command() {
  env \
    PATH="$TMP/bin:$PATH" \
    TEST_MUTATIONS="$TMP/mutations" \
    MCPHUB_TESTING=1 \
    MCPHUB_TEST_EUID=0 \
    MCPHUB_CTID=205 \
    MCPHUB_IP="${MCPHUB_IP-10.10.10.205}" \
    MCPHUB_CIDR=24 \
    MCPHUB_GATEWAY=10.10.10.1 \
    MCPHUB_BRIDGE=vmbr0 \
    MCPHUB_STORAGE="${MCPHUB_STORAGE:-local-zfs}" \
    MCPHUB_TEMPLATE_STORAGE="${MCPHUB_TEMPLATE_STORAGE:-local}" \
    MCPHUB_NAMESERVERS="${MCPHUB_NAMESERVERS-10.10.10.2,10.10.10.3}" \
    "$@"
}

run_installer() {
  run_command "$ROOT/install.sh" --non-interactive --dry-run "$@"
}

run_downloaded_installer() {
  local script
  script=$(<"$ROOT/install.sh")
  run_command bash -c "$script" -- --non-interactive --dry-run "$@"
}

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

setup_stubs
output=$(run_installer)
[[ $output == *"pct create 205"* ]] || fail "dry-run must render pct create"
[[ $output == *"local:vztmpl/debian-13-standard_13.6-1_amd64.tar.zst"* ]] || fail "AMD64 template was not selected"
[[ $output != *"debian-13-standard_13.6-1_arm64.tar.zst"* ]] || fail "ARM64 template was selected"
[[ $output == *"--cores 6"* ]] || fail "default core count is missing"
[[ $output == *"--memory 8192"* ]] || fail "default memory is missing"
[[ $output == *"--swap 1024"* ]] || fail "default swap is missing"
[[ $output == *"local-zfs:32"* ]] || fail "default disk is missing"
[[ $output == *"ip=10.10.10.205/24"* ]] || fail "static IP is missing"
[[ $output == *"--unprivileged 1"* ]] || fail "container must be unprivileged"
[[ $output == *"--features nesting=1\,keyctl=1"* ]] || fail "Docker LXC features are missing"
[[ $output == *"--nameserver 10.10.10.2\\ 10.10.10.3"* ]] || fail "two DNS servers were not normalized for Proxmox"
[[ $output == *"pct push 205"*"mcphub-compose.yml"* ]] || fail "Compose payload was not pushed"
[[ $output == *"pct exec 205 -- env MCPHUB_PORT=3000 /root/install-mcphub.sh"* ]] || \
  fail "guest installer was not invoked with the configured port"
[[ $output != *"ADMIN_PASSWORD="* && $output != *"JWT_SECRET="* ]] || fail "dry-run output exposed credentials"
[[ ! -s $TMP/mutations ]] || fail "dry-run executed a mutating command"

setup_stubs
output=$(MCPHUB_PORT=3100 MCPHUB_CORES=4 MCPHUB_MEMORY=8192 MCPHUB_DISK=24 run_installer)
[[ $output == *"--cores 4"* && $output == *"--memory 8192"* && $output == *"local-zfs:24"* ]] || \
  fail "custom resource settings were not applied"
[[ $output == *"MCPHUB_PORT=3100 /root/install-mcphub.sh"* ]] || fail "custom port was not passed to the guest"
[[ ! -s $TMP/mutations ]] || fail "custom-settings dry-run executed a mutating command"

setup_stubs
if MCPHUB_PORT=65536 run_installer >/dev/null 2>&1; then
  fail "invalid port was accepted"
fi
[[ ! -s $TMP/mutations ]] || fail "invalid port reached mutation"

setup_stubs
if ! output=$(run_downloaded_installer 2>&1); then
  fail "download-and-execute invocation failed: $output"
fi
[[ $output == *"pct create 205"* ]] || fail "download-and-execute invocation did not run the installer"
[[ ! -s $TMP/mutations ]] || fail "download-and-execute dry-run executed a mutating command"

setup_stubs
if MCPHUB_IP= run_installer >/dev/null 2>&1; then
  fail "missing static IP was accepted"
fi
[[ ! -s $TMP/mutations ]] || fail "missing IP reached mutation"

setup_stubs
if TEST_IP_USED=1 run_installer >/dev/null 2>&1; then
  fail "occupied static IP was accepted"
fi
[[ ! -s $TMP/mutations ]] || fail "occupied IP reached mutation"

setup_stubs
if TEST_CT_EXISTS=1 run_installer >/dev/null 2>&1; then
  fail "existing CT ID was accepted"
fi
[[ ! -s $TMP/mutations ]] || fail "CT collision reached mutation"

setup_stubs
if MCPHUB_STORAGE=missing run_installer >/dev/null 2>&1; then
  fail "unsupported root storage was accepted"
fi
[[ ! -s $TMP/mutations ]] || fail "unsupported storage reached mutation"

setup_stubs
if MCPHUB_NAMESERVERS=10.10.10.999 run_installer >/dev/null 2>&1; then
  fail "malformed DNS server was accepted"
fi
[[ ! -s $TMP/mutations ]] || fail "malformed DNS reached mutation"

setup_stubs
if MCPHUB_NAMESERVERS=10.10.10.2,10.10.10.3,10.10.10.4 run_installer >/dev/null 2>&1; then
  fail "more than two DNS servers were accepted"
fi
[[ ! -s $TMP/mutations ]] || fail "excess DNS servers reached mutation"

echo "PASS: host installer"
