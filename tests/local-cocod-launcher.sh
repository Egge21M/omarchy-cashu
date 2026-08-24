#!/usr/bin/env bash

set -euo pipefail

project_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
fixture_root=$(mktemp -d)
candidate_repo="$fixture_root/coco"
incompatible_repo="$fixture_root/coco-without-openapi"
legacy_repo="$fixture_root/cocod"
instance_home="$fixture_root/wallet-instance"
state_root="$instance_home/.cocod"
fake_bin="$fixture_root/bin"
invocation="$fixture_root/invocation"
launcher_output="$fixture_root/launcher-output"

cleanup() {
  rm -rf "$fixture_root"
}
trap cleanup EXIT

fail() {
  echo "local-cocod-launcher: $*" >&2
  exit 1
}

make_monorepo_fixture() {
  local repo=$1
  mkdir -p "$repo/packages/cocod/src/utils" "$repo/packages/cocod/docs"
  printf '%s\n' '{"name":"coco","workspaces":["packages/*"]}' >"$repo/package.json"
  printf '%s\n' '{"name":"cocod","private":true}' >"$repo/packages/cocod/package.json"
  printf '%s\n' '#!/usr/bin/env bun' >"$repo/packages/cocod/src/index.ts"
}

make_monorepo_fixture "$candidate_repo"
printf '%s\n' 'export const CONFIG_DIR = `${homedir()}/.cocod`;' \
  >"$candidate_repo/packages/cocod/src/utils/config.ts"
cat >"$candidate_repo/packages/cocod/docs/openapi-v1.json" <<'OPENAPI'
{
  "openapi": "3.1.0",
  "x-cocod-interface-version": "1",
  "paths": {
    "/v1/openapi.json": {},
    "/v1/status": {},
    "/v1/balances": {},
    "/v1/events": {},
    "/v1/mints": {},
    "/v1/operations/receive/prepared": {},
    "/v1/operations/receive/in-flight": {},
    "/v1/operations/send/prepared": {},
    "/v1/operations/send/in-flight": {},
    "/v1/admin/wallet/initialize": {},
    "/v1/admin/wallet/recovery-material": {},
    "/v1/admin/process/stop": {}
  }
}
OPENAPI

make_monorepo_fixture "$incompatible_repo"
printf '%s\n' 'export const CONFIG_DIR = `${homedir()}/.cocod`;' \
  >"$incompatible_repo/packages/cocod/src/utils/config.ts"
printf '%s\n' '{}' >"$incompatible_repo/packages/cocod/docs/openapi-v1.json"

mkdir -p "$legacy_repo/src" "$fake_bin"
printf '%s\n' '{"name":"cocod"}' >"$legacy_repo/package.json"
printf '%s\n' '#!/usr/bin/env bun' >"$legacy_repo/src/index.ts"

cat >"$fake_bin/bun" <<'FAKE_BUN'
#!/usr/bin/env bash
set -euo pipefail
{
  printf 'state=%s\n' "${COCOD_STATE_DIR-unset}"
  printf 'home=%s\n' "${HOME:-}"
  printf 'host=%s\n' "${COCOD_LISTEN_HOST:-}"
  printf 'port=%s\n' "${COCOD_LISTEN_PORT:-}"
  printf 'client_url=%s\n' "${COCOD_URL-unset}"
  printf 'working_directory=%s\n' "$PWD"
  printf 'arguments='
  printf '%q ' "$@"
  printf '\n'
} >"$LOCAL_COCOD_TEST_INVOCATION"
FAKE_BUN
chmod 755 "$fake_bin/bun"

PATH="$fake_bin:$PATH" LOCAL_COCOD_TEST_INVOCATION="$invocation" COCOD_URL=http://example.invalid \
  "$project_dir/scripts/run-local-cocod.sh" \
    --repo "$candidate_repo" \
    --state-root "$state_root" \
    --port 38435 \
    >"$launcher_output" 2>&1 \
  || fail "compatible source checkout was rejected"

rg -Fx 'state=unset' "$invocation" >/dev/null \
  || fail "launcher passed its Wallet Client state override into canonical cocod"
rg -Fx "home=$instance_home" "$invocation" >/dev/null \
  || fail "launcher did not isolate canonical cocod through its dedicated HOME"
rg -Fx 'host=127.0.0.1' "$invocation" >/dev/null \
  || fail "launcher did not restrict cocod to loopback"
rg -Fx 'port=38435' "$invocation" >/dev/null \
  || fail "launcher did not pass the selected port"
rg -Fx 'client_url=unset' "$invocation" >/dev/null \
  || fail "launcher leaked an inherited cocod client endpoint into the daemon"
rg -Fx "working_directory=$candidate_repo" "$invocation" >/dev/null \
  || fail "launcher did not run from the selected Coco repository"
rg -F 'packages/cocod/src/index.ts daemon' "$invocation" >/dev/null \
  || fail "launcher did not execute cocod from source"
rg -Fx "COCOD_STATE_DIR=$state_root" "$launcher_output" >/dev/null \
  || fail "launcher did not print the Wallet Client state-root setting"
rg -Fx 'OMARCHY_CASHU_DAEMON_URL=http://127.0.0.1:38435' "$launcher_output" >/dev/null \
  || fail "launcher did not print the Wallet Client daemon URL"
if rg -i 'credential|authorization|bearer' "$launcher_output"; then
  fail "launcher output mentioned sensitive authentication material"
fi

assert_rejected() {
  local expected=$1
  shift
  if PATH="$fake_bin:$PATH" LOCAL_COCOD_TEST_INVOCATION="$invocation" \
      "$project_dir/scripts/run-local-cocod.sh" "$@" >"$launcher_output" 2>&1; then
    fail "invalid launcher input was accepted: $*"
  fi
  rg -F "$expected" "$launcher_output" >/dev/null \
    || fail "launcher error was not actionable for: $*"
}

assert_rejected 'compatible Coco monorepo' \
  --repo "$legacy_repo" --state-root "$state_root"
assert_rejected 'canonical cocod OpenAPI' \
  --repo "$incompatible_repo" --state-root "$state_root"
assert_rejected 'state root must be an absolute path' \
  --repo "$candidate_repo" --state-root relative/wallet
assert_rejected 'state root must not be the filesystem root' \
  --repo "$candidate_repo" --state-root /
assert_rejected 'state root must end with /.cocod' \
  --repo "$candidate_repo" --state-root "$fixture_root/not-cocod"
assert_rejected 'port must be an integer between 1 and 65535' \
  --repo "$candidate_repo" --state-root "$state_root" --port 0
assert_rejected 'port must be an integer between 1 and 65535' \
  --repo "$candidate_repo" --state-root "$state_root" --port 65536

echo "local-cocod-launcher: source selection, isolation, and safe environment output passed"
