#!/usr/bin/env bash

set -euo pipefail

project_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
port=${OMARCHY_CASHU_TEST_PORT:-38431}
base_url="http://127.0.0.1:$port"
daemon_log=$(mktemp)
stream_output=$(mktemp)
stream_headers=$(mktemp)
create_headers=$(mktemp)
reveal_headers=$(mktemp)
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
  rm -f "$daemon_log" "$stream_output" "$stream_headers" "$create_headers" "$reveal_headers"
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
  and .wallet.state == "uninitialized"
  and .wallet.balances == {spendable: 0, reserved: 0, unit: "sat"}
  and .wallet.activeTransfers == []
  and .wallet.trustedMints == []
' <<<"$snapshot" >/dev/null || fail "initial snapshot does not match the contract"

status=$(curl -fsS "$base_url/__test__/status")
jq -e '
  .createRequests == 0
  and .recoveryPhraseRevealRequests == 0
' <<<"$status" >/dev/null || fail "mock issued a wallet command without an explicit request"

if rg -qi 'recovery|phrase|abandon' <<<"$snapshot"; then
  fail "initial snapshot leaked Recovery Phrase material"
fi

echo "contract: explicit uninitialized first run passed"

uninitialized_reveal_status=$(curl -sS -o /dev/null -w '%{http_code}' -X POST \
  -H 'Content-Type: application/json' --data '{}' \
  "$base_url/v1/wallet/recovery-phrase/reveal")
[[ $uninitialized_reveal_status == 409 ]] \
  || fail "uninitialized wallet exposed a Recovery Phrase"

curl -sS -N --max-time 3 -D "$stream_headers" -H 'Accept: text/event-stream' \
  -H 'Last-Event-ID: 1' "$base_url/v1/events" >"$stream_output" 2>/dev/null &
stream_pid=$!

for _attempt in {1..40}; do
  status=$(curl -fsS "$base_url/__test__/status") || true
  jq -e '.streamConnections == 1 and .lastEventId == "1"' \
    <<<"$status" >/dev/null 2>&1 && break
  sleep 0.05
done

create_response=$(curl -fsS -D "$create_headers" -X POST \
  -H 'Content-Type: application/json' --data '{}' \
  "$base_url/v1/wallet/create") || fail "explicit create command failed"
jq -e '.accepted == true' <<<"$create_response" >/dev/null \
  || fail "create command did not return its minimal acknowledgement"
rg -qi '^Cache-Control: no-store' "$create_headers" \
  || fail "create response is cacheable"

for _attempt in {1..40}; do
  status=$(curl -fsS "$base_url/__test__/status") || true
  jq -e '.createRequests == 1 and .revision == 2' \
    <<<"$status" >/dev/null 2>&1 && break
  sleep 0.05
done

for _attempt in {1..40}; do
  rg -q '^data: .*"revision":2' "$stream_output" && break
  sleep 0.05
done
rg -q '^data: \{"apiVersion":"1","revision":2,"kind":"wallet-state-changed"\}$' \
  "$stream_output" || fail "create event did not contain safe versioned metadata"

snapshot=$(curl -fsS "$base_url/v1/wallet/snapshot")
jq -e '
  .revision == 2
  and .wallet.state == "unlocked"
  and .wallet.balances == {spendable: 0, reserved: 0, unit: "sat"}
  and .wallet.activeTransfers == []
  and .wallet.trustedMints == []
' <<<"$snapshot" >/dev/null || fail "creation did not settle to one empty Wallet Instance"

second_create_status=$(curl -sS -o /dev/null -w '%{http_code}' -X POST \
  -H 'Content-Type: application/json' --data '{}' \
  "$base_url/v1/wallet/create")
[[ $second_create_status == 409 ]] \
  || fail "second create was not rejected with HTTP 409"
status=$(curl -fsS "$base_url/__test__/status")
jq -e '.createRequests == 2 and .revision == 2' <<<"$status" >/dev/null \
  || fail "rejected create mutated the Wallet Instance"

echo "contract: explicit create and conflict behavior passed"

reveal_response=$(curl -fsS -D "$reveal_headers" -X POST \
  -H 'Content-Type: application/json' --data '{}' \
  "$base_url/v1/wallet/recovery-phrase/reveal") \
  || fail "Recovery Phrase reveal command failed"
revealed_phrase=$(jq -er '.recoveryPhrase | select(type == "string" and length > 0)' \
  <<<"$reveal_response") || fail "reveal response did not contain a Recovery Phrase"
rg -qi '^Cache-Control: no-store' "$reveal_headers" \
  || fail "Recovery Phrase response is cacheable"
status=$(curl -fsS "$base_url/__test__/status")
jq -e '.recoveryPhraseRevealRequests == 2 and .revision == 2' \
  <<<"$status" >/dev/null || fail "Recovery Phrase reveal mutated durable Wallet State"
snapshot=$(curl -fsS "$base_url/v1/wallet/snapshot")
if rg -Fq "$revealed_phrase" <<<"$snapshot$status" \
    || rg -Fq "$revealed_phrase" "$stream_output"; then
  fail "Recovery Phrase escaped its command response"
fi

echo "contract: transient no-store Recovery Phrase response passed"

curl -fsS -X POST -H 'Content-Type: application/json' \
  --data '{"wallet":{"balances":{"spendable":50000,"reserved":0,"unit":"sat"},"activeTransfers":[]},"delivery":"partial"}' \
  "$base_url/__test__/snapshot" >/dev/null \
  || fail "could not advance the deterministic snapshot"

for _attempt in {1..40}; do
  rg -q '^data: .*"revision":3' "$stream_output" && break
  sleep 0.05
done

rg -q '^event: wallet.changed$' "$stream_output" \
  || fail "SSE lifecycle event was not delivered"
rg -qi '^Content-Type: text/event-stream' "$stream_headers" \
  || fail "event endpoint did not return text/event-stream"
rg -q '^data: \{"apiVersion":"1","revision":3,"kind":"wallet-state-changed"\}$' \
  "$stream_output" || fail "SSE event does not contain safe versioned metadata"
if rg -qi 'balance|proof|token|recovery|phrase|50000' "$stream_output"; then
  fail "SSE stream leaked wallet material"
fi

snapshot=$(curl -fsS "$base_url/v1/wallet/snapshot")
jq -e '
  .revision == 3
  and .wallet.balances.spendable == 50000
  and .wallet.balances.reserved == 0
  and .wallet.activeTransfers == []
' <<<"$snapshot" >/dev/null || fail "authoritative snapshot did not advance"

echo "contract: safe incremental SSE invalidation passed"
