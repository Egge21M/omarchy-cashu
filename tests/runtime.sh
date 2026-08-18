#!/usr/bin/env bash

set -euo pipefail

project_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
port=${OMARCHY_CASHU_TEST_PORT:-38433}
base_url="http://127.0.0.1:$port"
runtime_dir=$(mktemp -d)
shell_qml="$runtime_dir/shell.qml"
mock_log=$(mktemp)
shell_log=$(mktemp)
mock_pid=""
shell_pid=""

cleanup() {
  if [[ -n $shell_pid ]]; then
    kill "$shell_pid" 2>/dev/null || true
    wait "$shell_pid" 2>/dev/null || true
  fi
  if [[ -n $mock_pid ]]; then
    kill "$mock_pid" 2>/dev/null || true
    wait "$mock_pid" 2>/dev/null || true
  fi
  rm -f "$mock_log" "$shell_log"
  rm -f "$runtime_dir/Service.qml" "$runtime_dir/shell.qml"
  rm -f "$runtime_dir/Panel.qml" "$runtime_dir/Commons" "$runtime_dir/Ui"
  rmdir "$runtime_dir" 2>/dev/null || true
}
trap cleanup EXIT

fail() {
  echo "runtime: $*" >&2
  echo "runtime: shell log follows" >&2
  sed -n '1,200p' "$shell_log" >&2
  echo "runtime: mock log follows" >&2
  sed -n '1,120p' "$mock_log" >&2
  exit 1
}

adapter_call() {
  quickshell ipc --any-display -p "$shell_qml" call \
    io.github.egge21m.omarchy-cashu.state "$@" 2>/dev/null
}

panel_call() {
  quickshell ipc --any-display -p "$shell_qml" call \
    io.github.egge21m.omarchy-cashu.runtime-test panelSnapshot 2>/dev/null
}

wait_snapshot() {
  local expression=$1
  local value=""
  for _attempt in {1..100}; do
    value=$(adapter_call snapshot || true)
    jq -e "$expression" <<<"$value" >/dev/null 2>&1 && {
      printf '%s\n' "$value"
      return 0
    }
    sleep 0.05
  done
  fail "adapter did not satisfy: $expression; last snapshot: ${value:-<empty>}"
}

wait_panel_snapshot() {
  local expression=$1
  local value=""
  for _attempt in {1..100}; do
    value=$(panel_call || true)
    jq -e "$expression" <<<"$value" >/dev/null 2>&1 && {
      printf '%s\n' "$value"
      return 0
    }
    sleep 0.05
  done
  fail "panel did not satisfy: $expression; last snapshot: ${value:-<empty>}"
}

wait_mock_status() {
  local expression=$1
  local value=""
  for _attempt in {1..100}; do
    value=$(curl -fsS "$base_url/__test__/status" 2>/dev/null || true)
    jq -e "$expression" <<<"$value" >/dev/null 2>&1 && {
      printf '%s\n' "$value"
      return 0
    }
    sleep 0.05
  done
  fail "mock did not satisfy: $expression; last status: ${value:-<empty>}"
}

cp "$project_dir/Service.qml" "$runtime_dir/Service.qml"
cp "$project_dir/Panel.qml" "$runtime_dir/Panel.qml"
cp "$project_dir/tests/runtime-shell.qml" "$shell_qml"
ln -s /usr/share/omarchy/shell/Commons "$runtime_dir/Commons"
ln -s /usr/share/omarchy/shell/Ui "$runtime_dir/Ui"

python3 "$project_dir/scripts/mock-cocod.py" --port "$port" >"$mock_log" 2>&1 &
mock_pid=$!
for _attempt in {1..40}; do
  curl -fsS "$base_url/__test__/status" >/dev/null 2>&1 && break
  sleep 0.05
done

OMARCHY_CASHU_DAEMON_URL="$base_url" quickshell --no-color -p "$shell_qml" \
  >"$shell_log" 2>&1 &
shell_pid=$!

wait_snapshot '
  .revision == 1
  and .connectionState == "connected"
  and .compatibilityState == "compatible"
  and .walletState == "unlocked"
  and .spendableBalance == 42000
  and .reservedBalance == 7000
  and .barAttention == false
  and .barActive == true
  and .setupTitle == "Connected to cocod"
' >/dev/null
wait_panel_snapshot '
  .revision == 1
  and .walletState == "unlocked"
  and .balancesAvailable == true
  and .spendableBalance == 42000
  and .reservedBalance == 7000
  and .retryVisible == false
' >/dev/null

curl -fsS -X POST -H 'Content-Type: application/json' \
  --data '{"wallet":{"balances":{"spendable":50000,"reserved":0,"unit":"sat"},"activeTransfers":[]},"delivery":"partial"}' \
  "$base_url/__test__/snapshot" >/dev/null

wait_snapshot '
  .revision == 2
  and .observedRevision == 2
  and .spendableBalance == 50000
  and .reservedBalance == 0
  and .activeTransfers == []
  and .barActive == false
  and .heartbeatCount > 0
' >/dev/null
wait_panel_snapshot '
  .revision == 2
  and .balancesAvailable == true
  and .spendableBalance == 50000
  and .reservedBalance == 0
' >/dev/null

curl -fsS -X POST -H 'Content-Type: application/json' \
  --data '{"snapshot":"ok","delayMs":300}' "$base_url/__test__/mode" >/dev/null
curl -fsS -X POST -H 'Content-Type: application/json' \
  --data '{"wallet":{"balances":{"spendable":51000,"reserved":0,"unit":"sat"}},"delivery":"partial"}' \
  "$base_url/__test__/snapshot" >/dev/null
wait_mock_status '.snapshotRequestsActive == 1' >/dev/null

adapter_call rotate >/dev/null
curl -fsS -X POST -H 'Content-Type: application/json' \
  --data '{"snapshot":"ok","delayMs":0}' "$base_url/__test__/mode" >/dev/null
wait_snapshot '
  .connectionState == "connected"
  and .revision == 3
  and .rotationCount == 1
  and .reconnectCount >= 1
' >/dev/null

wait_mock_status '.streamConnections >= 1 and .lastEventId == "3"' >/dev/null

curl -fsS -X POST -H 'Content-Type: application/json' \
  --data '{"wallet":{"balances":{"spendable":52000,"reserved":0,"unit":"sat"}},"delivery":"whole"}' \
  "$base_url/__test__/snapshot" >/dev/null
wait_snapshot '
  .connectionState == "connected"
  and .revision == 4
  and .observedRevision == 4
  and .spendableBalance == 52000
' >/dev/null
wait_panel_snapshot '
  .revision == 4
  and .balancesAvailable == true
  and .spendableBalance == 52000
' >/dev/null

curl -fsS -X POST -H 'Content-Type: application/json' \
  --data '{"snapshot":"unavailable"}' "$base_url/__test__/mode" >/dev/null
curl -fsS -X POST "$base_url/__test__/disconnect" >/dev/null

wait_snapshot '
  .connectionState == "unavailable"
  and .walletState == "unavailable"
  and .barAttention == true
  and .retryAttempt >= 2
  and .retryDelayMs >= 240
  and .setupTitle == "cocod is temporarily unavailable"
' >/dev/null
wait_panel_snapshot '
  .connectionState == "unavailable"
  and .walletState == "unavailable"
  and .balancesAvailable == false
  and .spendableText == "Unavailable"
  and .reservedText == "Unavailable"
  and .retryVisible == true
  and .setupTitle == "cocod is temporarily unavailable"
' >/dev/null

curl -fsS -X POST -H 'Content-Type: application/json' \
  --data '{"snapshot":"ok"}' "$base_url/__test__/mode" >/dev/null
wait_snapshot '
  .connectionState == "connected"
  and .revision == 4
  and .retryAttempt == 0
  and .retryDelayMs == 0
' >/dev/null

curl -fsS -X POST -H 'Content-Type: application/json' \
  --data '{"snapshot":"invalid"}' "$base_url/__test__/mode" >/dev/null
adapter_call reconnect >/dev/null
wait_snapshot '
  .connectionState == "error"
  and .walletState == "unavailable"
  and .barAttention == true
  and .retryAttempt >= 1
  and .setupTitle == "cocod returned an invalid response"
' >/dev/null

curl -fsS -X POST -H 'Content-Type: application/json' \
  --data '{"snapshot":"ok"}' "$base_url/__test__/mode" >/dev/null
wait_snapshot '.connectionState == "connected" and .revision == 4' >/dev/null

curl -fsS -X POST -H 'Content-Type: application/json' \
  --data '{"snapshot":"stale"}' "$base_url/__test__/mode" >/dev/null
adapter_call reconnect >/dev/null
wait_snapshot '
  .revision == 4
  and .observedRevision == 4
  and .connectionState == "error"
  and .connectionDetail == "cocod returned a stale snapshot revision"
' >/dev/null

curl -fsS -X POST -H 'Content-Type: application/json' \
  --data '{"snapshot":"ok"}' "$base_url/__test__/mode" >/dev/null
wait_snapshot '.connectionState == "connected" and .revision == 4' >/dev/null

curl -fsS -X POST -H 'Content-Type: application/json' \
  --data '{"snapshot":"incompatible"}' "$base_url/__test__/mode" >/dev/null
adapter_call reconnect >/dev/null
wait_snapshot '
  .compatibilityState == "incompatible"
  and .walletState == "unavailable"
  and .barAttention == true
  and .setupTitle == "Incompatible cocod contract"
' >/dev/null
wait_panel_snapshot '
  .compatibilityState == "incompatible"
  and .walletState == "unavailable"
  and .balancesAvailable == false
  and .retryVisible == true
  and .retryLabel == "Check again"
  and .setupTitle == "Incompatible cocod contract"
' >/dev/null

kill "$shell_pid"
wait "$shell_pid" 2>/dev/null || true
shell_pid=""
kill "$mock_pid"
wait "$mock_pid" 2>/dev/null || true
mock_pid=""

OMARCHY_CASHU_DAEMON_URL="$base_url" quickshell --no-color -p "$shell_qml" \
  >"$shell_log" 2>&1 &
shell_pid=$!
wait_snapshot '
  .revision == 0
  and .connectionState == "missing"
  and .walletState == "unavailable"
  and .barAttention == true
  and .retryAttempt >= 1
  and .setupTitle == "cocod is not available"
' >/dev/null
wait_panel_snapshot '
  .connectionState == "missing"
  and .walletState == "unavailable"
  and .balancesAvailable == false
  and .retryVisible == true
  and .setupTitle == "cocod is not available"
' >/dev/null

kill "$shell_pid"
wait "$shell_pid" 2>/dev/null || true
shell_pid=""

OMARCHY_CASHU_DAEMON_URL="http://example.com:38433" quickshell --no-color -p "$shell_qml" \
  >"$shell_log" 2>&1 &
shell_pid=$!
wait_snapshot '
  .daemonUrlAllowed == false
  and .connectionState == "error"
  and .connectionDetail == "cocod URL must use HTTP on loopback"
  and .walletState == "unavailable"
  and .balancesAvailable == false
  and .retryAttempt == 0
' >/dev/null
wait_panel_snapshot '
  .connectionState == "error"
  and .walletState == "unavailable"
  and .balancesAvailable == false
  and .retryVisible == true
  and .setupTitle == "Invalid cocod connection"
' >/dev/null

echo "runtime: real panel and adapter passed SSE, rotation race, backoff, recovery, compatibility, missing cocod, and loopback-only checks"
