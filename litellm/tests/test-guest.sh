#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
LITELLM_TESTING=1
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
assert_file_contains "$GUEST_INSTALLER" "install -d -m 0755 /opt/litellm" \
  "guest installer does not create /opt/litellm"
assert_file_contains "$GUEST_INSTALLER" "chmod 0600 /opt/litellm/.env" \
  "guest installer does not protect the secrets file"
assert_file_contains "$GUEST_INSTALLER" 'generate_hex_secret()' \
  "guest installer is missing its secret validation helper"
assert_file_contains "$GUEST_INSTALLER" 'master_key=$(generate_hex_secret)' \
  "guest installer does not validate the generated master key"
assert_file_contains "$GUEST_INSTALLER" 'salt_key=$(generate_hex_secret)' \
  "guest installer does not validate the generated salt key"
assert_file_contains "$GUEST_INSTALLER" 'postgres_password=$(generate_hex_secret)' \
  "guest installer does not validate the generated database password"
assert_file_contains "$GUEST_INSTALLER" "install -m 0755 /tmp/litellm-update /usr/local/sbin/litellm-update" \
  "guest installer does not install the updater"
assert_file_contains "$GUEST_INSTALLER" "ln -sfn /usr/local/sbin/litellm-update /usr/bin/update" \
  "guest installer does not expose /usr/bin/update"
assert_file_contains "$GUEST_INSTALLER" "docker compose --env-file .env -f compose.yml up -d" \
  "guest installer does not start the Compose stack"
assert_file_contains "$GUEST_INSTALLER" '/health/readiness' \
  "guest installer does not verify readiness"

assert_file_contains "$COMPOSE_FILE" 'image: ghcr.io/berriai/litellm:${LITELLM_VERSION}' \
  "Compose does not use a pinned LiteLLM release"
assert_file_contains "$COMPOSE_FILE" 'image: postgres:16' \
  "Compose does not use PostgreSQL 16"
assert_file_contains "$COMPOSE_FILE" 'restart: unless-stopped' \
  "Compose services do not restart automatically"
assert_file_contains "$COMPOSE_FILE" 'condition: service_healthy' \
  "LiteLLM does not wait for a healthy database"
assert_file_contains "$COMPOSE_FILE" 'STORE_MODEL_IN_DB: "True"' \
  "database-backed model management is not enabled"
assert_file_contains "$COMPOSE_FILE" '${LITELLM_PORT:-4000}:4000' \
  "Compose does not publish the configured gateway port"
assert_file_contains "$COMPOSE_FILE" 'postgres_data:/var/lib/postgresql/data' \
  "PostgreSQL does not use a persistent named volume"

mkdir -p "$TMP/bin"

cat >"$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf 'curl' >>"$TEST_CALLS"
printf ' %q' "$@" >>"$TEST_CALLS"
printf '\n' >>"$TEST_CALLS"
if [[ " $* " == *"api.github.com/repos/BerriAI/litellm/releases/latest"* ]]; then
  printf '{"tag_name":"%s"}\n' "${TEST_RELEASE_TAG:-}"
  exit 0
fi
[[ " $* " == *"/health/readiness"* ]]
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
LITELLM_VERSION=v1.2.3
LITELLM_PORT=4000
LITELLM_MASTER_KEY=sk-master-secret
LITELLM_SALT_KEY=sk-salt-secret
POSTGRES_PASSWORD=database-secret
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
    LITELLM_DIR="$CASE_DIR" \
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
expected_env=$'LITELLM_VERSION=v1.2.4\nLITELLM_PORT=4000\nLITELLM_MASTER_KEY=sk-master-secret\nLITELLM_SALT_KEY=sk-salt-secret\nPOSTGRES_PASSWORD=database-secret'
[[ $(<"$CASE_DIR/.env") == "$expected_env" ]] || fail "updater changed fields other than LITELLM_VERSION"
[[ $(stat -c '%a' "$CASE_DIR/.env") == 600 ]] || fail "updater did not retain private .env permissions"
[[ $output != *"sk-master-secret"* && $output != *"sk-salt-secret"* && $output != *"database-secret"* ]] || \
  fail "updater printed a stored secret"
assert_file_contains "$TMP/calls" 'docker compose --env-file .env -f compose.yml pull' \
  "updater did not pull the pinned images"
assert_file_contains "$TMP/calls" 'docker compose --env-file .env -f compose.yml up -d' \
  "updater did not recreate the stack"
assert_file_contains "$TMP/calls" '/health/readiness' \
  "updater did not verify readiness"

setup_update_case
TEST_RELEASE_TAG=v1.2.3
run_updater >/dev/null || fail "updater rejected the currently installed release"
assert_file_contains "$TMP/calls" 'docker compose --env-file .env -f compose.yml pull' \
  "same-version update did not refresh images"
assert_file_contains "$TMP/calls" '/health/readiness' \
  "same-version update did not verify readiness"

echo "PASS: guest payloads and updater"
