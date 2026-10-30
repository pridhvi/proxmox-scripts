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

check_output() {
  local name=$1 expected=$2
  shift 2
  local actual
  if ! actual=$("$@"); then
    echo "FAIL: $name"
    failures=$((failures + 1))
  elif [[ $actual != "$expected" ]]; then
    echo "FAIL: $name (expected '$expected', got '$actual')"
    failures=$((failures + 1))
  fi
}

check_ok "accepts a normal CT ID" validate_ctid 205
check_fail "rejects CT ID below Proxmox range" validate_ctid 99
check_fail "rejects nonnumeric CT ID" validate_ctid abc

check_ok "accepts a normal IPv4 address" validate_ipv4 10.10.10.205
check_fail "rejects an out-of-range IPv4 octet" validate_ipv4 10.10.10.999
check_fail "rejects an incomplete IPv4 address" validate_ipv4 10.10.205

check_ok "accepts an IPv4 CIDR" validate_cidr 24
check_fail "rejects an IPv4 CIDR above 32" validate_cidr 33
check_fail "rejects a nonnumeric CIDR" validate_cidr nope

check_ok "accepts the MCPHub port" validate_port 3000
check_fail "rejects port zero" validate_port 0
check_fail "rejects ports above 65535" validate_port 65536

check_ok "accepts a simple hostname" validate_hostname mcphub
check_ok "accepts a dashed hostname" validate_hostname mcphub-gateway
check_fail "rejects hostname labels starting with a dash" validate_hostname -mcphub
check_fail "rejects spaces in a hostname" validate_hostname "lite llm"

check_output "accepts no explicit DNS servers" "" normalize_nameservers ""
check_output "normalizes one DNS server" "10.10.10.2" normalize_nameservers "10.10.10.2"
check_output "normalizes two comma-separated DNS servers" "10.10.10.2 10.10.10.3" normalize_nameservers "10.10.10.2, 10.10.10.3"
check_fail "rejects an empty DNS entry" normalize_nameservers "10.10.10.2,"
check_fail "rejects duplicate DNS servers" normalize_nameservers "10.10.10.2,10.10.10.2"
check_fail "rejects an invalid DNS server" normalize_nameservers "10.10.10.999"
check_fail "rejects more than two DNS servers" normalize_nameservers "10.10.10.2,10.10.10.3,10.10.10.4"

if [[ $failures -ne 0 ]]; then
  exit 1
fi

echo "PASS: validation helpers"
