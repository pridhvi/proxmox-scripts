#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
source "$ROOT/install.sh"
prepare_payloads
trap 'cleanup; rm -rf "$TMP"' EXIT

GUEST_INSTALLER=$WORK_DIR/install-internal.sh
UPDATER=$WORK_DIR/update.sh

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

grep -Fq 'libatomic1' "$GUEST_INSTALLER" || fail "Node.js runtime dependency libatomic1 is missing"
grep -Fq 'export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin' "$GUEST_INSTALLER" || fail "guest PATH does not include /usr/local/bin"

TOKEN=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
printf '%s\n' "$TOKEN" >"$TMP/token"
chmod 600 "$TMP/token"

output=$(OPENCLAW_DRY_RUN=1 OPENCLAW_TOKEN_FILE="$TMP/token" "$GUEST_INSTALLER")
[[ $output == *"Node.js 26"* ]] || fail "Node.js 26 step missing"
[[ $output == *"openclaw@latest"* ]] || fail "OpenClaw install step missing"
[[ $output == *"Google Chrome"* ]] || fail "Chrome install step missing"
[[ $output == *"gateway.mode local"* ]] || fail "local gateway mode missing"
[[ $output == *"gateway.bind lan"* ]] || fail "LAN bind missing"
[[ $output == *"gateway.auth.mode token"* ]] || fail "token auth missing"
[[ $output == *"loginctl enable-linger openclaw"* ]] || fail "linger step missing"
[[ $output == *"openclaw gateway install"* ]] || fail "managed service install missing"
[[ $output == *"install /usr/bin/update"* ]] || fail "local updater install missing"
[[ $output != *"$TOKEN"* ]] || fail "gateway token leaked"

mkdir -p "$TMP/bin"
cat >"$TMP/bin/openclaw" <<'STUB'
#!/usr/bin/env bash
echo "openclaw $*" >>"$TEST_LOG"
if [[ ${TEST_FAIL_UPDATE:-0} == 1 && ${1:-} == update ]]; then
  exit 42
fi
STUB
cat >"$TMP/bin/curl" <<'STUB'
#!/usr/bin/env bash
echo "curl $*" >>"$TEST_LOG"
STUB
chmod +x "$TMP/bin/openclaw" "$TMP/bin/curl"

: >"$TMP/update.log"
PATH="$TMP/bin:$PATH" TEST_LOG="$TMP/update.log" OPENCLAW_TESTING=1 "$UPDATER"
grep -Fxq "openclaw update" "$TMP/update.log" || fail "updater did not call openclaw update"
grep -Fxq "openclaw doctor --fix" "$TMP/update.log" || fail "updater did not run Doctor"
grep -Fxq "openclaw gateway status --deep" "$TMP/update.log" || fail "updater did not check gateway"
grep -Fxq "openclaw browser --json status" "$TMP/update.log" || fail "updater did not check browser"

: >"$TMP/update.log"
if PATH="$TMP/bin:$PATH" TEST_LOG="$TMP/update.log" TEST_FAIL_UPDATE=1 OPENCLAW_TESTING=1 "$UPDATER" >/dev/null 2>&1; then
  fail "update failure was swallowed"
fi
if grep -q "doctor" "$TMP/update.log"; then
  fail "updater continued after failed package update"
fi

echo "PASS: guest installer and updater"
