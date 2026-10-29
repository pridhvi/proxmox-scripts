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
  printf "Name Type Status Total Used Available %%\nlocal-lvm lvmthin active 1 0 1 0\n"
elif [[ "$*" == *"vztmpl"* ]]; then
  printf "Name Type Status Total Used Available %%\nlocal dir active 1 0 1 0\n"
else
  exit 1
fi'
  make_stub pveam '
if [[ "${1:-}" == "available" ]]; then
  printf "system debian-13-standard_13.1-2_amd64.tar.zst\n"
elif [[ "${1:-}" == "list" ]]; then
  exit 0
elif [[ "${1:-}" == "download" ]]; then
  echo "pveam $*" >>"$TEST_MUTATIONS"
fi'
  make_stub pct '
if [[ "${1:-}" == "status" ]]; then
  [[ ${TEST_CT_EXISTS:-0} == 1 ]] && exit 0
  exit 1
fi
if [[ "${1:-}" == "push" && ! -f ${3:-} ]]; then
  echo "missing push source: ${3:-}" >&2
  exit 1
fi
echo "pct $*" >>"$TEST_MUTATIONS"'
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
    OPENCLAW_TESTING=1 \
    OPENCLAW_TEST_EUID=0 \
    OPENCLAW_CTID=205 \
    OPENCLAW_IP="${OPENCLAW_IP-10.10.10.204}" \
    OPENCLAW_CIDR=24 \
    OPENCLAW_GATEWAY=10.10.10.1 \
    OPENCLAW_BRIDGE=vmbr0 \
    OPENCLAW_STORAGE="${OPENCLAW_STORAGE:-local-lvm}" \
    OPENCLAW_TEMPLATE_STORAGE="${OPENCLAW_TEMPLATE_STORAGE:-local}" \
    "$@"
}

run_script() {
  local script=$1
  shift
  run_command "$script" "$@"
}

run_installer() {
  run_script "${INSTALL_SCRIPT:-$ROOT/install.sh}" --non-interactive --dry-run "$@"
}

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

setup_stubs
output=$(run_installer)
[[ $output == *"pct create 205"* ]] || fail "dry-run must render pct create"
[[ $output == *"--cores 8"* ]] || fail "default cores missing"
[[ $output == *"--memory 16384"* ]] || fail "default memory missing"
[[ $output == *"--swap 1024"* ]] || fail "default swap missing"
[[ $output == *"local-lvm:32"* ]] || fail "default disk missing"
[[ $output == *"ip=10.10.10.204/24"* ]] || fail "supplied static address missing"
[[ $output == *"--unprivileged 1"* ]] || fail "container must be unprivileged"
[[ $output != *"nesting"* ]] || fail "nesting must stay disabled"
[[ ! -s $TMP/mutations ]] || fail "dry-run executed a mutating command"

setup_stubs
if OPENCLAW_IP=999.10.10.204 run_installer >/dev/null 2>&1; then
  fail "invalid IP was accepted"
fi
[[ ! -s $TMP/mutations ]] || fail "invalid input reached mutation"

setup_stubs
if OPENCLAW_IP= run_installer >/dev/null 2>&1; then
  fail "non-interactive install accepted a missing IP address"
fi
[[ ! -s $TMP/mutations ]] || fail "missing IP reached mutation"

setup_stubs
if TEST_CT_EXISTS=1 run_installer >/dev/null 2>&1; then
  fail "existing CT ID was accepted"
fi
[[ ! -s $TMP/mutations ]] || fail "CT collision reached mutation"

setup_stubs
if TEST_IP_USED=1 run_installer >/dev/null 2>&1; then
  fail "occupied IP was accepted"
fi
[[ ! -s $TMP/mutations ]] || fail "IP collision reached mutation"

setup_stubs
if OPENCLAW_STORAGE=missing run_installer >/dev/null 2>&1; then
  fail "missing root storage was accepted"
fi

setup_stubs
run_command bash -c "$(<"$ROOT/install.sh")" openclaw-installer --non-interactive >/dev/null
grep -Fq "/root/install-openclaw.sh" "$TMP/mutations" || fail "self-contained installer did not push guest installer"
grep -Fq "/root/update-openclaw.sh" "$TMP/mutations" || fail "self-contained installer did not push updater"

echo "PASS: host installer"
