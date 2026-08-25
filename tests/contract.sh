#!/usr/bin/env bash

set -euo pipefail

project_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
port=${OMARCHY_CASHU_TEST_PORT:-38431}
base_url="http://127.0.0.1:$port"
recovery_port=$((port + 1))
recovery_base_url="http://127.0.0.1:$recovery_port"
credential=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
state_dir=$(mktemp -d)
recovery_state_dir=$(mktemp -d)
daemon_log=$(mktemp)
recovery_daemon_log=$(mktemp)
stream_output=$(mktemp)
stream_headers=$(mktemp)
initialize_headers=$(mktemp)
recovery_headers=$(mktemp)
operation_headers=$(mktemp)
mint_headers=$(mktemp)
command_headers=$(mktemp)
result_headers=$(mktemp)
daemon_pid=""
recovery_daemon_pid=""
stream_pid=""

cleanup() {
  if [[ -n $daemon_pid ]]; then
    kill "$daemon_pid" 2>/dev/null || true
    wait "$daemon_pid" 2>/dev/null || true
  fi
  if [[ -n $recovery_daemon_pid ]]; then
    kill "$recovery_daemon_pid" 2>/dev/null || true
    wait "$recovery_daemon_pid" 2>/dev/null || true
  fi
  if [[ -n $stream_pid ]]; then
    kill "$stream_pid" 2>/dev/null || true
    wait "$stream_pid" 2>/dev/null || true
  fi
  rm -f "$daemon_log" "$recovery_daemon_log" "$stream_output" "$stream_headers" \
    "$initialize_headers" "$recovery_headers" \
    "$operation_headers" "$mint_headers" "$command_headers"
  rm -f "$result_headers"
  rm -rf "$state_dir" "$recovery_state_dir"
}
trap cleanup EXIT

fail() {
  echo "contract: $*" >&2
  echo "contract: mock log follows" >&2
  sed -n '1,160p' "$daemon_log" >&2
  echo "contract: recovery mock log follows" >&2
  sed -n '1,160p' "$recovery_daemon_log" >&2
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
jq -e '.error.code == "unauthenticated" and .error.retryable == false' \
  <<<"$missing_auth" >/dev/null || fail "missing authentication did not use the common error document"

invalid_auth=$(curl -sS -H 'Authorization: Bearer invalid' "$base_url/v1/status")
jq -e '.error.code == "unauthenticated" and .error.retryable == false' \
  <<<"$invalid_auth" >/dev/null || fail "invalid authentication did not use a stable error code"

openapi=$(curl -fsS "${auth[@]}" "$base_url/v1/openapi.json") \
  || fail "authenticated OpenAPI discovery failed"
jq -e '
  .openapi == "3.1.0"
  and ."x-cocod-interface-version" == "1"
  and (.paths as $paths | all([
    "/v1/status", "/v1/balances", "/v1/events", "/v1/mints",
    "/v1/operations/receive",
    "/v1/operations/receive/prepared", "/v1/operations/receive/in-flight",
    "/v1/operations/send",
    "/v1/operations/send/prepared", "/v1/operations/send/in-flight",
    "/v1/admin/wallet/initialize", "/v1/admin/wallet/recovery-material"
  ][]; $paths[.] != null)
  and ($paths | has("/v1/token-previews") | not)
  and ($paths | has("/v1/operations/send/max") | not))
' <<<"$openapi" >/dev/null || fail "OpenAPI discovery does not describe the mock-backed slice"

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
      {"mintUrl":"https://mint.one","name":"Mint One","trusted":true,"createdAt":"2026-08-20T12:00:00.000Z","updatedAt":"2026-08-20T12:00:00.000Z"}
    ]},
    "receivePrepared": {"items": []},
    "receiveInFlight": {"items": []},
    "sendPrepared": {"items": [{"id":"send-1","type":"send","state":"prepared","mintUrl":"https://mint.one","unit":"sat","method":"default","requestedAmount":"60","fee":"2","inputAmount":"70","needsSwap":true,"createdAt":"2026-08-20T12:00:00.000Z","updatedAt":"2026-08-20T12:00:00.000Z"}]},
    "sendInFlight": {"items": []},
    "event": {"type":"balance.updated","timestamp":"2026-08-20T12:00:01.000Z","data":{"mintUrl":"https://mint.one"}},
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
jq -e '.items[0].method == "default" and .items[0].requestedAmount == "60"
  and (.items[0].requestedAmount | type == "string")' \
  <<<"$send_prepared" >/dev/null || fail "Send Operation collection is invalid"
jq -e '.items == []' <<<"$send_in_flight" >/dev/null || fail "Send in-flight collection is invalid"

send_mint='https://mint.send.test'
curl -fsS -X POST -H 'Content-Type: application/json' \
  --data '{
    "balances":{"items":[{"mintUrl":"https://mint.send.test","unit":"sat","spendable":"100","reserved":"0","total":"100"}]},
    "mints":{"items":[{"mintUrl":"https://mint.send.test","name":"Send Mint","trusted":true,"createdAt":"2026-08-20T12:00:00.000Z","updatedAt":"2026-08-20T12:00:00.000Z"}]},
    "sendPrepared":{"items":[]},
    "sendInFlight":{"items":[]}
  }' "$base_url/__test__/resources" >/dev/null \
  || fail "could not establish funded Send resources"

for invalid_amount in 0 01 -1 1.5; do
  invalid_send=$(jq -cn --arg mint "$send_mint" --arg amount "$invalid_amount" \
    '{mintUrl:$mint,unit:"sat",amount:$amount}' \
    | curl -sS -w '\n%{http_code}' "${auth[@]}" -X POST \
        -H 'Content-Type: application/json' --data-binary @- \
        "$base_url/v1/operations/send")
  [[ ${invalid_send##*$'\n'} == 400 ]] \
    || fail "Send accepted invalid decimal amount $invalid_amount"
  jq -e '.error.code == "invalid_request"' <<<"${invalid_send%$'\n'*}" >/dev/null \
    || fail "invalid Send amount did not use a stable error code"
done

prepared_send=$(jq -cn --arg mint "$send_mint" \
  '{mintUrl:$mint,unit:"sat",amount:"60"}' \
  | curl -fsS -D "$operation_headers" "${auth[@]}" -X POST \
      -H 'Content-Type: application/json' --data-binary @- \
      "$base_url/v1/operations/send") || fail "Send preparation failed"
prepared_send_id=$(jq -er '.id' <<<"$prepared_send")
jq -e --arg id "$prepared_send_id" --arg mint "$send_mint" '
  . == {
    id:$id,type:"send",state:"prepared",mintUrl:$mint,unit:"sat",
    method:"default",requestedAmount:"60",fee:"2",inputAmount:"70",needsSwap:true,
    createdAt:"2026-08-20T12:00:00.000Z",updatedAt:"2026-08-20T12:00:00.000Z"
  }
  and ([.requestedAmount,.fee,.inputAmount] | all(type == "string"))
' <<<"$prepared_send" >/dev/null || fail "Send preparation did not return a safe Prepared Send"
rg -q '^HTTP/.* 201' "$operation_headers" \
  || fail "Send preparation did not return 201 Created"
if rg -qi '^Location:' "$operation_headers"; then
  fail "Send preparation added a noncanonical Location header"
fi
reserved_send_balances=$(curl -fsS "${auth[@]}" "$base_url/v1/balances")
jq -e --arg mint "$send_mint" '
  .items == [{mintUrl:$mint,unit:"sat",spendable:"30",reserved:"70",total:"100"}]
' <<<"$reserved_send_balances" >/dev/null \
  || fail "Prepared Send did not reserve inputs in canonical balances"
canonical_prepared_send=$(curl -fsS "${auth[@]}" \
  "$base_url/v1/operations/send/$prepared_send_id")
[[ $canonical_prepared_send == "$prepared_send" ]] \
  || fail "canonical Send resource disagreed with preparation"

cancelled_send=$(curl -fsS "${auth[@]}" -X POST \
  "$base_url/v1/operations/send/$prepared_send_id/cancel") \
  || fail "Prepared Send cancellation failed"
jq -e --arg id "$prepared_send_id" \
  '.id == $id and .state == "rolled_back"' <<<"$cancelled_send" >/dev/null \
  || fail "Send cancellation did not return the rolled-back Operation"
released_send_balances=$(curl -fsS "${auth[@]}" "$base_url/v1/balances")
jq -e --arg mint "$send_mint" '
  .items == [{mintUrl:$mint,unit:"sat",spendable:"100",reserved:"0",total:"100"}]
' <<<"$released_send_balances" >/dev/null \
  || fail "Send cancellation did not release its reservation"
jq -e '.items == []' \
  <<<"$(curl -fsS "${auth[@]}" "$base_url/v1/operations/send/prepared")" >/dev/null \
  || fail "cancelled Send remained in the Prepared Send collection"

curl -fsS -X POST -H 'Content-Type: application/json' \
  --data '{"balances":{"items":[{"mintUrl":"https://mint.send.test","unit":"sat","spendable":"50","reserved":"0","total":"50"}]}}' \
  "$base_url/__test__/resources" >/dev/null
stale_prepare=$(jq -cn --arg mint "$send_mint" \
  '{mintUrl:$mint,unit:"sat",amount:"60"}' \
  | curl -sS -w '\n%{http_code}' "${auth[@]}" -X POST \
      -H 'Content-Type: application/json' --data-binary @- \
      "$base_url/v1/operations/send")
[[ ${stale_prepare##*$'\n'} == 500 ]] \
  || fail "stale local balance did not fail canonical Send preparation"
jq -e '.error.code == "coco_error"' \
  <<<"${stale_prepare%$'\n'*}" >/dev/null \
  || fail "stale balance failure did not use canonical Coco error mapping"

curl -fsS -X POST -H 'Content-Type: application/json' \
  --data '{"balances":{"items":[{"mintUrl":"https://mint.send.test","unit":"sat","spendable":"100","reserved":"0","total":"100"}]}}' \
  "$base_url/__test__/resources" >/dev/null
full_balance_send=$(jq -cn --arg mint "$send_mint" \
  '{mintUrl:$mint,unit:"sat",amount:"100"}' \
  | curl -fsS "${auth[@]}" -X POST -H 'Content-Type: application/json' \
      --data-binary @- "$base_url/v1/operations/send") \
  || fail "full-balance Send preparation failed"
full_balance_send_id=$(jq -er '.id' <<<"$full_balance_send")
jq -e '.method == "default" and .requestedAmount == "100"
  and .fee == "0" and .inputAmount == "100"
  and .needsSwap == false' <<<"$full_balance_send" >/dev/null \
  || fail "full-balance Send preparation changed its requested amount"
executed_send=$(curl -fsS -D "$command_headers" "${auth[@]}" -X POST \
  "$base_url/v1/operations/send/$full_balance_send_id/execute") \
  || fail "Prepared Send execution failed"
send_token=$(jq -er '.result.token | select(type == "string" and length > 0)' \
  <<<"$executed_send") || fail "Send execution omitted its outgoing token"
jq -e --arg id "$full_balance_send_id" '
  .operation.id == $id and .operation.state == "pending"
  and .operation.requestedAmount == "100" and .operation.fee == "0"
  and (.operation | has("token") | not)
' <<<"$executed_send" >/dev/null \
  || fail "Send execution mixed its sensitive result into the Operation"
rg -qi '^Cache-Control: no-store' "$command_headers" \
  || fail "Send execution result is cacheable"
safe_send_lookup=$(curl -fsS "${auth[@]}" \
  "$base_url/v1/operations/send/$full_balance_send_id")
safe_send_in_flight=$(curl -fsS "${auth[@]}" \
  "$base_url/v1/operations/send/in-flight")
send_status=$(curl -fsS "$base_url/__test__/status")
if rg -Fq "$send_token" <<<"$safe_send_lookup$safe_send_in_flight$send_status" \
    || rg -Fq "$send_token" "$daemon_log" "$stream_output"; then
  fail "outgoing Send token escaped its immediate execution result"
fi

recovered_send_result=$(curl -fsS -D "$result_headers" "${auth[@]}" \
  "$base_url/v1/operations/send/$full_balance_send_id/result") \
  || fail "retained Send result was not retrievable"
[[ $(jq -er '.token' <<<"$recovered_send_result") == "$send_token" ]] \
  || fail "Send result retrieval did not return the retained token"
rg -qi '^Cache-Control: no-store' "$result_headers" \
  || fail "retrieved Send result is cacheable"

reclaimed_send=$(curl -fsS "${auth[@]}" -X POST \
  "$base_url/v1/operations/send/$full_balance_send_id/reclaim") \
  || fail "Pending Send Reclaim failed"
jq -e --arg id "$full_balance_send_id" '
  .id == $id and .type == "send" and .state == "rolled_back"
  and .method == "default" and .requestedAmount == "100"
  and .fee == "0" and .inputAmount == "100"
  and ([.requestedAmount,.fee,.inputAmount] | all(type == "string"))
  and (has("token") | not)
' <<<"$reclaimed_send" >/dev/null \
  || fail "successful Reclaim did not return the safe rolled-back Send"
reclaimed_send_balances=$(curl -fsS "${auth[@]}" "$base_url/v1/balances")
jq -e --arg mint "$send_mint" '
  .items == [{mintUrl:$mint,unit:"sat",spendable:"100",reserved:"0",total:"100"}]
' <<<"$reclaimed_send_balances" >/dev/null \
  || fail "successful Reclaim did not return Reserved Balance to Spendable Balance"
jq -e '.items == []' \
  <<<"$(curl -fsS "${auth[@]}" "$base_url/v1/operations/send/in-flight")" \
  >/dev/null || fail "reclaimed Send remained in the in-flight collection"

inconclusive_send=$(jq -cn --arg mint "$send_mint" \
  '{mintUrl:$mint,unit:"sat",amount:"60"}' \
  | curl -fsS "${auth[@]}" -X POST -H 'Content-Type: application/json' \
      --data-binary @- "$base_url/v1/operations/send") \
  || fail "inconclusive Reclaim fixture preparation failed"
inconclusive_send_id=$(jq -er '.id' <<<"$inconclusive_send")
curl -fsS "${auth[@]}" -X POST \
  "$base_url/v1/operations/send/$inconclusive_send_id/execute" >/dev/null \
  || fail "inconclusive Reclaim fixture execution failed"
curl -fsS -X POST -H 'Content-Type: application/json' \
  --data '{"sendReclaimOutcome":"reclaim_inconclusive"}' \
  "$base_url/__test__/mode" >/dev/null
inconclusive_reclaim=$(curl -sS -w '\n%{http_code}' "${auth[@]}" -X POST \
  "$base_url/v1/operations/send/$inconclusive_send_id/reclaim")
[[ ${inconclusive_reclaim##*$'\n'} == 500 ]] \
  || fail "inconclusive Reclaim returned the wrong status"
jq -e '.error.code == "coco_error" and .error.retryable == false' \
  <<<"${inconclusive_reclaim%$'\n'*}" >/dev/null \
  || fail "inconclusive Reclaim did not use canonical Coco error mapping"
jq -e --arg id "$inconclusive_send_id" '
  .id == $id and .state == "pending"
' <<<"$(curl -fsS "${auth[@]}" \
  "$base_url/v1/operations/send/$inconclusive_send_id")" >/dev/null \
  || fail "inconclusive Reclaim did not leave the Send recoverable"
jq -e --arg mint "$send_mint" '
  .items == [{mintUrl:$mint,unit:"sat",spendable:"30",reserved:"70",total:"100"}]
' <<<"$(curl -fsS "${auth[@]}" "$base_url/v1/balances")" >/dev/null \
  || fail "inconclusive Reclaim changed the Pending Send reservation"
curl -fsS "${auth[@]}" -X POST \
  "$base_url/v1/operations/send/$inconclusive_send_id/reclaim" >/dev/null \
  || fail "retry after inconclusive Reclaim did not succeed"

recipient_send=$(jq -cn --arg mint "$send_mint" \
  '{mintUrl:$mint,unit:"sat",amount:"60"}' \
  | curl -fsS "${auth[@]}" -X POST -H 'Content-Type: application/json' \
      --data-binary @- "$base_url/v1/operations/send") \
  || fail "recipient-won fixture preparation failed"
recipient_send_id=$(jq -er '.id' <<<"$recipient_send")
curl -fsS "${auth[@]}" -X POST \
  "$base_url/v1/operations/send/$recipient_send_id/execute" >/dev/null \
  || fail "recipient-won fixture execution failed"
curl -fsS -X POST -H 'Content-Type: application/json' \
  --data "$(jq -cn --arg id "$recipient_send_id" '{operationId:$id}')" \
  "$base_url/__test__/redeem-send" >/dev/null \
  || fail "recipient-won fixture redemption failed"
recipient_won=$(curl -sS -w '\n%{http_code}' "${auth[@]}" -X POST \
  "$base_url/v1/operations/send/$recipient_send_id/reclaim")
[[ ${recipient_won##*$'\n'} == 409 ]] \
  || fail "recipient-won Reclaim race returned the wrong status"
jq -e '.error.code == "invalid_operation_state" and .error.retryable == false' \
  <<<"${recipient_won%$'\n'*}" >/dev/null \
  || fail "recipient-won Reclaim race did not expose canonical terminal state"
jq -e --arg id "$recipient_send_id" '
  .id == $id and .state == "finalized"
' <<<"$(curl -fsS "${auth[@]}" \
  "$base_url/v1/operations/send/$recipient_send_id")" >/dev/null \
  || fail "recipient-won Reclaim race did not finalize the same Send"
jq -e --arg mint "$send_mint" '
  .items == [{mintUrl:$mint,unit:"sat",spendable:"30",reserved:"0",total:"30"}]
' <<<"$(curl -fsS "${auth[@]}" "$base_url/v1/balances")" >/dev/null \
  || fail "recipient-won race did not consume the Reserved Balance"
jq -e '.items == []' \
  <<<"$(curl -fsS "${auth[@]}" "$base_url/v1/operations/send/in-flight")" \
  >/dev/null || fail "recipient-won Send remained canonically active"

curl -fsS -X POST -H 'Content-Type: application/json' \
  --data "$(jq -cn --arg mint "$send_mint" '{
    balances:{items:[{mintUrl:$mint,unit:"sat",spendable:"100",reserved:"0",total:"100"}]},
    sendPrepared:{items:[]},sendInFlight:{items:[]}
  }')" "$base_url/__test__/resources" >/dev/null
unavailable_refresh_send=$(jq -cn --arg mint "$send_mint" \
  '{mintUrl:$mint,unit:"sat",amount:"60"}' \
  | curl -fsS "${auth[@]}" -X POST -H 'Content-Type: application/json' \
      --data-binary @- "$base_url/v1/operations/send")
unavailable_refresh_send_id=$(jq -er '.id' <<<"$unavailable_refresh_send")
curl -fsS "${auth[@]}" -X POST \
  "$base_url/v1/operations/send/$unavailable_refresh_send_id/execute" >/dev/null
curl -fsS -X POST -H 'Content-Type: application/json' \
  --data '{"sendRefreshError":"mint_unavailable"}' \
  "$base_url/__test__/mode" >/dev/null
unavailable_refresh=$(curl -sS -w '\n%{http_code}' "${auth[@]}" -X POST \
  "$base_url/v1/operations/send/$unavailable_refresh_send_id/refresh")
[[ ${unavailable_refresh##*$'\n'} == 500 ]] \
  || fail "unavailable Mint Send refresh returned the wrong status"
jq -e '.error.code == "coco_error" and .error.retryable == false' \
  <<<"${unavailable_refresh%$'\n'*}" >/dev/null \
  || fail "unavailable Mint Send refresh did not use canonical Coco error mapping"
jq -e --arg id "$unavailable_refresh_send_id" '.id == $id and .state == "pending"' \
  <<<"$(curl -fsS "${auth[@]}" \
  "$base_url/v1/operations/send/$unavailable_refresh_send_id")" >/dev/null \
  || fail "unavailable Mint refresh did not leave the Send recoverable"
curl -fsS "${auth[@]}" -X POST \
  "$base_url/v1/operations/send/$unavailable_refresh_send_id/reclaim" >/dev/null

receive_token='cashuAeyJ0ZXN0Ijoic2xpY2UtNC11bmtub3duLW1pbnQifQ'
cancel_token='cashuAeyJ0ZXN0Ijoic2xpY2UtNC1jYW5jZWwifQ'
invalid_token='cashuAeyJ0ZXN0Ijoic2xpY2UtNC1pbnZhbGlkIn0'
unsupported_token='cashuAeyJ0ZXN0Ijoic2xpY2UtNC11c2QifQ'
unavailable_token='cashuAeyJ0ZXN0Ijoic2xpY2UtNC1taW50LWRvd24ifQ'
spent_token='cashuAeyJ0ZXN0Ijoic2xpY2UtNC1zcGVudCJ9'
conflicting_token='cashuAeyJ0ZXN0Ijoic2xpY2UtNC1jb25mbGljdCJ9'
receive_mint='https://mint.slice4.test'

before_receive_balances=$(curl -fsS "${auth[@]}" "$base_url/v1/balances")
not_registered=$(post_token "/v1/operations/receive" false -sS -w '\n%{http_code}' \
  <<<"$receive_token")
[[ ${not_registered##*$'\n'} == 500 ]] \
  || fail "Receive preparation accepted a token from an unknown Mint"
jq -e '.error.code == "coco_error"' \
  <<<"${not_registered%$'\n'*}" >/dev/null \
  || fail "unknown-Mint preparation failure did not use canonical error mapping"

registered=$(curl -fsS -D "$mint_headers" "${auth[@]}" -X POST \
  -H 'Content-Type: application/json' \
  --data "$(jq -cn --arg mint "$receive_mint" '{mintUrl: $mint}')" \
  "$base_url/v1/mints") || fail "Known Mint registration failed"
rg -q '^HTTP/.* 201' "$mint_headers" \
  || fail "new Known Mint registration did not return 201 Created"
jq -e --arg mint "$receive_mint" \
  '.mintUrl == $mint and .trusted == false' <<<"$registered" >/dev/null \
  || fail "Known Mint registration implicitly trusted the mint"
not_trusted=$(post_token "/v1/operations/receive" false -sS -w '\n%{http_code}' \
  <<<"$receive_token")
[[ ${not_trusted##*$'\n'} == 500 ]] \
  || fail "Receive creation accepted an untrusted mint"
jq -e '.error.code == "coco_error"' \
  <<<"${not_trusted%$'\n'*}" >/dev/null \
  || fail "untrusted Mint failure did not use canonical error mapping"

trusted=$(curl -fsS -D "$mint_headers" "${auth[@]}" -X POST \
  -H 'Content-Type: application/json' \
  --data "$(jq -cn --arg mint "$receive_mint" '{mintUrl: $mint}')" \
  "$base_url/v1/mints/trust") || fail "Known Mint trust failed"
rg -q '^HTTP/.* 200' "$mint_headers" \
  || fail "Known Mint trust did not return 200 OK"
jq -e --arg mint "$receive_mint" \
  '.mintUrl == $mint and .trusted == true' <<<"$trusted" >/dev/null \
  || fail "Known Mint trust did not return the updated resource"

for token in "$invalid_token" "$unavailable_token"; do
  failure=$(post_token "/v1/operations/receive" false -sS -w '\n%{http_code}' \
    <<<"$token")
  [[ ${failure##*$'\n'} == 500 ]] \
    || fail "canonical Receive preparation failure returned the wrong status"
  jq -e '.error.code == "coco_error" and .error.retryable == false' \
    <<<"${failure%$'\n'*}" >/dev/null \
    || fail "Receive preparation failure did not use canonical error mapping"
done

unsupported_receive=$(post_token "/v1/operations/receive" false -fsS \
  <<<"$unsupported_token") || fail "non-sat Receive preparation failed"
unsupported_receive_id=$(jq -er '.id' <<<"$unsupported_receive")
jq -e --arg id "$unsupported_receive_id" '
  .id == $id and .state == "prepared" and .unit == "usd"
  and .amount == "12" and .fee == "1"
' <<<"$unsupported_receive" >/dev/null \
  || fail "non-sat Receive did not expose its canonical safe unit"
unsupported_cancel=$(curl -fsS "${auth[@]}" -X POST \
  "$base_url/v1/operations/receive/$unsupported_receive_id/cancel") \
  || fail "non-sat Prepared Receive could not be cancelled"
jq -e --arg id "$unsupported_receive_id" \
  '.id == $id and .state == "rolled_back" and .unit == "usd"' \
  <<<"$unsupported_cancel" >/dev/null \
  || fail "non-sat Receive cancellation changed its canonical unit"

cancelled_prepare=$(post_token "/v1/operations/receive" false -fsS \
  <<<"$cancel_token") || fail "cancellable Receive creation failed"
cancelled_id=$(jq -er '.id' <<<"$cancelled_prepare")
cancelled=$(curl -fsS -D "$command_headers" "${auth[@]}" -X POST \
  "$base_url/v1/operations/receive/$cancelled_id/cancel") \
  || fail "Prepared Receive cancellation failed"
rg -q '^HTTP/.* 200' "$command_headers" \
  || fail "Receive cancellation did not return 200 OK"
jq -e --arg id "$cancelled_id" '
  .id == $id and .type == "receive" and .state == "rolled_back"
  and .amount == "400" and .fee == "1"
  and (keys | sort) == (["amount","createdAt","fee","id","mintUrl","state","type","unit","updatedAt"] | sort)
' <<<"$cancelled" >/dev/null || fail "cancel did not return the updated Operation"
[[ $(curl -fsS "${auth[@]}" "$base_url/v1/balances") == "$before_receive_balances" ]] \
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
    createdAt: "2026-08-20T12:00:00.000Z",
    updatedAt: "2026-08-20T12:00:00.000Z"
  }
' <<<"$prepared" >/dev/null || fail "Receive creation did not return a safe Prepared Receive"
rg -qi '^Cache-Control: no-store' "$operation_headers" \
  || fail "token-bearing Receive creation response is cacheable"
rg -q '^HTTP/.* 201' "$operation_headers" \
  || fail "Receive creation did not return 201 Created"
if rg -qi '^Location:' "$operation_headers"; then
  fail "Receive creation added a noncanonical Location header"
fi

duplicate=$(post_token "/v1/operations/receive" false -sS -w '\n%{http_code}' \
  <<<"$receive_token")
[[ ${duplicate##*$'\n'} == 500 ]] \
  || fail "one bearer token created two Prepared Receives"
jq -e '.error.code == "coco_error"' <<<"${duplicate%$'\n'*}" >/dev/null \
  || fail "duplicate Receive creation did not use canonical error mapping"

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
  "$base_url/v1/operations/receive/$operation_id/execute") \
  || fail "Prepared Receive execution failed"
rg -q '^HTTP/.* 200' "$command_headers" \
  || fail "Receive execution did not return 200 OK"
jq -e --arg id "$operation_id" '
  .id == $id and .type == "receive" and .state == "finalized"
  and .amount == "1200" and .fee == "2"
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
[[ ${replay##*$'\n'} == 500 ]] || fail "redeemed token replay was accepted"
jq -e '.error.code == "coco_error"' <<<"${replay%$'\n'*}" >/dev/null \
  || fail "redeemed token replay did not use canonical error mapping"

for operation_case in \
  "missing|execute|not_found|404" \
  "$operation_id|execute|invalid_operation_state|409"; do
  case_id=${operation_case%%|*}
  remainder=${operation_case#*|}
  command=${remainder%%|*}
  remainder=${remainder#*|}
  expected_code=${remainder%%|*}
  expected_status=${remainder##*|}
  failure=$(curl -sS -w '\n%{http_code}' "${auth[@]}" -X POST \
    "$base_url/v1/operations/receive/$case_id/$command")
  [[ ${failure##*$'\n'} == "$expected_status" ]] \
    || fail "$expected_code command returned the wrong status"
  jq -e --arg code "$expected_code" '.error.code == $code' \
    <<<"${failure%$'\n'*}" >/dev/null \
    || fail "$expected_code command did not return a structured error"
done

for creation_case in \
  "$spent_token|coco_error|500" \
  "$conflicting_token|coco_error|500"; do
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
    <<<"$prepared$canonical_prepared$executed$canonical_final$mock_receive_status" \
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
    "event":{"type":"balance.updated","timestamp":"2026-08-20T12:00:02.000Z","data":{"mintUrl":"https://mint.one"}},
    "delivery":"partial"
  }' "$base_url/__test__/resources" >/dev/null
for _attempt in {1..40}; do
  rg -Fqx 'data: {"type":"balance.updated","timestamp":"2026-08-20T12:00:02.000Z","data":{"mintUrl":"https://mint.one"}}' \
    "$stream_output" && break
  sleep 0.05
done
rg -qi '^Content-Type: text/event-stream' "$stream_headers" \
  || fail "events did not use the SSE content type"
rg -q '^retry: 3000$' "$stream_output" || fail "event stream omitted the server retry hint"
rg -Fqx 'data: {"type":"balance.updated","timestamp":"2026-08-20T12:00:02.000Z","data":{"mintUrl":"https://mint.one"}}' \
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

# A second deterministic fixture proves that durable safe Receive state survives
# process replacement on both sides of the Wallet commit point. The dropped
# execute responses model the client losing contact after execution begins.
mkdir -p "$recovery_state_dir/credentials/generation-1"
printf '%s\n' "$credential" >"$recovery_state_dir/credentials/generation-1/client"
chmod 700 "$recovery_state_dir" "$recovery_state_dir/credentials" \
  "$recovery_state_dir/credentials/generation-1"
chmod 600 "$recovery_state_dir/credentials/generation-1/client"
ln -s generation-1 "$recovery_state_dir/credentials/current"

COCOD_STATE_DIR="$recovery_state_dir" python3 "$project_dir/scripts/mock-cocod.py" \
  --port "$recovery_port" >"$recovery_daemon_log" 2>&1 &
recovery_daemon_pid=$!
for _attempt in {1..40}; do
  curl -fsS "$recovery_base_url/__test__/status" >/dev/null 2>&1 && break
  sleep 0.05
done
curl -fsS "${auth[@]}" -X POST -H 'Content-Type: application/json' --data '{}' \
  "$recovery_base_url/v1/admin/wallet/initialize" >/dev/null \
  || fail "recovery fixture Wallet initialization failed"
curl -fsS "${auth[@]}" -X POST -H 'Content-Type: application/json' \
  --data "$(jq -cn --arg mint "$receive_mint" '{mintUrl: $mint}')" \
  "$recovery_base_url/v1/mints" >/dev/null \
  || fail "recovery fixture Mint registration failed"
curl -fsS "${auth[@]}" -X POST -H 'Content-Type: application/json' \
  --data "$(jq -cn --arg mint "$receive_mint" '{mintUrl: $mint}')" \
  "$recovery_base_url/v1/mints/trust" >/dev/null \
  || fail "recovery fixture Mint trust failed"

send_recovery_mint='https://mint.slice7.test'
curl -fsS -X POST -H 'Content-Type: application/json' \
  --data "$(jq -cn --arg receiveMint "$receive_mint" \
    --arg sendMint "$send_recovery_mint" '{
      balances:{items:[{
        mintUrl:$sendMint,unit:"sat",spendable:"100",reserved:"0",total:"100"
      }]},
      mints:{items:[
        {mintUrl:$receiveMint,name:"Receive Mint",trusted:true,
          createdAt:"2026-08-20T12:00:00.000Z",updatedAt:"2026-08-20T12:00:00.000Z"},
        {mintUrl:$sendMint,name:"Recovery Send Mint",trusted:true,
          createdAt:"2026-08-20T12:00:00.000Z",updatedAt:"2026-08-20T12:00:00.000Z"}
      ]}
    }')" "$recovery_base_url/__test__/resources" >/dev/null \
  || fail "could not fund the recovered Send fixture"
recovery_send=$(jq -cn --arg mint "$send_recovery_mint" \
  '{mintUrl:$mint,unit:"sat",amount:"60"}' \
  | curl -fsS "${auth[@]}" -X POST -H 'Content-Type: application/json' \
      --data-binary @- "$recovery_base_url/v1/operations/send") \
  || fail "recovered Send preparation failed"
recovery_send_id=$(jq -er '.id' <<<"$recovery_send")
unavailable_send_result=$(curl -sS -w '\n%{http_code}' "${auth[@]}" \
  "$recovery_base_url/v1/operations/send/$recovery_send_id/result")
[[ ${unavailable_send_result##*$'\n'} == 409 ]] \
  || fail "Prepared Send result did not remain unavailable"
jq -e '.error.code == "operation_result_not_available" and .error.retryable == false' \
  <<<"${unavailable_send_result%$'\n'*}" >/dev/null \
  || fail "unavailable Send result was not a structured retryable state"
curl -fsS -X POST -H 'Content-Type: application/json' \
  --data '{"sendExecuteInterruption":"after_commit"}' \
  "$recovery_base_url/__test__/mode" >/dev/null
if curl -fsS "${auth[@]}" -X POST \
    "$recovery_base_url/v1/operations/send/$recovery_send_id/execute" >/dev/null 2>&1; then
  fail "dropped Send execute response returned an optimistic success"
fi
retained_send_result_before_restart=$(curl -fsS "${auth[@]}" \
  "$recovery_base_url/v1/operations/send/$recovery_send_id/result") \
  || fail "committed Send result was unavailable before restart"
retained_send_token_before_restart=$(jq -er \
  '.token | select(type == "string" and startswith("cashuA"))' \
  <<<"$retained_send_result_before_restart") \
  || fail "committed Send result omitted its original token"
jq -e --arg id "$recovery_send_id" \
  --slurpfile state "$recovery_state_dir/mock-runtime-state.json" \
  '$state[0].sendResults[$id] == .token' \
  <<<"$retained_send_result_before_restart" >/dev/null \
  || fail "mock persisted only enough data to regenerate the Send result"

curl -fsS -X POST -H 'Content-Type: application/json' \
  --data '{"receiveInterruption":"before_commit"}' \
  "$recovery_base_url/__test__/mode" >/dev/null
before_interrupt=$(jq -Rn '{token: input}' <<<"$cancel_token" \
  | curl -fsS "${auth[@]}" -X POST -H 'Content-Type: application/json' \
      --data-binary @- "$recovery_base_url/v1/operations/receive") \
  || fail "before-commit Receive preparation failed"
before_interrupt_id=$(jq -er '.id' <<<"$before_interrupt")
if curl -fsS "${auth[@]}" -X POST \
    "$recovery_base_url/v1/operations/receive/$before_interrupt_id/execute" >/dev/null 2>&1; then
  fail "before-commit interruption returned an optimistic execute success"
fi

curl -fsS -X POST -H 'Content-Type: application/json' \
  --data '{"receiveInterruption":"after_commit"}' \
  "$recovery_base_url/__test__/mode" >/dev/null
after_interrupt=$(jq -Rn '{token: input}' <<<"$receive_token" \
  | curl -fsS "${auth[@]}" -X POST -H 'Content-Type: application/json' \
      --data-binary @- "$recovery_base_url/v1/operations/receive") \
  || fail "after-commit Receive preparation failed"
after_interrupt_id=$(jq -er '.id' <<<"$after_interrupt")
if curl -fsS "${auth[@]}" -X POST \
    "$recovery_base_url/v1/operations/receive/$after_interrupt_id/execute" >/dev/null 2>&1; then
  fail "after-commit interruption returned an optimistic execute success"
fi

kill "$recovery_daemon_pid"
wait "$recovery_daemon_pid" 2>/dev/null || true
recovery_daemon_pid=""
COCOD_STATE_DIR="$recovery_state_dir" python3 "$project_dir/scripts/mock-cocod.py" \
  --port "$recovery_port" >>"$recovery_daemon_log" 2>&1 &
recovery_daemon_pid=$!
for _attempt in {1..40}; do
  curl -fsS "$recovery_base_url/__test__/status" >/dev/null 2>&1 && break
  sleep 0.05
done

recovered_in_flight=$(curl -fsS "${auth[@]}" \
  "$recovery_base_url/v1/operations/receive/in-flight") \
  || fail "interrupted Receives were not discoverable after restart"
jq -e --arg before "$before_interrupt_id" --arg after "$after_interrupt_id" '
  (.items | length) == 2
  and (.items | any(.id == $before and .state == "executing"
    and .amount == "400" and (.amount | type == "string")))
  and (.items | any(.id == $after and .state == "executing"
    and .amount == "1200" and (.fee | type == "string")))
' <<<"$recovered_in_flight" >/dev/null \
  || fail "restart did not rehydrate the same safe executing Operations"

recovered_send_in_flight=$(curl -fsS "${auth[@]}" \
  "$recovery_base_url/v1/operations/send/in-flight") \
  || fail "Pending Send was not discoverable after restart"
jq -e --arg id "$recovery_send_id" '
  .items == [{
    id:$id,type:"send",state:"pending",mintUrl:"https://mint.slice7.test",
    unit:"sat",method:"default",requestedAmount:"60",fee:"2",inputAmount:"70",needsSwap:true,
    createdAt:"2026-08-20T12:00:00.000Z",updatedAt:"2026-08-20T12:00:00.000Z"
  }]
  and ([.items[0].requestedAmount,.items[0].fee,.items[0].inputAmount]
    | all(type == "string"))
' <<<"$recovered_send_in_flight" >/dev/null \
  || fail "restart did not recover the same safe Pending Send"
recovered_send_result=$(curl -fsS -D "$result_headers" "${auth[@]}" \
  "$recovery_base_url/v1/operations/send/$recovery_send_id/result") \
  || fail "dropped Send execute result was not recoverable after restart"
recovered_send_token=$(jq -er '.token | select(type == "string" and startswith("cashuA"))' \
  <<<"$recovered_send_result") \
  || fail "recovered Send result omitted its token"
[[ $recovered_send_token == "$retained_send_token_before_restart" ]] \
  || fail "restart regenerated a different Send bearer result"
[[ $(curl -fsS "${auth[@]}" \
  "$recovery_base_url/v1/operations/send/$recovery_send_id/result") \
  == "$recovered_send_result" ]] \
  || fail "repeated Send result retrieval returned a different token"
rg -qi '^Cache-Control: no-store' "$result_headers" \
  || fail "recovered Send result is cacheable"
recovered_send_balances=$(curl -fsS "${auth[@]}" "$recovery_base_url/v1/balances")
jq -e --arg mint "$send_recovery_mint" '
  .items | any(.mintUrl == $mint and .unit == "sat"
    and .spendable == "30" and .reserved == "70" and .total == "100"
    and ([.spendable,.reserved,.total] | all(type == "string")))
' <<<"$recovered_send_balances" >/dev/null \
  || fail "recovered Pending Send did not preserve its Reserved Balance"

before_refreshed=$(curl -fsS "${auth[@]}" -X POST \
  "$recovery_base_url/v1/operations/receive/$before_interrupt_id/refresh") \
  || fail "before-commit Receive refresh failed"
after_refreshed=$(curl -fsS "${auth[@]}" -X POST \
  "$recovery_base_url/v1/operations/receive/$after_interrupt_id/refresh") \
  || fail "after-commit Receive refresh failed"
jq -e --arg id "$before_interrupt_id" \
  '.id == $id and .state == "rolled_back"' <<<"$before_refreshed" >/dev/null \
  || fail "pre-commit interruption did not reconcile to rolled_back"
jq -e --arg id "$after_interrupt_id" \
  '.id == $id and .state == "finalized"' <<<"$after_refreshed" >/dev/null \
  || fail "post-commit interruption did not reconcile to finalized"
recovered_balances=$(curl -fsS "${auth[@]}" "$recovery_base_url/v1/balances")
jq -e --arg mint "$receive_mint" '
  .items | any(.mintUrl == $mint and .unit == "sat"
    and .spendable == "1198" and .reserved == "0" and .total == "1198")
' <<<"$recovered_balances" >/dev/null \
  || fail "refresh duplicated or lost the committed Receive balance"
recovery_replay=$(jq -Rn '{token: input}' <<<"$receive_token" \
  | curl -sS -w '\n%{http_code}' "${auth[@]}" -X POST \
      -H 'Content-Type: application/json' --data-binary @- \
      "$recovery_base_url/v1/operations/receive")
[[ ${recovery_replay##*$'\n'} == 500 ]] \
  || fail "recovered token replay created a second Receive"
jq -e '.error.code == "coco_error"' \
  <<<"${recovery_replay%$'\n'*}" >/dev/null \
  || fail "recovered token replay did not remain actionable"
[[ $(curl -fsS "${auth[@]}" "$recovery_base_url/v1/balances") \
    == "$recovered_balances" ]] \
  || fail "recovered token replay credited Spendable Balance twice"
recovery_status=$(curl -fsS "$recovery_base_url/__test__/status")
jq -e '
  .receiveCreateRequests == 1
  and .receiveExecuteRequests == 0
  and .receiveRefreshRequests == 2
  and .receiveOperationCount == 2
  and .sendCreateRequests == 0
  and .sendExecuteRequests == 0
  and .sendResultRequests == 2
  and .sendOperationCount == 1
' <<<"$recovery_status" >/dev/null \
  || fail "restart replay created or re-executed an Operation"
if rg -Fq "$receive_token" "$recovery_state_dir/mock-runtime-state.json" \
    || rg -Fq "$cancel_token" "$recovery_state_dir/mock-runtime-state.json" \
    || rg -qi 'proof|credential|mnemonic' "$recovery_state_dir/mock-runtime-state.json"; then
  fail "durable recovery fixture persisted sensitive material outside its Send result"
fi

echo "contract: cocod v1 auth, lifecycle, resources, decimal strings, errors, SSE, and redaction passed"
