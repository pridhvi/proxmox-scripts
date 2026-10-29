#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
OPENCLAW_TESTING=1
source "$ROOT/install.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

reset_output() {
  LOG_FILE="$TMP/install.log"
  VERBOSE=0
  DRY_RUN=0
  NO_COLOR=1
  OPENCLAW_FORCE_TTY=0
  setup_output
}

status=0
short_verbose=$(bash -c 'source "$1"; parse_args -v; printf "%s" "$VERBOSE"' _ "$ROOT/install.sh" 2>/dev/null) || status=$?
[[ $status -eq 0 && $short_verbose == 1 ]] || fail "-v did not enable verbose output"

status=0
long_verbose=$(bash -c 'source "$1"; parse_args --verbose; printf "%s" "$VERBOSE"' _ "$ROOT/install.sh" 2>/dev/null) || status=$?
[[ $status -eq 0 && $long_verbose == 1 ]] || fail "--verbose did not enable verbose output"

reset_output
output=$(run_step "Quiet work" bash -c 'echo quiet-detail')
[[ $output == *"Quiet work"* ]] || fail "quiet mode omitted the step label"
[[ $output != *"quiet-detail"* ]] || fail "quiet mode leaked command output"
grep -Fq "quiet-detail" "$LOG_FILE" || fail "quiet mode did not save command output"

reset_output
VERBOSE=1
output=$(run_step "Verbose work" bash -c 'echo verbose-detail')
[[ $output == *"verbose-detail"* ]] || fail "verbose mode hid command output"
grep -Fq "verbose-detail" "$LOG_FILE" || fail "verbose mode did not save command output"

reset_output
status=0
run_step "Failing work" bash -c 'echo failure-detail; exit 23' >/dev/null 2>&1 || status=$?
[[ $status -eq 23 ]] || fail "failed step returned $status instead of 23"
grep -Fq "failure-detail" "$LOG_FILE" || fail "failed step did not retain command output"

reset_output
OPENCLAW_FORCE_TTY=1
setup_output
output=$(run_step "No color" true)
[[ $output != *$'\033['* ]] || fail "NO_COLOR output contained ANSI escapes"

reset_output
unset NO_COLOR
OPENCLAW_FORCE_TTY=0
setup_output
output=$(run_step "Non-TTY" true)
[[ $output != *$'\033['* ]] || fail "non-TTY output contained ANSI escapes"

reset_output
unset NO_COLOR
OPENCLAW_FORCE_TTY=1
setup_output
output=$(run_step "Colored success" true)
[[ $output == *$'\033[32m✓\033[0m'* ]] || fail "forced-TTY success did not render a green check"

echo "PASS: installer output"
