#!/usr/bin/env bash

set -euo pipefail

repo=""
state_root=""
port=62626
host=127.0.0.1

usage() {
  cat <<'USAGE'
Usage: scripts/run-local-cocod.sh --repo PATH --state-root PATH [--port PORT]

Run a compatible cocod directly from a local cashubtc/coco monorepo checkout.
The daemon stays in the foreground so its caller or a systemd user unit owns it.

Required:
  --repo PATH        Absolute path to a compatible Coco monorepo checkout
  --state-root PATH  Absolute state root for this development Wallet Instance

Optional:
  --port PORT        Loopback TCP port (default: 62626)
  -h, --help         Show this help
USAGE
}

fail() {
  echo "run-local-cocod: $*" >&2
  exit 1
}

while (($# > 0)); do
  case $1 in
    --repo)
      (($# >= 2)) || fail "--repo requires a path"
      repo=$2
      shift 2
      ;;
    --state-root)
      (($# >= 2)) || fail "--state-root requires a path"
      state_root=$2
      shift 2
      ;;
    --port)
      (($# >= 2)) || fail "--port requires a value"
      port=$2
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "unknown argument: $1"
      ;;
  esac
done

[[ -n $repo ]] || fail "--repo is required"
[[ $repo == /* ]] || fail "repository path must be an absolute path"
[[ -d $repo ]] || fail "repository does not exist: $repo"
repo=$(cd -- "$repo" && pwd -P)

[[ -n $state_root ]] || fail "--state-root is required"
[[ $state_root == /* ]] || fail "state root must be an absolute path"
state_root=$(realpath -m -- "$state_root")
[[ $state_root != / ]] || fail "state root must not be the filesystem root"
[[ ${state_root##*/} == .cocod ]] \
  || fail "state root must end with /.cocod for canonical cocod source isolation"
instance_home=${state_root%/.cocod}
[[ -n $instance_home && $instance_home != / ]] \
  || fail "state root must use a dedicated parent directory"

[[ $port =~ ^[0-9]+$ ]] || fail "port must be an integer between 1 and 65535"
((port >= 1 && port <= 65535)) || fail "port must be an integer between 1 and 65535"

cocod_package="$repo/packages/cocod/package.json"
cocod_entry="$repo/packages/cocod/src/index.ts"
cocod_openapi="$repo/packages/cocod/docs/openapi-v1.json"
[[ -f $repo/package.json && -f $cocod_package && -f $cocod_entry && -f $cocod_openapi ]] \
  || fail "repository is not a compatible Coco monorepo with packages/cocod"
jq -e '.name == "cocod"' "$cocod_package" >/dev/null 2>&1 \
  || fail "repository is not a compatible Coco monorepo with packages/cocod"
jq -e '
  .openapi == "3.1.0"
  and ."x-cocod-interface-version" == "1"
  and (.paths as $paths | all([
    "/v1/openapi.json",
    "/v1/status",
    "/v1/balances",
    "/v1/events",
    "/v1/mints",
    "/v1/operations/receive/prepared",
    "/v1/operations/receive/in-flight",
    "/v1/operations/send/prepared",
    "/v1/operations/send/in-flight",
    "/v1/admin/wallet/initialize",
    "/v1/admin/wallet/recovery-material",
    "/v1/admin/process/stop"
  ][]; $paths[.] != null))
' "$cocod_openapi" >/dev/null 2>&1 \
  || fail "local packages/cocod does not expose the canonical cocod OpenAPI surface"
command -v bun >/dev/null 2>&1 || fail "Bun is required to run cocod from source"

umask 077
mkdir -p -- "$instance_home"

printf '%s\n' "COCOD_STATE_DIR=$state_root"
printf '%s\n' "OMARCHY_CASHU_DAEMON_URL=http://$host:$port"

cd -- "$repo"
exec env -u COCOD_URL -u COCOD_STATE_DIR \
  HOME="$instance_home" \
  COCOD_LISTEN_HOST="$host" \
  COCOD_LISTEN_PORT="$port" \
  bun packages/cocod/src/index.ts daemon
