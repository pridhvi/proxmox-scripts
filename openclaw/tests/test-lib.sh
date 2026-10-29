#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$ROOT/install.sh"

failures=0

check_ok() {
  local name=$1
  shift
  if ! "$@" >/dev/null 2>&1; then
    echo "FAIL: $name"
    failures=$((failures + 1))
  fi
}

check_fail() {
  local name=$1
  shift
  if "$@" >/dev/null 2>&1; then
    echo "FAIL: $name"
    failures=$((failures + 1))
  fi
}

check_ok "accepts a normal CT ID" validate_ctid 204
check_fail "rejects CT ID below Proxmox range" validate_ctid 99
check_fail "rejects nonnumeric CT ID" validate_ctid abc

check_ok "accepts the requested IPv4 address" validate_ipv4 10.10.10.204
check_fail "rejects an out-of-range octet" validate_ipv4 10.10.10.999
check_fail "rejects missing octets" validate_ipv4 10.10.204

check_ok "accepts slash CIDR" validate_cidr 24
check_fail "rejects IPv4 CIDR above 32" validate_cidr 33
check_fail "rejects nonnumeric CIDR" validate_cidr nope

check_ok "accepts the gateway port" validate_port 18789
check_fail "rejects port zero" validate_port 0
check_fail "rejects port above 65535" validate_port 65536

check_ok "accepts a simple hostname" validate_hostname openclaw
check_ok "accepts a dashed hostname" validate_hostname openclaw-agent
check_fail "rejects hostname labels starting with a dash" validate_hostname -openclaw
check_fail "rejects spaces in hostname" validate_hostname "open claw"

token=$(generate_gateway_token)
if [[ ${#token} -lt 43 || "$token" =~ [[:space:]] ]]; then
  echo "FAIL: token must encode at least 32 random bytes without whitespace"
  failures=$((failures + 1))
fi

if [[ $failures -ne 0 ]]; then
  exit 1
fi

echo "PASS: validation helpers"
