#!/usr/bin/env bash

set -euo pipefail

project_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
repo=""
port=""

usage() {
  cat <<'USAGE'
Usage: tests/local-cocod.sh --repo PATH [--port PORT]

Run the public cocod v1 development-integration checks against a compatible
local cashubtc/coco monorepo checkout. The check creates and removes an isolated
temporary Wallet Instance and never performs Receive or Send operations.
USAGE
}

fail() {
  echo "local-cocod: $*" >&2
  echo "local-cocod: daemon log follows" >&2
  sed -n '1,200p' "$daemon_log" >&2
  echo "local-cocod: Wallet Client log follows" >&2
  sed -n '1,160p' "$shell_log" >&2
  exit 1
}

while (($# > 0)); do
  case $1 in
    --repo)
      (($# >= 2)) || { echo "local-cocod: --repo requires a path" >&2; exit 1; }
      repo=$2
      shift 2
      ;;
    --port)
      (($# >= 2)) || { echo "local-cocod: --port requires a value" >&2; exit 1; }
      port=$2
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "local-cocod: unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

[[ -n $repo ]] || { echo "local-cocod: --repo is required" >&2; exit 1; }
if [[ -z $port ]]; then
  port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')
fi

instance_home=$(mktemp -d)
state_root="$instance_home/.cocod"
daemon_log=$(mktemp)
stream_headers=$(mktemp)
stream_output=$(mktemp)
recovery_headers=$(mktemp)
shell_log=$(mktemp)
runtime_dir=$(mktemp -d)
shell_qml="$runtime_dir/shell.qml"
daemon_pid=""
stream_pid=""
shell_pid=""
shutdown_complete=false

cleanup() {
  if [[ -n $stream_pid ]]; then
    kill "$stream_pid" 2>/dev/null || true
    wait "$stream_pid" 2>/dev/null || true
  fi
  if [[ -n $shell_pid ]]; then
    kill "$shell_pid" 2>/dev/null || true
    wait "$shell_pid" 2>/dev/null || true
  fi
  if [[ -n $daemon_pid ]]; then
    kill "$daemon_pid" 2>/dev/null || true
    wait "$daemon_pid" 2>/dev/null || true
  fi
  rm -f "$daemon_log" "$stream_headers" "$stream_output" \
    "$recovery_headers" "$shell_log"
  rm -rf "$instance_home" "$runtime_dir"
}
trap cleanup EXIT

base_url="http://127.0.0.1:$port"
credential_path="$state_root/credentials/current/client"

auth_curl() {
  printf 'header = "Authorization: Bearer %s"\n' "$credential" \
    | curl --config - "$@"
}

adapter_call() {
  quickshell ipc --any-display -p "$shell_qml" call \
    io.github.egge21m.omarchy-cashu.local-cocod-test "$@" 2>/dev/null
}

wait_snapshot() {
  local expression=$1
  local value=""
  for _attempt in {1..200}; do
    value=$(adapter_call snapshot || true)
    jq -e "$expression" <<<"$value" >/dev/null 2>&1 && {
      printf '%s\n' "$value"
      return 0
    }
    sleep 0.05
  done
  fail "Wallet Client did not satisfy: $expression; last snapshot: ${value:-<empty>}"
}

"$project_dir/scripts/run-local-cocod.sh" \
  --repo "$repo" \
  --state-root "$state_root" \
  --port "$port" \
  >"$daemon_log" 2>&1 &
daemon_pid=$!

health=""
for _attempt in {1..200}; do
  if ! kill -0 "$daemon_pid" 2>/dev/null; then
    fail "source daemon exited before becoming healthy"
  fi
  health=$(curl -fsS "$base_url/health" 2>/dev/null || true)
  [[ -f $credential_path && -n $health ]] && break
  sleep 0.05
done
[[ -f $credential_path ]] || fail "source daemon did not provision its Client Credential"
jq -e '. == {status: "ok", interfaceVersion: "1"}' <<<"$health" >/dev/null \
  || fail "public health did not match the minimal v1 document"

[[ $(stat -c '%a' "$state_root") == 700 ]] \
  || fail "Wallet Instance state root is not private"
[[ $(stat -c '%a' "$credential_path") == 600 ]] \
  || fail "Client Credential file is not private"
credential=$(<"$credential_path")
[[ $credential =~ ^[A-Za-z0-9_-]{43}$ ]] \
  || fail "Client Credential does not match the discovery contract"

missing_auth=$(curl -sS "$base_url/v1/status")
jq -e '.error.code == "unauthenticated" and .error.retryable == false' \
  <<<"$missing_auth" >/dev/null \
  || fail "missing authentication did not return the structured v1 error"

invalid_auth=$(curl -sS -H 'Authorization: Bearer invalid' "$base_url/v1/status")
jq -e '.error.code == "unauthenticated" and .error.retryable == false' \
  <<<"$invalid_auth" >/dev/null \
  || fail "invalid authentication did not return the structured v1 error"

openapi=$(auth_curl -fsS "$base_url/v1/openapi.json") \
  || fail "authenticated OpenAPI discovery failed"
jq -e '
  .openapi == "3.1.0"
  and ."x-cocod-interface-version" == "1"
  and (.paths as $paths | all([
    "/v1/status", "/v1/balances", "/v1/events", "/v1/mints",
    "/v1/operations/receive", "/v1/operations/receive/prepared",
    "/v1/operations/receive/in-flight", "/v1/operations/send",
    "/v1/operations/send/prepared", "/v1/operations/send/in-flight",
    "/v1/admin/wallet/initialize", "/v1/admin/wallet/recovery-material",
    "/v1/admin/process/stop"
  ][]; $paths[.] != null))
' <<<"$openapi" >/dev/null \
  || fail "local cocod does not expose the canonical Wallet Client OpenAPI surface"
receive_preview_available=$(jq -r '.paths | has("/v1/token-previews")' <<<"$openapi")
send_max_available=$(jq -r '.paths | has("/v1/operations/send/max")' <<<"$openapi")

status=$(auth_curl -fsS "$base_url/v1/status") \
  || fail "authenticated lifecycle status failed"
jq -e '
  .daemon.interfaceVersion == "1"
  and .wallet == null
  and .seedAccess == null
  and .cocoSession.state == "stopped"
' <<<"$status" >/dev/null \
  || fail "temporary Wallet Instance did not begin uninitialized"

unconfigured=$(auth_curl -sS "$base_url/v1/balances")
jq -e '.error.code == "wallet_not_configured" and .error.retryable == false' \
  <<<"$unconfigured" >/dev/null \
  || fail "uninitialized balances did not return the stable v1 error"

cp "$project_dir/Service.qml" "$runtime_dir/Service.qml"
cp "$project_dir/tests/local-cocod-shell.qml" "$shell_qml"
COCOD_STATE_DIR="$state_root" OMARCHY_CASHU_DAEMON_URL="$base_url" \
  quickshell --no-color -p "$shell_qml" >"$shell_log" 2>&1 &
shell_pid=$!
wait_snapshot "
  .connectionState == \"connected\"
  and .compatibilityState == \"compatible\"
  and .walletState == \"uninitialized\"
  and .fixtureBacked == false
  and .receivePreviewAvailable == $receive_preview_available
  and .sendMaxAvailable == $send_max_available
" >/dev/null
[[ $(adapter_call canonicalDtosCompatible) == "ok" ]] \
  || fail "Shell Adapter rejected canonical cocod Receive, Send, or error DTOs"
[[ $(adapter_call createWallet) == "ok" ]] \
  || fail "Wallet Client could not initialize the temporary Wallet"
wait_snapshot '
  .connectionState == "connected"
  and .compatibilityState == "compatible"
  and .walletState == "unlocked"
  and .spendableBalance == "0"
  and .reservedBalance == "0"
' >/dev/null

for _attempt in {1..200}; do
  status=$(auth_curl -fsS "$base_url/v1/status" 2>/dev/null || true)
  jq -e '.wallet != null and .seedAccess.state == "available" and .cocoSession.state == "running"' \
    <<<"$status" >/dev/null 2>&1 && break
  sleep 0.05
done
jq -e '
  .wallet != null
  and .seedAccess == {state: "available", requiresPassphrase: false}
  and .cocoSession.state == "running"
' <<<"$status" >/dev/null \
  || fail "initialized Wallet lifecycle did not settle to available/running"

auth_curl -sS -N --max-time 3 \
  -D "$stream_headers" "$base_url/v1/events" \
  >"$stream_output" 2>/dev/null &
stream_pid=$!
for _attempt in {1..100}; do
  rg -q '^: connected$' "$stream_output" && break
  sleep 0.05
done
rg -qi '^Content-Type: text/event-stream' "$stream_headers" \
  || fail "authenticated event stream did not return SSE"
rg -q '^: connected$' "$stream_output" \
  || fail "authenticated event stream did not become readable"

balances=$(auth_curl -fsS "$base_url/v1/balances") \
  || fail "canonical balances were unavailable"
mints=$(auth_curl -fsS "$base_url/v1/mints") \
  || fail "canonical Known Mints were unavailable"
receive_prepared=$(auth_curl -fsS "$base_url/v1/operations/receive/prepared") \
  || fail "Prepared Receive collection was unavailable"
receive_in_flight=$(auth_curl -fsS "$base_url/v1/operations/receive/in-flight") \
  || fail "in-flight Receive collection was unavailable"
send_prepared=$(auth_curl -fsS "$base_url/v1/operations/send/prepared") \
  || fail "Prepared Send collection was unavailable"
send_in_flight=$(auth_curl -fsS "$base_url/v1/operations/send/in-flight") \
  || fail "in-flight Send collection was unavailable"
for resource in "$balances" "$receive_prepared" "$receive_in_flight" \
    "$send_prepared" "$send_in_flight"; do
  jq -e '.items == []' <<<"$resource" >/dev/null \
    || fail "new Wallet balances or Operations were not empty collections"
done
jq -e '
  (.items | type == "array")
  and all(.items[]; (.mintUrl | type == "string") and (.trusted | type == "boolean"))
' <<<"$mints" >/dev/null \
  || fail "Known Mints did not use the safe canonical collection shape"

recovery=$(auth_curl -fsS -D "$recovery_headers" -X POST \
  -H 'Content-Type: application/json' --data '{}' \
  "$base_url/v1/admin/wallet/recovery-material") \
  || fail "Recovery Material retrieval through local cocod failed"
recovered_mnemonic=$(jq -er '.mnemonic | select(type == "string" and length > 0)' \
  <<<"$recovery") || fail "Recovery Material response was invalid"
rg -qi '^Cache-Control: no-store' "$recovery_headers" \
  || fail "Recovery Material response was cacheable"

diagnostic_files=("$daemon_log" "$shell_log" "$stream_headers" "$stream_output")
[[ ! -f $state_root/daemon.log ]] || diagnostic_files+=("$state_root/daemon.log")
if printf '%s\n%s\n' "$credential" "$recovered_mnemonic" \
    | rg -Fq -f - "${diagnostic_files[@]}"; then
  fail "local-cocod diagnostics exposed Wallet secrets"
fi

kill "$shell_pid"
wait "$shell_pid" 2>/dev/null || true
shell_pid=""
health_after_client_exit=$(curl -fsS "$base_url/health") \
  || fail "closing the Wallet Client stopped the independently owned cocod process"
jq -e '.status == "ok"' <<<"$health_after_client_exit" >/dev/null \
  || fail "cocod health changed after the Wallet Client exited"

shutdown=$(auth_curl -fsS -X POST -H 'Content-Type: application/json' --data '{}' \
  "$base_url/v1/admin/process/stop") \
  || fail "authenticated graceful shutdown failed"
jq -e '.status == "stopping"' <<<"$shutdown" >/dev/null \
  || fail "graceful shutdown did not return the accepted response"
for _attempt in {1..200}; do
  kill -0 "$daemon_pid" 2>/dev/null || {
    shutdown_complete=true
    break
  }
  sleep 0.05
done
[[ $shutdown_complete == true ]] || fail "source daemon did not exit after graceful shutdown"
wait "$daemon_pid" 2>/dev/null || fail "source daemon exited unsuccessfully"
daemon_pid=""

echo "local-cocod: source launch, authentication, Wallet lifecycle, resources, SSE, redaction, and shutdown passed"
