#!/usr/bin/env bash

set -euo pipefail

project_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
port=${OMARCHY_CASHU_TEST_PORT:-38431}
base_url="http://127.0.0.1:$port"
daemon_log=$(mktemp)
stream_output=$(mktemp)
stream_headers=$(mktemp)
daemon_pid=""
stream_pid=""

cleanup() {
  if [[ -n $daemon_pid ]]; then
    kill "$daemon_pid" 2>/dev/null || true
    wait "$daemon_pid" 2>/dev/null || true
  fi
  if [[ -n $stream_pid ]]; then
    kill "$stream_pid" 2>/dev/null || true
    wait "$stream_pid" 2>/dev/null || true
  fi
  rm -f "$daemon_log" "$stream_output" "$stream_headers"
}
trap cleanup EXIT

fail() {
  echo "contract: $*" >&2
  echo "contract: mock log follows" >&2
  sed -n '1,160p' "$daemon_log" >&2
  exit 1
}

python3 "$project_dir/scripts/mock-cocod.py" --port "$port" >"$daemon_log" 2>&1 &
daemon_pid=$!

for _attempt in {1..40}; do
  curl -fsS "$base_url/__test__/status" >/dev/null 2>&1 && break
  sleep 0.05
done

snapshot=$(curl -fsS "$base_url/v1/wallet/snapshot") \
  || fail "versioned snapshot endpoint is unavailable"

jq -e '
  .apiVersion == "1"
  and .revision == 1
  and .wallet.state == "unlocked"
  and .wallet.balances == {spendable: 42000, reserved: 7000, unit: "sat"}
  and .wallet.activeTransfers[0].state == "pending-send"
' <<<"$snapshot" >/dev/null || fail "initial snapshot does not match the contract"

echo "contract: versioned snapshot endpoint passed"

curl -sS -N --max-time 3 -D "$stream_headers" -H 'Accept: text/event-stream' \
  -H 'Last-Event-ID: 1' "$base_url/v1/events" >"$stream_output" 2>/dev/null &
stream_pid=$!

for _attempt in {1..40}; do
  status=$(curl -fsS "$base_url/__test__/status") || true
  jq -e '.streamConnections == 1 and .lastEventId == "1"' \
    <<<"$status" >/dev/null 2>&1 && break
  sleep 0.05
done

curl -fsS -X POST -H 'Content-Type: application/json' \
  --data '{"wallet":{"balances":{"spendable":50000,"reserved":0,"unit":"sat"},"activeTransfers":[]},"delivery":"partial"}' \
  "$base_url/__test__/snapshot" >/dev/null \
  || fail "could not advance the deterministic snapshot"

for _attempt in {1..40}; do
  rg -q '^data: .*"revision":2' "$stream_output" && break
  sleep 0.05
done

rg -q '^event: wallet.changed$' "$stream_output" \
  || fail "SSE lifecycle event was not delivered"
rg -qi '^Content-Type: text/event-stream' "$stream_headers" \
  || fail "event endpoint did not return text/event-stream"
rg -q '^data: \{"apiVersion":"1","revision":2,"kind":"wallet-state-changed"\}$' \
  "$stream_output" || fail "SSE event does not contain safe versioned metadata"
if rg -qi 'balance|proof|token|recovery|phrase|50000|7000' "$stream_output"; then
  fail "SSE stream leaked wallet material"
fi

snapshot=$(curl -fsS "$base_url/v1/wallet/snapshot")
jq -e '
  .revision == 2
  and .wallet.balances.spendable == 50000
  and .wallet.balances.reserved == 0
  and .wallet.activeTransfers == []
' <<<"$snapshot" >/dev/null || fail "authoritative snapshot did not advance"

echo "contract: safe incremental SSE invalidation passed"
