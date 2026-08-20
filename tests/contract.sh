#!/usr/bin/env bash

set -euo pipefail

project_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
port=${OMARCHY_CASHU_TEST_PORT:-38431}
base_url="http://127.0.0.1:$port"
credential=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
state_dir=$(mktemp -d)
daemon_log=$(mktemp)
stream_output=$(mktemp)
stream_headers=$(mktemp)
initialize_headers=$(mktemp)
recovery_headers=$(mktemp)
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
  rm -f "$daemon_log" "$stream_output" "$stream_headers" \
    "$initialize_headers" "$recovery_headers"
  rm -rf "$state_dir"
}
trap cleanup EXIT

fail() {
  echo "contract: $*" >&2
  echo "contract: mock log follows" >&2
  sed -n '1,160p' "$daemon_log" >&2
  echo "contract: stream output follows" >&2
  sed -n '1,120p' "$stream_output" >&2
  exit 1
}

auth=(-H "Authorization: Bearer $credential")
mkdir -p "$state_dir/credentials/generation-1"
printf '%s\n' "$credential" >"$state_dir/credentials/generation-1/client"
chmod 700 "$state_dir" "$state_dir/credentials" "$state_dir/credentials/generation-1"
chmod 600 "$state_dir/credentials/generation-1/client"
ln -s generation-1 "$state_dir/credentials/current"

COCOD_STATE_DIR="$state_dir" python3 "$project_dir/scripts/mock-cocod.py" \
  --port "$port" >"$daemon_log" 2>&1 &
daemon_pid=$!

for _attempt in {1..40}; do
  curl -fsS "$base_url/__test__/status" >/dev/null 2>&1 && break
  sleep 0.05
done

health=$(curl -fsS "$base_url/health") || fail "public health endpoint is unavailable"
jq -e '. == {status: "ok", interfaceVersion: "1"}' <<<"$health" >/dev/null \
  || fail "health leaked more than minimal process liveness"

missing_auth=$(curl -sS "$base_url/v1/status")
jq -e '.error.code == "authentication_required" and .error.retryable == false' \
  <<<"$missing_auth" >/dev/null || fail "missing authentication did not use the common error document"

invalid_auth=$(curl -sS -H 'Authorization: Bearer invalid' "$base_url/v1/status")
jq -e '.error.code == "invalid_client_credential" and .error.retryable == false' \
  <<<"$invalid_auth" >/dev/null || fail "invalid authentication did not use a stable error code"

capabilities=$(curl -fsS "${auth[@]}" "$base_url/v1/capabilities") \
  || fail "authenticated capability discovery failed"
jq -e '
  .interfaceVersion == "1"
  and (.instanceId | type == "string" and length > 0)
  and ([
    "wallet.lifecycle", "wallet.balances", "wallet.mints",
    "wallet.receive-operations", "wallet.send-operations", "wallet.events"
  ] - .capabilities | length == 0)
' <<<"$capabilities" >/dev/null || fail "capability discovery does not describe the implemented slice"

status=$(curl -fsS "${auth[@]}" "$base_url/v1/status") \
  || fail "authenticated lifecycle status failed"
jq -e '
  .daemon.interfaceVersion == "1"
  and .wallet == null
  and .seedAccess == null
  and .cocoSession.state == "stopped"
' <<<"$status" >/dev/null || fail "first-run lifecycle facts do not match cocod v1"

unconfigured=$(curl -sS "${auth[@]}" "$base_url/v1/balances")
jq -e '.error.code == "wallet_not_configured" and .error.retryable == false' \
  <<<"$unconfigured" >/dev/null || fail "wallet-dependent failure is not structured"

initialize=$(curl -fsS -D "$initialize_headers" "${auth[@]}" -X POST \
  -H 'Content-Type: application/json' --data '{}' \
  "$base_url/v1/admin/wallet/initialize") || fail "Wallet initialization failed"
generated_mnemonic=$(jq -er '.generatedMnemonic | select(type == "string" and length > 0)' \
  <<<"$initialize") || fail "initialization omitted generated Wallet Recovery Material"
rg -qi '^Cache-Control: no-store' "$initialize_headers" \
  || fail "initialization response is cacheable"

status=$(curl -fsS "${auth[@]}" "$base_url/v1/status")
jq -e '
  (.wallet.configuredAt | type == "string")
  and .seedAccess == {state: "available", requiresPassphrase: false}
  and .cocoSession.state == "running"
' <<<"$status" >/dev/null || fail "initialized lifecycle facts do not match cocod v1"

second_initialize=$(curl -sS "${auth[@]}" -X POST \
  -H 'Content-Type: application/json' --data '{}' \
  "$base_url/v1/admin/wallet/initialize")
jq -e '.error.code == "wallet_already_configured" and .error.retryable == false' \
  <<<"$second_initialize" >/dev/null || fail "repeated initialization did not branch on a stable code"

curl -fsS -X POST -H 'Content-Type: application/json' \
  --data '{
    "balances": {"items": [
      {"mintUrl":"https://mint.one","unit":"sat","spendable":"90071992547409931234567890","reserved":"7","total":"90071992547409931234567897"},
      {"mintUrl":"https://mint.two","unit":"sat","spendable":"10","reserved":"3","total":"13"}
    ]},
    "mints": {"items": [
      {"mintUrl":"https://mint.one","name":"Mint One","trusted":true,"createdAt":"2026-08-20T12:00:00Z","updatedAt":"2026-08-20T12:00:00Z"}
    ]},
    "receivePrepared": {"items": []},
    "receiveInFlight": {"items": []},
    "sendPrepared": {"items": [{"id":"send-1","type":"send","state":"prepared","mintUrl":"https://mint.one","unit":"sat","amount":"60","fee":"2","inputAmount":"70","needsSwap":true,"createdAt":"2026-08-20T12:00:00Z","updatedAt":"2026-08-20T12:00:00Z"}]},
    "sendInFlight": {"items": []},
    "event": {"type":"balance.updated","timestamp":"2026-08-20T12:00:01Z","data":{"mintUrl":"https://mint.one"}},
    "delivery":"partial"
  }' "$base_url/__test__/resources" >/dev/null \
  || fail "could not establish canonical mock resources"

balances=$(curl -fsS "${auth[@]}" "$base_url/v1/balances")
mints=$(curl -fsS "${auth[@]}" "$base_url/v1/mints")
receive_prepared=$(curl -fsS "${auth[@]}" "$base_url/v1/operations/receive/prepared")
receive_in_flight=$(curl -fsS "${auth[@]}" "$base_url/v1/operations/receive/in-flight")
send_prepared=$(curl -fsS "${auth[@]}" "$base_url/v1/operations/send/prepared")
send_in_flight=$(curl -fsS "${auth[@]}" "$base_url/v1/operations/send/in-flight")
jq -e '
  .items[0].spendable == "90071992547409931234567890"
  and (.items[0].spendable | type == "string")
  and (.items[0].reserved | type == "string")
  and (.items[0].total | type == "string")
' <<<"$balances" >/dev/null || fail "balances are not lossless decimal strings"
jq -e '.items[0].trusted == true' <<<"$mints" >/dev/null || fail "Known Mints shape is invalid"
jq -e '.items == []' <<<"$receive_prepared" >/dev/null || fail "Receive prepared collection is invalid"
jq -e '.items == []' <<<"$receive_in_flight" >/dev/null || fail "Receive in-flight collection is invalid"
jq -e '.items[0].amount == "60" and (.items[0].amount | type == "string")' \
  <<<"$send_prepared" >/dev/null || fail "Send Operation collection is invalid"
jq -e '.items == []' <<<"$send_in_flight" >/dev/null || fail "Send in-flight collection is invalid"

curl -sS -N --max-time 3 -D "$stream_headers" "${auth[@]}" \
  -H 'Accept: text/event-stream' "$base_url/v1/events" >"$stream_output" 2>/dev/null &
stream_pid=$!
for _attempt in {1..40}; do
  mock_status=$(curl -fsS "$base_url/__test__/status") || true
  jq -e '.streamConnections == 1' <<<"$mock_status" >/dev/null 2>&1 && break
  sleep 0.05
done

curl -fsS -X POST -H 'Content-Type: application/json' \
  --data '{
    "balances":{"items":[{"mintUrl":"https://mint.one","unit":"sat","spendable":"42","reserved":"0","total":"42"}]},
    "event":{"type":"balance.updated","timestamp":"2026-08-20T12:00:02Z","data":{"mintUrl":"https://mint.one"}},
    "delivery":"partial"
  }' "$base_url/__test__/resources" >/dev/null
for _attempt in {1..40}; do
  rg -Fqx 'data: {"type":"balance.updated","timestamp":"2026-08-20T12:00:02Z","data":{"mintUrl":"https://mint.one"}}' \
    "$stream_output" && break
  sleep 0.05
done
rg -qi '^Content-Type: text/event-stream' "$stream_headers" \
  || fail "events did not use the SSE content type"
rg -q '^retry: 3000$' "$stream_output" || fail "event stream omitted the server retry hint"
rg -Fqx 'data: {"type":"balance.updated","timestamp":"2026-08-20T12:00:02Z","data":{"mintUrl":"https://mint.one"}}' \
  "$stream_output" || fail "event stream did not emit a safe invalidation envelope"
if rg -q '^id:' "$stream_output" || rg -qi 'proof|token|90071992547409931234567890' "$stream_output"; then
  fail "event stream exposed replay metadata or wallet material"
fi

recovery=$(curl -fsS -D "$recovery_headers" "${auth[@]}" -X POST \
  -H 'Content-Type: application/json' --data '{}' \
  "$base_url/v1/admin/wallet/recovery-material") || fail "Recovery Material retrieval failed"
recovered_mnemonic=$(jq -er '.mnemonic | select(type == "string" and length > 0)' \
  <<<"$recovery") || fail "Recovery Material response omitted its mnemonic"
[[ $recovered_mnemonic == "$generated_mnemonic" ]] \
  || fail "Recovery Material did not preserve the Wallet Instance mnemonic"
rg -qi '^Cache-Control: no-store' "$recovery_headers" \
  || fail "Recovery Material response is cacheable"

mock_status=$(curl -fsS "$base_url/__test__/status")
jq -e '
  .authorizationFailures == 2
  and .authenticatedV1Requests >= 12
  and .resourceRequests.status >= 2
  and .resourceRequests.balances >= 1
  and .resourceRequests.mints >= 1
  and .resourceRequests.receivePrepared >= 1
  and .resourceRequests.receiveInFlight >= 1
  and .resourceRequests.sendPrepared >= 1
  and .resourceRequests.sendInFlight >= 1
' <<<"$mock_status" >/dev/null || fail "mock diagnostics did not record the canonical contract"

if rg -Fq "$credential" "$daemon_log" \
    || rg -Fq "$generated_mnemonic" <<<"$status$balances$mints$receive_prepared$receive_in_flight$send_prepared$send_in_flight$mock_status" \
    || rg -Fq "$generated_mnemonic" "$daemon_log" "$stream_output"; then
  fail "a Client Credential or Recovery Phrase escaped its narrow sensitive response"
fi

echo "contract: cocod v1 auth, lifecycle, resources, decimal strings, errors, SSE, and redaction passed"
