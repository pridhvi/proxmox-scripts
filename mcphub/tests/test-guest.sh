#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'cleanup; rm -rf "$TMP"' EXIT
MCPHUB_TESTING=1
source "$ROOT/install.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_file_contains() {
  local file=$1 text=$2 message=$3
  grep -Fq -- "$text" "$file" || fail "$message"
}

WORK_DIR=""
prepare_payloads

GUEST_INSTALLER="$WORK_DIR/install-internal.sh"
COMPOSE_FILE="$WORK_DIR/compose.yml"
UPDATER="$WORK_DIR/update.sh"

[[ -x $GUEST_INSTALLER ]] || fail "guest installer was not created as an executable"
[[ -f $COMPOSE_FILE ]] || fail "Compose file was not created"
[[ -x $UPDATER ]] || fail "updater was not created as an executable"
bash -n "$GUEST_INSTALLER" "$UPDATER" || fail "embedded scripts have invalid Bash syntax"

assert_file_contains "$GUEST_INSTALLER" "ca-certificates curl jq openssl docker.io docker-cli docker-compose" \
  "guest installer does not install the required packages"
assert_file_contains "$GUEST_INSTALLER" "systemctl enable --now docker" \
  "guest installer does not enable Docker"
assert_file_contains "$GUEST_INSTALLER" "install -d -m 0755 /opt/mcphub" \
  "guest installer does not create /opt/mcphub"
assert_file_contains "$GUEST_INSTALLER" "chmod 0600 /opt/mcphub/.env" \
  "guest installer does not protect the secrets file"
assert_file_contains "$GUEST_INSTALLER" 'generate_hex_secret()' \
  "guest installer is missing its secret validation helper"
assert_file_contains "$GUEST_INSTALLER" 'admin_password=$(generate_hex_secret)' \
  "guest installer does not validate the generated admin password"
assert_file_contains "$GUEST_INSTALLER" 'jwt_secret=$(generate_hex_secret)' \
  "guest installer does not validate the generated JWT secret"
assert_file_contains "$GUEST_INSTALLER" 'install -d -m 0700 /opt/mcphub/data' \
  "guest installer does not protect the data directory"
assert_file_contains "$GUEST_INSTALLER" 'printf '\''{"mcpServers":{}}\n'\'' >/opt/mcphub/data/mcp_settings.json' \
  "guest installer does not start with an empty server configuration"
assert_file_contains "$GUEST_INSTALLER" 'MCPHub is already configured; use update instead' \
  "guest installer does not guard against replacing existing credentials"
assert_file_contains "$GUEST_INSTALLER" "install -m 0755 /tmp/mcphub-update /usr/local/sbin/mcphub-update" \
  "guest installer does not install the updater"
assert_file_contains "$GUEST_INSTALLER" "ln -sfn /usr/local/sbin/mcphub-update /usr/bin/update" \
  "guest installer does not expose /usr/bin/update"
assert_file_contains "$GUEST_INSTALLER" "docker compose --env-file .env -f compose.yml up -d" \
  "guest installer does not start the Compose stack"
assert_file_contains "$GUEST_INSTALLER" '/health' \
  "guest installer does not verify readiness"

assert_file_contains "$COMPOSE_FILE" 'image: samanhappy/mcphub:${MCPHUB_VERSION}' \
  "Compose does not use a pinned MCPHub release"
assert_file_contains "$COMPOSE_FILE" 'restart: unless-stopped' \
  "MCPHub does not restart automatically"
assert_file_contains "$COMPOSE_FILE" 'USE_DB: "false"' \
  "file-backed storage is not enabled"
assert_file_contains "$COMPOSE_FILE" 'MCPHUB_SETTING_PATH: /app/data/mcp_settings.json' \
  "settings are not stored in the persistent directory"
assert_file_contains "$COMPOSE_FILE" 'ADMIN_PASSWORD: ${ADMIN_PASSWORD:?set in .env}' \
  "Compose does not require the generated admin password"
assert_file_contains "$COMPOSE_FILE" 'JWT_SECRET: ${JWT_SECRET:?set in .env}' \
  "Compose does not require a persistent JWT secret"
assert_file_contains "$COMPOSE_FILE" '${MCPHUB_PORT:-3000}:3000' \
  "Compose does not publish the configured gateway port"
assert_file_contains "$COMPOSE_FILE" './data:/app/data' \
  "MCPHub data is not persisted"
assert_file_contains "$COMPOSE_FILE" 'npm_cache:/root/.npm' \
  "npm package cache is not persisted"
assert_file_contains "$COMPOSE_FILE" 'uv_cache:/root/.cache/uv' \
  "uv package cache is not persisted"
if grep -Eq 'privileged:|docker.sock|postgres' "$COMPOSE_FILE"; then
  fail "Compose enables unnecessary elevated access or a database"
fi

# Test the root guard separately so mocked updater tests can run without sudo.
assert_file_contains "$UPDATER" '[[ $EUID -eq 0 ]] || die "run as root"' \
  "updater does not require root"
if [[ $EUID -ne 0 ]]; then
  if "$UPDATER" >"$TMP/root-check" 2>&1; then
    fail "updater accepted an unprivileged user"
  fi
  assert_file_contains "$TMP/root-check" 'run as root' "updater did not enforce its root guard"
  sed 's/^\[\[ $EUID -eq 0 \]\] || die "run as root"$/:/' "$UPDATER" >"$TMP/update-test"
  chmod +x "$TMP/update-test"
  UPDATER="$TMP/update-test"
fi

mkdir -p "$TMP/bin"

cat >"$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf 'curl' >>"$TEST_CALLS"
printf ' %q' "$@" >>"$TEST_CALLS"
printf '\n' >>"$TEST_CALLS"
if [[ " $* " == *"api.github.com/repos/samanhappy/mcphub/releases/latest"* ]]; then
  printf '{"tag_name":"%s"}\n' "${TEST_RELEASE_TAG:-}"
  exit 0
fi
[[ ${TEST_HEALTH_FAIL:-0} != 1 && " $* " == *"/health"* ]]
EOF

cat >"$TMP/bin/jq" <<'EOF'
#!/usr/bin/env bash
input=$(cat)
tag=$(printf '%s' "$input" | sed -n 's/.*"tag_name":"\([^"]*\)".*/\1/p')
[[ -n $tag ]] || exit 4
printf '%s\n' "$tag"
EOF

cat >"$TMP/bin/docker" <<'EOF'
#!/usr/bin/env bash
printf 'docker' >>"$TEST_CALLS"
printf ' %q' "$@" >>"$TEST_CALLS"
printf '\n' >>"$TEST_CALLS"
[[ ${TEST_PULL_FAIL:-0} != 1 || ${*: -1} != pull ]]
EOF

cat >"$TMP/bin/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$TMP/bin/"*

setup_update_case() {
  CASE_DIR="$TMP/case"
  rm -rf "$CASE_DIR"
  mkdir -p "$CASE_DIR"
  cat >"$CASE_DIR/.env" <<'EOF'
MCPHUB_VERSION=1.2.3
MCPHUB_PORT=3000
ADMIN_PASSWORD=admin-secret
JWT_SECRET=jwt-secret
EOF
  cp "$COMPOSE_FILE" "$CASE_DIR/compose.yml"
  cp "$CASE_DIR/.env" "$CASE_DIR/original.env"
  : >"$TMP/calls"
}

run_updater() {
  env \
    PATH="$TMP/bin:$PATH" \
    TEST_CALLS="$TMP/calls" \
    TEST_RELEASE_TAG="${TEST_RELEASE_TAG:-}" \
    TEST_HEALTH_FAIL="${TEST_HEALTH_FAIL:-0}" \
    TEST_PULL_FAIL="${TEST_PULL_FAIL:-0}" \
    MCPHUB_DIR="$CASE_DIR" \
    "$UPDATER"
}

setup_update_case
TEST_RELEASE_TAG=not-a-version
if run_updater >/dev/null 2>&1; then
  fail "updater accepted a malformed release tag"
fi
cmp -s "$CASE_DIR/.env" "$CASE_DIR/original.env" || fail "malformed release changed .env"
[[ ! -s $TMP/calls || $(<"$TMP/calls") != *"docker"* ]] || fail "malformed release invoked Docker"

setup_update_case
TEST_RELEASE_TAG=""
if run_updater >/dev/null 2>&1; then
  fail "updater accepted an empty release tag"
fi
cmp -s "$CASE_DIR/.env" "$CASE_DIR/original.env" || fail "empty release changed .env"

setup_update_case
TEST_RELEASE_TAG=v1.2.4
output=$(run_updater) || fail "updater rejected a valid newer release"
expected_env=$'MCPHUB_VERSION=1.2.4\nMCPHUB_PORT=3000\nADMIN_PASSWORD=admin-secret\nJWT_SECRET=jwt-secret'
[[ $(<"$CASE_DIR/.env") == "$expected_env" ]] || fail "updater changed fields other than MCPHUB_VERSION"
[[ $(stat -c '%a' "$CASE_DIR/.env") == 600 ]] || fail "updater did not retain private .env permissions"
[[ $output != *"admin-secret"* && $output != *"jwt-secret"* ]] || \
  fail "updater printed a stored secret"
assert_file_contains "$TMP/calls" 'docker compose --env-file .env -f compose.yml pull' \
  "updater did not pull the pinned images"
assert_file_contains "$TMP/calls" 'docker compose --env-file .env -f compose.yml up -d' \
  "updater did not recreate the stack"
assert_file_contains "$TMP/calls" '/health' \
  "updater did not verify readiness"

setup_update_case
TEST_RELEASE_TAG=v1.2.3
run_updater >/dev/null || fail "updater rejected the currently installed release"
assert_file_contains "$TMP/calls" 'docker compose --env-file .env -f compose.yml pull' \
  "same-version update did not refresh images"
assert_file_contains "$TMP/calls" '/health' \
  "same-version update did not verify readiness"

setup_update_case
printf 'MCPHUB_PORT=3100\n' >>"$CASE_DIR/.env"
cp "$CASE_DIR/.env" "$CASE_DIR/original.env"
if run_updater >/dev/null 2>&1; then
  fail "updater accepted a duplicated port"
fi
cmp -s "$CASE_DIR/.env" "$CASE_DIR/original.env" || fail "invalid configuration changed .env"
if grep -Fq 'docker' "$TMP/calls"; then
  fail "invalid configuration invoked Docker"
fi

setup_update_case
sed -i 's/MCPHUB_PORT=3000/MCPHUB_PORT=3100/' "$CASE_DIR/.env"
run_updater >/dev/null || fail "updater rejected a custom port"
assert_file_contains "$TMP/calls" 'http://127.0.0.1:3100/health' \
  "updater ignored the configured port"

setup_update_case
if TEST_PULL_FAIL=1 run_updater >/dev/null 2>&1; then
  fail "updater ignored a failed image pull"
fi
if grep -Fq 'up -d' "$TMP/calls"; then
  fail "updater recreated the service after a failed image pull"
fi

setup_update_case
if TEST_HEALTH_FAIL=1 run_updater >/dev/null 2>&1; then
  fail "updater reported success for an unhealthy service"
fi

echo "PASS: guest payloads and updater"
