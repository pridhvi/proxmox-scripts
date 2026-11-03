#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'cleanup; rm -rf "$TMP"' EXIT
source "$ROOT/install.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }
contains() { grep -Fq -- "$2" "$1" || fail "missing: $2"; }
prepare_payloads
bash -n "$WORK_DIR/update.sh" "$WORK_DIR/install-internal.sh"
contains "$WORK_DIR/override.yml" 'image: ollama/ollama:latest'
contains "$WORK_DIR/override.yml" 'ollama-models:/root/.ollama'
if grep -Fq 'ports:' "$WORK_DIR/override.yml"; then fail "Ollama publishes a port"; fi
contains "$WORK_DIR/install-internal.sh" 'EMBEDDING_PROVIDER=ollama'
contains "$WORK_DIR/install-internal.sh" 'EMBEDDING_URL=http://ollama:11434'
contains "$WORK_DIR/install-internal.sh" 'ollama pull nomic-embed-text'
contains "$WORK_DIR/install-internal.sh" 'DOCKER_INSIDE=false'
contains "$WORK_DIR/install-internal.sh" 'PENTAGI_POSTGRES_PASSWORD=%s'
contains "$WORK_DIR/install-internal.sh" 'LOCAL_SCRAPER_PASSWORD=%s'
contains "$WORK_DIR/update.sh" 'sha256sum -c .compose.sha256'
contains "$WORK_DIR/update.sh" 'docker compose --env-file .env -f compose.yml -f compose.local.yml up -d'
if grep -Fq 'ollama pull' "$WORK_DIR/update.sh"; then fail "updater overwrites embedding weights"; fi

assert_root_guard='[[ $EUID -eq 0 ]] || die "run as root"'
contains "$WORK_DIR/update.sh" "$assert_root_guard"
if [[ $EUID -ne 0 ]]; then
  sed 's/^\[\[ $EUID -eq 0 \]\] || die "run as root"$/:/' "$WORK_DIR/update.sh" >"$TMP/update"
else
  cp "$WORK_DIR/update.sh" "$TMP/update"
fi
chmod +x "$TMP/update"
mkdir -p "$TMP/bin" "$TMP/instance"
cat >"$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >>"$CALLS"
if [[ $* == *api.github.com* ]]; then printf '{"tag_name":"%s"}\n' "${RELEASE:-v2.2.1}"
elif [[ $* == *raw.githubusercontent.com* ]]; then
  while [[ $# -gt 0 ]]; do if [[ $1 == -o ]]; then printf 'services: {}\n' >"$2"; exit; fi; shift; done
elif [[ ${FAIL_HEALTH:-0} == 1 ]]; then exit 1
fi
EOF
cat >"$TMP/bin/jq" <<'EOF'
#!/usr/bin/env bash
sed -n 's/.*"tag_name":"\([^"]*\)".*/\1/p'
EOF
cat >"$TMP/bin/docker" <<'EOF'
#!/usr/bin/env bash
printf 'docker %s\n' "$*" >>"$CALLS"
[[ ${FAIL_PULL:-0} != 1 || ${*: -1} != pull ]]
EOF
cat >"$TMP/bin/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$TMP/bin/"*
setup_case() {
  printf 'PENTAGI_IMAGE=vxcontrol/pentagi:2.2.0\nPENTAGI_LISTEN_PORT=8443\nLLM_SERVER_KEY=secret\n' >"$TMP/instance/.env"
  printf 'services: {}\n' >"$TMP/instance/compose.yml"
  cp "$WORK_DIR/override.yml" "$TMP/instance/compose.local.yml"
  (cd "$TMP/instance" && sha256sum compose.yml >.compose.sha256)
  cp "$TMP/instance/.env" "$TMP/original"
  : >"$TMP/calls"
}
run_update() { env PATH="$TMP/bin:$PATH" CALLS="$TMP/calls" PENTAGI_DIR="$TMP/instance" "$TMP/update"; }
setup_case
RELEASE=bad; export RELEASE
if run_update >/dev/null 2>&1; then fail "invalid release accepted"; fi
cmp "$TMP/original" "$TMP/instance/.env" || fail "invalid release changed env"
RELEASE=v2.2.1
setup_case
output=$(run_update) || fail "valid update failed"
contains "$TMP/instance/.env" 'PENTAGI_IMAGE=vxcontrol/pentagi:2.2.1'
contains "$TMP/instance/.env" 'LLM_SERVER_KEY=secret'
[[ $output != *secret* ]] || fail "updater exposed a secret"
[[ $(stat -c %a "$TMP/instance/.env") == 600 ]] || fail "env permissions incorrect"
contains "$TMP/calls" 'pull'
contains "$TMP/calls" 'up -d'
setup_case
if FAIL_PULL=1 run_update >/dev/null 2>&1; then fail "pull failure ignored"; fi
cmp "$TMP/original" "$TMP/instance/.env" || fail "pull failure changed env"
if grep -Fq 'up -d' "$TMP/calls"; then fail "pull failure started stack"; fi
setup_case
printf '# user change\n' >>"$TMP/instance/compose.yml"
if run_update >/dev/null 2>&1; then fail "modified compose accepted"; fi
[[ ! -s "$TMP/calls" ]] || fail "modified compose reached network or Docker"
setup_case
if FAIL_HEALTH=1 run_update >/dev/null 2>&1; then fail "health failure ignored"; fi
echo "PASS: guest payloads and updater"
