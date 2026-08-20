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
preview_headers=$(mktemp)
operation_headers=$(mktemp)
mint_headers=$(mktemp)
command_headers=$(mktemp)
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
    "$initialize_headers" "$recovery_headers" "$preview_headers" \
    "$operation_headers" "$mint_headers" "$command_headers"
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

post_token() {
  local path=$1
  local accepted_units=$2
  shift 2
  local filter='{token: input}'
  if [[ $accepted_units == true ]]; then
    filter='{token: input, acceptedUnits: ["sat"]}'
  fi
  jq -Rn "$filter" | curl "$@" "${auth[@]}" -X POST \
    -H 'Content-Type: application/json' --data-binary @- "$base_url$path"
}

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
    "wallet.receive-preview", "wallet.receive-operations",
    "wallet.send-operations", "wallet.events"
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

receive_token='cashuAeyJ0ZXN0Ijoic2xpY2UtNC11bmtub3duLW1pbnQifQ'
cancel_token='cashuAeyJ0ZXN0Ijoic2xpY2UtNC1jYW5jZWwifQ'
invalid_token='cashuAeyJ0ZXN0Ijoic2xpY2UtNC1pbnZhbGlkIn0'
unsupported_token='cashuAeyJ0ZXN0Ijoic2xpY2UtNC11c2QifQ'
unavailable_token='cashuAeyJ0ZXN0Ijoic2xpY2UtNC1taW50LWRvd24ifQ'
spent_token='cashuAeyJ0ZXN0Ijoic2xpY2UtNC1zcGVudCJ9'
conflicting_token='cashuAeyJ0ZXN0Ijoic2xpY2UtNC1jb25mbGljdCJ9'
receive_mint='https://mint.slice4.test'

before_preview_balances=$(curl -fsS "${auth[@]}" "$base_url/v1/balances")
before_preview_mints=$(curl -fsS "${auth[@]}" "$base_url/v1/mints")
before_preview_operations=$(curl -fsS "${auth[@]}" \
  "$base_url/v1/operations/receive/prepared")
preview=$(post_token "/v1/token-previews" true -fsS -D "$preview_headers" \
  <<<"$receive_token") || fail "valid Receive preview failed"
jq -e --arg mint "$receive_mint" '
  . == {
    mintUrl: $mint,
    unit: "sat",
    amount: "1200",
    fee: "2",
    netAmount: "1198",
    trusted: false
  }
' <<<"$preview" >/dev/null || fail "Receive preview does not match the accepted DTO"
rg -qi '^Cache-Control: no-store' "$preview_headers" \
  || fail "token preview response is cacheable"
[[ $(curl -fsS "${auth[@]}" "$base_url/v1/balances") == "$before_preview_balances" ]] \
  || fail "token preview mutated balances"
[[ $(curl -fsS "${auth[@]}" "$base_url/v1/mints") == "$before_preview_mints" ]] \
  || fail "token preview registered or trusted a mint"
[[ $(curl -fsS "${auth[@]}" "$base_url/v1/operations/receive/prepared") \
    == "$before_preview_operations" ]] || fail "token preview created an Operation"

for preview_case in \
  "$invalid_token|invalid_token|422" \
  "$unsupported_token|unsupported_unit|422" \
  "$unavailable_token|mint_unavailable|503"; do
  token=${preview_case%%|*}
  remainder=${preview_case#*|}
  expected_code=${remainder%%|*}
  expected_status=${remainder##*|}
  failure=$(post_token "/v1/token-previews" true -sS -w '\n%{http_code}' \
    <<<"$token")
  [[ ${failure##*$'\n'} == "$expected_status" ]] \
    || fail "$expected_code preview returned the wrong status"
  jq -e --arg code "$expected_code" \
    '.error.code == $code and (.error.retryable | type == "boolean")' \
    <<<"${failure%$'\n'*}" >/dev/null \
    || fail "$expected_code preview did not return a structured error"
done
[[ $(curl -fsS "${auth[@]}" "$base_url/v1/balances") == "$before_preview_balances" ]] \
  || fail "rejected previews mutated balances"
[[ $(curl -fsS "${auth[@]}" "$base_url/v1/mints") == "$before_preview_mints" ]] \
  || fail "rejected previews mutated Known Mints"

not_registered=$(post_token "/v1/operations/receive" false -sS -w '\n%{http_code}' \
  <<<"$receive_token")
[[ ${not_registered##*$'\n'} == 409 ]] \
  || fail "Receive creation accepted an unregistered mint"
jq -e '.error.code == "mint_not_registered"' \
  <<<"${not_registered%$'\n'*}" >/dev/null \
  || fail "unregistered mint failure did not use mint_not_registered"

registered=$(curl -fsS -D "$mint_headers" "${auth[@]}" -X POST \
  -H 'Content-Type: application/json' \
  --data "$(jq -cn --arg mint "$receive_mint" '{mintUrl: $mint}')" \
  "$base_url/v1/mints") || fail "Known Mint registration failed"
rg -q '^HTTP/.* 201' "$mint_headers" \
  || fail "new Known Mint registration did not return 201 Created"
jq -e --arg mint "$receive_mint" \
  '.mintUrl == $mint and .trusted == false' <<<"$registered" >/dev/null \
  || fail "Known Mint registration implicitly trusted the mint"
mint_location=$(sed -n 's/^Location: //p' "$mint_headers" | tr -d '\r')
[[ $mint_location == /v1/mints/info\?mintUrl=* ]] \
  || fail "Known Mint registration omitted its canonical Location"
canonical_mint=$(curl -fsS "${auth[@]}" "$base_url$mint_location") \
  || fail "Known Mint canonical Location was not readable"
[[ $canonical_mint == "$registered" ]] \
  || fail "Known Mint canonical Location returned a different resource"
not_trusted=$(post_token "/v1/operations/receive" false -sS -w '\n%{http_code}' \
  <<<"$receive_token")
[[ ${not_trusted##*$'\n'} == 409 ]] \
  || fail "Receive creation accepted an untrusted mint"
jq -e '.error.code == "mint_not_trusted"' \
  <<<"${not_trusted%$'\n'*}" >/dev/null \
  || fail "untrusted mint failure did not use mint_not_trusted"

trusted=$(curl -fsS -D "$mint_headers" "${auth[@]}" -X POST \
  -H 'Content-Type: application/json' \
  --data "$(jq -cn --arg mint "$receive_mint" '{mintUrl: $mint}')" \
  "$base_url/v1/mints/trust") || fail "Known Mint trust failed"
rg -q '^HTTP/.* 200' "$mint_headers" \
  || fail "Known Mint trust did not return 200 OK"
jq -e --arg mint "$receive_mint" \
  '.mintUrl == $mint and .trusted == true' <<<"$trusted" >/dev/null \
  || fail "Known Mint trust did not return the updated resource"

cancelled_prepare=$(post_token "/v1/operations/receive" false -fsS \
  <<<"$cancel_token") || fail "cancellable Receive creation failed"
cancelled_id=$(jq -er '.id' <<<"$cancelled_prepare")
cancelled=$(curl -fsS -D "$command_headers" "${auth[@]}" -X POST \
  -H 'Content-Type: application/json' \
  --data '{}' "$base_url/v1/operations/receive/$cancelled_id/cancel") \
  || fail "Prepared Receive cancellation failed"
rg -q '^HTTP/.* 200' "$command_headers" \
  || fail "Receive cancellation did not return 200 OK"
jq -e --arg id "$cancelled_id" '
  .id == $id and .type == "receive" and .state == "rolled_back"
  and .amount == "400" and .fee == "1" and .netAmount == "399"
' <<<"$cancelled" >/dev/null || fail "cancel did not return the updated Operation"
[[ $(curl -fsS "${auth[@]}" "$base_url/v1/balances") == "$before_preview_balances" ]] \
  || fail "cancelling a Prepared Receive changed balances"

prepared=$(post_token "/v1/operations/receive" false -fsS -D "$operation_headers" \
  <<<"$receive_token") || fail "Receive creation failed"
operation_id=$(jq -er '.id' <<<"$prepared")
jq -e --arg id "$operation_id" --arg mint "$receive_mint" '
  . == {
    id: $id,
    type: "receive",
    state: "prepared",
    mintUrl: $mint,
    unit: "sat",
    amount: "1200",
    fee: "2",
    netAmount: "1198",
    createdAt: "2026-08-20T12:00:00Z",
    updatedAt: "2026-08-20T12:00:00Z"
  }
' <<<"$prepared" >/dev/null || fail "Receive creation did not return a safe Prepared Receive"
rg -qi '^Cache-Control: no-store' "$operation_headers" \
  || fail "token-bearing Receive creation response is cacheable"
rg -q '^HTTP/.* 201' "$operation_headers" \
  || fail "Receive creation did not return 201 Created"
rg -qi '^Location: /v1/operations/receive/' "$operation_headers" \
  || fail "Receive creation omitted its canonical Location"

duplicate=$(post_token "/v1/operations/receive" false -sS -w '\n%{http_code}' \
  <<<"$receive_token")
[[ ${duplicate##*$'\n'} == 409 ]] \
  || fail "one bearer token created two Prepared Receives"
jq -e '.error.code == "operation_conflict"' <<<"${duplicate%$'\n'*}" >/dev/null \
  || fail "duplicate Receive creation did not return operation_conflict"

canonical_prepared=$(curl -fsS "${auth[@]}" \
  "$base_url/v1/operations/receive/$operation_id")
[[ $canonical_prepared == "$prepared" ]] \
  || fail "canonical Receive resource disagreed with creation"
prepared_collection=$(curl -fsS "${auth[@]}" \
  "$base_url/v1/operations/receive/prepared")
jq -e --arg id "$operation_id" \
  '.items | any(.id == $id and .state == "prepared")' \
  <<<"$prepared_collection" >/dev/null \
  || fail "Prepared Receive was absent from its canonical collection"

executed=$(curl -fsS -D "$command_headers" "${auth[@]}" -X POST \
  -H 'Content-Type: application/json' \
  --data '{}' "$base_url/v1/operations/receive/$operation_id/execute") \
  || fail "Prepared Receive execution failed"
rg -q '^HTTP/.* 200' "$command_headers" \
  || fail "Receive execution did not return 200 OK"
jq -e --arg id "$operation_id" '
  .id == $id and .type == "receive" and .state == "finalized"
  and .amount == "1200" and .fee == "2" and .netAmount == "1198"
' <<<"$executed" >/dev/null || fail "execute did not return the finalized Operation"
canonical_final=$(curl -fsS "${auth[@]}" \
  "$base_url/v1/operations/receive/$operation_id")
[[ $canonical_final == "$executed" ]] \
  || fail "canonical Receive resource did not establish success"
settled_balances=$(curl -fsS "${auth[@]}" "$base_url/v1/balances")
jq -e --arg mint "$receive_mint" '
  .items | any(.mintUrl == $mint and .unit == "sat"
    and .spendable == "1198" and .reserved == "0" and .total == "1198")
' <<<"$settled_balances" >/dev/null \
  || fail "finalized Receive did not reconcile canonical balances"

replay=$(post_token "/v1/operations/receive" false -sS -w '\n%{http_code}' \
  <<<"$receive_token")
[[ ${replay##*$'\n'} == 409 ]] || fail "redeemed token replay was accepted"
jq -e '.error.code == "token_already_spent"' <<<"${replay%$'\n'*}" >/dev/null \
  || fail "redeemed token replay did not return token_already_spent"

for operation_case in \
  "missing|execute|operation_not_found|404" \
  "$operation_id|execute|operation_conflict|409"; do
  case_id=${operation_case%%|*}
  remainder=${operation_case#*|}
  command=${remainder%%|*}
  remainder=${remainder#*|}
  expected_code=${remainder%%|*}
  expected_status=${remainder##*|}
  failure=$(curl -sS -w '\n%{http_code}' "${auth[@]}" -X POST \
    -H 'Content-Type: application/json' --data '{}' \
    "$base_url/v1/operations/receive/$case_id/$command")
  [[ ${failure##*$'\n'} == "$expected_status" ]] \
    || fail "$expected_code command returned the wrong status"
  jq -e --arg code "$expected_code" '.error.code == $code' \
    <<<"${failure%$'\n'*}" >/dev/null \
    || fail "$expected_code command did not return a structured error"
done

for creation_case in \
  "$spent_token|token_already_spent|409" \
  "$conflicting_token|operation_conflict|409"; do
  token=${creation_case%%|*}
  remainder=${creation_case#*|}
  expected_code=${remainder%%|*}
  expected_status=${remainder##*|}
  failure=$(post_token "/v1/operations/receive" false -sS -w '\n%{http_code}' \
    <<<"$token")
  [[ ${failure##*$'\n'} == "$expected_status" ]] \
    || fail "$expected_code creation returned the wrong status"
  jq -e --arg code "$expected_code" '.error.code == $code' \
    <<<"${failure%$'\n'*}" >/dev/null \
    || fail "$expected_code creation did not return a structured error"
done

mock_receive_status=$(curl -fsS "$base_url/__test__/status")
if rg -Fq "$receive_token" \
    <<<"$preview$prepared$canonical_prepared$executed$canonical_final$mock_receive_status" \
    || rg -Fq "$receive_token" "$daemon_log" "$stream_output"; then
  fail "Receive bearer token escaped command bodies"
fi

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
