#!/usr/bin/env bash

set -euo pipefail

project_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
port=${OMARCHY_CASHU_TEST_PORT:-38433}
base_url="http://127.0.0.1:$port"
credential=BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB
state_dir=$(mktemp -d)
runtime_dir=$(mktemp -d)
missing_state_dir=$(mktemp -d)
shell_qml="$runtime_dir/shell.qml"
mock_log=$(mktemp)
shell_log=$(mktemp)
mock_pid=""
shell_pid=""

cleanup() {
  wl-copy --clear 2>/dev/null || true
  if [[ -n $shell_pid ]]; then
    kill "$shell_pid" 2>/dev/null || true
    wait "$shell_pid" 2>/dev/null || true
  fi
  if [[ -n $mock_pid ]]; then
    kill "$mock_pid" 2>/dev/null || true
    wait "$mock_pid" 2>/dev/null || true
  fi
  rm -f "$mock_log" "$shell_log"
  rm -rf "$runtime_dir" "$state_dir" "$missing_state_dir"
}
trap cleanup EXIT

fail() {
  echo "runtime: $*" >&2
  echo "runtime: shell log follows" >&2
  sed -n '1,240p' "$shell_log" >&2
  echo "runtime: mock log follows" >&2
  sed -n '1,160p' "$mock_log" >&2
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

bar_call() {
  quickshell ipc --any-display -p "$shell_qml" call \
    io.github.egge21m.omarchy-cashu.runtime-test barSnapshot 2>/dev/null
}

panel_action() {
  quickshell ipc --any-display -p "$shell_qml" call \
    io.github.egge21m.omarchy-cashu.runtime-test "$@" 2>/dev/null
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
  fail "adapter did not satisfy: $expression; last snapshot: ${value:-<empty>}"
}

wait_panel_snapshot() {
  local expression=$1
  local value=""
  for _attempt in {1..200}; do
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
  for _attempt in {1..200}; do
    value=$(curl -fsS "$base_url/__test__/status" 2>/dev/null || true)
    jq -e "$expression" <<<"$value" >/dev/null 2>&1 && {
      printf '%s\n' "$value"
      return 0
    }
    sleep 0.05
  done
  fail "mock did not satisfy: $expression; last status: ${value:-<empty>}"
}

set_sensitive_clipboard() {
  local value=$1
  wl-copy --clear 2>/dev/null || true
  wait_clipboard_owner empty
  printf '%s' "$value" | wl-copy --sensitive
  wait_clipboard_owner ready
  panel_call >/dev/null || true
}

wait_clipboard_owner() {
  local expected=$1
  for _attempt in {1..200}; do
    if wl-paste --list-types 2>/dev/null | rg -q '.'; then
      [[ $expected == "ready" ]] && return 0
    else
      [[ $expected == "empty" ]] && return 0
    fi
    sleep 0.05
  done
  fail "Wayland clipboard ownership did not become $expected"
}

open_receive_panel() {
  [[ $(panel_action openPanel) == "ok" ]] \
    || fail "panel could not be opened for Receive"
  [[ $(panel_action openReceive) == "ok" ]] \
    || fail "Receive entry point was unavailable"
  wait_panel_snapshot '
    .receiveViewState == "entry"
    and .receiveInputVisible == true
  ' >/dev/null
  printf '%s\n' "ok"
}

require_receive_action() {
  local action=$1
  local description=$2
  local result
  result=$(panel_action "$action" || true)
  [[ $result == "ok" ]] \
    || fail "$description was rejected; $action returned ${result:-<empty>}"
}

close_receive_panel() {
  local scenario=$1
  require_receive_action cancelReceive "Receive cancellation after $scenario"
  wait_panel_snapshot '
    .receiveViewState == "closed"
    and .receiveTextPresent == false
  ' >/dev/null
}

prepare_clipboard_receive() {
  local token=$1
  set_sensitive_clipboard "$token"
  open_receive_panel >/dev/null
  require_receive_action pasteReceive "Receive Paste action"
  wait_panel_snapshot '.receiveTextPresent == true' >/dev/null
  require_receive_action prepareReceive "Receive preparation"
}

prepare_receive_fixture() {
  local token=$1
  jq -Rn '{token: input}' <<<"$token" \
    | curl -fsS -H "Authorization: Bearer $credential" -X POST \
        -H 'Content-Type: application/json' --data-binary @- \
        "$base_url/v1/operations/receive"
}

fund_send_fixture() {
  local spendable=$1
  wait_mock_status '.resourceRequestsActive == 0' >/dev/null
  jq -cn --arg amount "$spendable" '{
    balances:{items:[{
      mintUrl:"https://mint.one",unit:"sat",spendable:$amount,
      reserved:"0",total:$amount
    }]},
    mints:{items:[{
      mintUrl:"https://mint.one",name:"Mint One",trusted:true,
      createdAt:"2026-08-20T12:00:00.000Z",updatedAt:"2026-08-20T12:00:00.000Z"
    }]},
    sendPrepared:{items:[]},sendInFlight:{items:[]}
  }' | curl -fsS -X POST -H 'Content-Type: application/json' \
    --data-binary @- "$base_url/__test__/resources" >/dev/null
  adapter_call reconnect >/dev/null
  wait_snapshot ".connectionState == \"connected\"
    and .spendableBalance == \"$spendable\"
    and .reservedBalance == \"0\"
    and .activeTransfers == []" >/dev/null
}

create_pending_send_fixture() {
  local amount=$1
  local prepared operation_id executed
  prepared=$(jq -cn --arg amount "$amount" '{
    mintUrl:"https://mint.one",unit:"sat",amount:$amount
  }' | curl -fsS -H "Authorization: Bearer $credential" -X POST \
    -H 'Content-Type: application/json' --data-binary @- \
    "$base_url/v1/operations/send")
  operation_id=$(jq -r '.id' <<<"$prepared")
  executed=$(curl -fsS -H "Authorization: Bearer $credential" -X POST \
    "$base_url/v1/operations/send/$operation_id/execute")
  jq -r '[.operation.id,.result.token] | @tsv' <<<"$executed"
}

open_send_flow() {
  local amount=$1
  local mint_url=${2:-https://mint.one}
  [[ $(panel_action openPanel) == "ok" ]] \
    || fail "panel could not be opened for Send"
  [[ $(panel_action openSend) == "ok" ]] \
    || fail "Send entry point was unavailable"
  [[ $(panel_action setSendAmount "$amount") == "ok" ]] \
    || fail "Send amount $amount could not be entered"
  [[ $(panel_action selectSendMint "$mint_url") == "ok" ]] \
    || fail "Trusted Mint $mint_url could not be selected"
}

prepare_send_flow() {
  local amount=$1
  local mint_url=${2:-https://mint.one}
  open_send_flow "$amount" "$mint_url"
  [[ $(panel_action prepareSend) == "ok" ]] \
    || fail "Send for $amount sat could not be prepared"
  wait_panel_snapshot '.sendViewState == "review"' >/dev/null
}

mkdir -p "$state_dir/credentials/generation-1"
printf '%s\n' "$credential" >"$state_dir/credentials/generation-1/client"
chmod 700 "$state_dir" "$state_dir/credentials" "$state_dir/credentials/generation-1"
chmod 600 "$state_dir/credentials/generation-1/client"
ln -s generation-1 "$state_dir/credentials/current"

cp "$project_dir/Service.qml" "$runtime_dir/Service.qml"
cp "$project_dir/Panel.qml" "$runtime_dir/Panel.qml"
cp "$project_dir/ReceiveFlow.qml" "$runtime_dir/ReceiveFlow.qml"
cp "$project_dir/SendFlow.qml" "$runtime_dir/SendFlow.qml"
cp "$project_dir/BarWidget.qml" "$runtime_dir/BarWidget.qml"
cp "$project_dir/tests/runtime-shell.qml" "$shell_qml"
ln -s /usr/share/omarchy/shell/Commons "$runtime_dir/Commons"
ln -s /usr/share/omarchy/shell/Ui "$runtime_dir/Ui"

COCOD_STATE_DIR="$state_dir" python3 "$project_dir/scripts/mock-cocod.py" \
  --port "$port" >"$mock_log" 2>&1 &
mock_pid=$!
for _attempt in {1..40}; do
  curl -fsS "$base_url/__test__/status" >/dev/null 2>&1 && break
  sleep 0.05
done

COCOD_STATE_DIR="$state_dir" OMARCHY_CASHU_DAEMON_URL="$base_url" \
  quickshell --no-color -p "$shell_qml" >"$shell_log" 2>&1 &
shell_pid=$!

wait_snapshot '
  .connectionState == "connected"
  and .compatibilityState == "compatible"
  and .receiveAvailable == true
  and .sendAvailable == true
  and .walletState == "uninitialized"
  and .spendableBalance == "0"
  and .reservedBalance == "0"
  and .trustedMintCount == 0
  and .activeTransfers == []
  and .creating == false
  and .barAttention == true
  and .barActive == false
  and .setupTitle == "Connected to cocod"
' >/dev/null
wait_panel_snapshot '
  .walletState == "uninitialized"
  and .balancesAvailable == true
  and .spendableBalance == "0"
  and .reservedBalance == "0"
  and .retryVisible == false
  and .createVisible == true
  and .createEnabled == true
  and .recoveryEntryVisible == false
' >/dev/null
wait_mock_status '
  .authenticatedV1Requests >= 2
  and .authorizationFailures == 0
  and .resourceRequests.openapi >= 1
  and .resourceRequests.status >= 1
  and .resourceRequests.balances == 0
' >/dev/null

curl -fsS -X POST -H 'Content-Type: application/json' \
  --data '{"resources":"ok","createDelayMs":250,"createSessionPolls":3}' \
  "$base_url/__test__/mode" >/dev/null
[[ $(panel_action createWallet) == "ok" ]] \
  || fail "explicit Create Wallet action was unavailable"
wait_snapshot '.creating == true and .walletState == "uninitialized"' >/dev/null
[[ $(panel_action createWallet) == "disabled" ]] \
  || fail "duplicate Create Wallet action remained available"
wait_mock_status '.createRequests == 1' >/dev/null
wait_mock_status '.remainingSessionStartPolls == 0' >/dev/null

wait_snapshot '
  .walletState == "unlocked"
  and .creating == false
  and .spendableBalance == "0"
  and .reservedBalance == "0"
  and .activeTransfers == []
  and .trustedMintCount == 0
' >/dev/null
wait_mock_status '
  .resourceRequests.balances >= 1
  and .resourceRequests.mints >= 1
  and .resourceRequests.receivePrepared >= 1
  and .resourceRequests.receiveInFlight >= 1
  and .resourceRequests.sendPrepared >= 1
  and .resourceRequests.sendInFlight >= 1
  and .streamConnections == 1
' >/dev/null

[[ $(panel_action openPanel) == "ok" ]] \
  || fail "panel could not be opened for canonical transfer actions"
[[ $(panel_action openReceive) == "ok" ]] \
  || fail "Receive entry point was unavailable with canonical OpenAPI"
[[ $(panel_action cancelReceive) == "ok" ]] \
  || fail "canonical Receive entry point could not be dismissed"
[[ $(panel_action openSend) == "ok" ]] \
  || fail "Send entry point was unavailable with canonical OpenAPI"
[[ $(panel_action cancelSend) == "ok" ]] \
  || fail "canonical Send entry point could not be dismissed"

kill "$shell_pid"
wait "$shell_pid" 2>/dev/null || true
shell_pid=""
COCOD_STATE_DIR="$state_dir" OMARCHY_CASHU_DAEMON_URL="$base_url" \
  quickshell --no-color -p "$shell_qml" >"$shell_log" 2>&1 &
shell_pid=$!
wait_snapshot '.walletState == "unlocked" and .creating == false' >/dev/null
wait_mock_status '.createRequests == 1 and .streamConnections == 1' >/dev/null

panel_action openPanel >/dev/null
[[ $(panel_action confirmRecoveryPhrase) == "disabled" ]] \
  || fail "Recovery Phrase could be requested without its warning"
wait_mock_status '.recoveryMaterialRequests == 0' >/dev/null
[[ $(panel_action openRecoveryPhrase) == "ok" ]] \
  || fail "Recovery Phrase warning could not be opened"
wait_panel_snapshot '
  .recoveryViewState == "warning"
  and .recoveryWarningVisible == true
  and .recoveryPhraseVisible == false
' >/dev/null
[[ $(panel_action leaveRecoveryPhrase) == "ok" ]] \
  || fail "Recovery Phrase warning could not be cancelled"
wait_mock_status '.recoveryMaterialRequests == 0' >/dev/null
panel_action openRecoveryPhrase >/dev/null
[[ $(panel_action confirmRecoveryPhrase) == "ok" ]] \
  || fail "confirmed Recovery Phrase retrieval was unavailable"
wait_mock_status '.recoveryMaterialRequests == 1 and .recoveryMaterialResponses == 1' >/dev/null
panel_snapshot=$(wait_panel_snapshot '
  .recoveryViewState == "revealed"
  and .recoveryPhraseVisible == true
')
adapter_snapshot=$(adapter_call snapshot)
if rg -q 'abandon' <<<"$adapter_snapshot$panel_snapshot" \
    || rg -Fq "$credential" <<<"$adapter_snapshot$panel_snapshot"; then
  fail "a Recovery Phrase or Client Credential escaped diagnostics"
fi
panel_action leaveRecoveryPhrase >/dev/null
wait_panel_snapshot '.recoveryViewState == "closed" and .recoveryPhraseVisible == false' >/dev/null

receive_token='cashuAeyJ0ZXN0Ijoic2xpY2UtNC11bmtub3duLW1pbnQifQ'
recovery_token='cashuAeyJ0ZXN0Ijoic2xpY2UtNC1jYW5jZWwifQ'
pending_recovery_token='cashuAeyJ0ZXN0Ijoic2xpY2UtNi1wZW5kaW5nIn0'
rotation_recovery_token='cashuAeyJ0ZXN0Ijoic2xpY2UtNi1yb3RhdGlvbiJ9'
concurrent_recovery_token='cashuAeyJ0ZXN0Ijoic2xpY2UtNi1jb25jdXJyZW50In0'
invalid_token='cashuAeyJ0ZXN0Ijoic2xpY2UtNC1pbnZhbGlkIn0'
unsupported_token='cashuAeyJ0ZXN0Ijoic2xpY2UtNC11c2QifQ'
unavailable_token='cashuAeyJ0ZXN0Ijoic2xpY2UtNC1taW50LWRvd24ifQ'
conflicting_token='cashuAeyJ0ZXN0Ijoic2xpY2UtNC1jb25mbGljdCJ9'
not_registered_token='cashuAeyJ0ZXN0Ijoic2xpY2UtNC1ub3QtcmVnaXN0ZXJlZCJ9'
not_trusted_token='cashuAeyJ0ZXN0Ijoic2xpY2UtNC1ub3QtdHJ1c3RlZCJ9'
not_found_token='cashuAeyJ0ZXN0Ijoic2xpY2UtNC1ub3QtZm91bmQifQ'

set_sensitive_clipboard "$receive_token"
[[ $(open_receive_panel) == "ok" ]] \
  || fail "Receive entry point was unavailable"
panel_snapshot=$(wait_panel_snapshot '
  .receiveViewState == "entry"
  and .receiveInputVisible == true
  and .receiveInputFocused == true
  and .receiveTextPresent == false
  and .receivePasteVisible == true
  and .receiveClipboardReads == 0
  and .keyCatcherBlocked == true
')
if rg -Fq "$receive_token" <<<"$(adapter_call snapshot)$panel_snapshot"; then
  fail "opening Receive read or exposed the clipboard token"
fi
wait_mock_status '
  .receiveCreateRequests == 0
' >/dev/null

wtype 'x'
wait_panel_snapshot '
  .receiveViewState == "entry"
  and .receiveTextPresent == true
  and .receiveClipboardReads == 0
' >/dev/null
close_receive_panel "manual entry"

curl -fsS -X POST -H 'Content-Type: application/json' \
  --data "$(jq -cn '{
    mints:{items:[{
      mintUrl:"https://mint.slice4.test",name:"Slice 4 Mint",trusted:true,
      createdAt:"2026-08-20T12:00:00.000Z",updatedAt:"2026-08-20T12:00:00.000Z"
    }]},
    event:{type:"mint.updated",timestamp:"2026-08-20T12:00:00.000Z",
      data:{mintUrl:"https://mint.slice4.test"}}
  }')" "$base_url/__test__/resources" >/dev/null
wait_snapshot '.trustedMintCount == 1' >/dev/null

open_receive_panel >/dev/null
require_receive_action pasteReceive "explicit Receive Paste action"
wait_panel_snapshot '
  .receiveViewState == "entry"
  and .receiveTextPresent == true
  and .receiveClipboardReads == 1
' >/dev/null
before_prepared_receive=$(curl -fsS "$base_url/__test__/status")
before_prepared_receive_creates=$(jq -r '.receiveCreateRequests' \
  <<<"$before_prepared_receive")
before_prepared_receive_cancels=$(jq -r '.receiveCancelRequests' \
  <<<"$before_prepared_receive")
require_receive_action prepareReceive "canonical Receive preparation"
panel_snapshot=$(wait_panel_snapshot '
  .receiveViewState == "review"
  and .receivePreparedAmount == "1200"
  and .receivePreparedFee == "2"
  and .receivePreparedUnit == "sat"
  and .receivePreparedMint == "https://mint.slice4.test"
  and .receiveConfirmEnabled == true
')
if rg -Fq "$receive_token" <<<"$(adapter_call snapshot)$panel_snapshot"; then
  fail "Prepared Receive review exposed bearer-token text"
fi
close_receive_panel "Prepared Receive review"
wait_mock_status ".receiveCreateRequests == $((before_prepared_receive_creates + 1))
  and .receiveCancelRequests == $((before_prepared_receive_cancels + 1))
  and .receiveExecuteRequests == 0" >/dev/null
after_cancel_balances=$(curl -fsS -H "Authorization: Bearer $credential" \
  "$base_url/v1/balances")
jq -e '.items == []' <<<"$after_cancel_balances" >/dev/null \
  || fail "cancelling a Prepared Receive changed balances"

durable_prepared_receive=$(prepare_receive_fixture "$receive_token") \
  || fail "durable Prepared Receive fixture creation failed"
durable_prepared_receive_id=$(jq -er '.id' <<<"$durable_prepared_receive")
adapter_call reconnect >/dev/null
wait_snapshot ".connectionState == \"connected\"
  and (.activeTransfers | any(.id == \"$durable_prepared_receive_id\"
    and .state == \"prepared\"))" >/dev/null
panel_action openPanel >/dev/null
require_receive_action openReceive "durable Prepared Receive reopen"
wait_panel_snapshot '
  .receiveViewState == "review"
  and .receivePreparedAmount == "1200"
  and .receiveConfirmEnabled == true
' >/dev/null
close_receive_panel "reopened durable preparation"

before_ambiguous_receive_creates=$(curl -fsS "$base_url/__test__/status" \
  | jq -r '.receiveCreateRequests')
curl -fsS -X POST -H 'Content-Type: application/json' \
  --data '{"receiveCreateInterruption":"after_commit"}' \
  "$base_url/__test__/mode" >/dev/null
prepare_clipboard_receive "$receive_token"
wait_panel_snapshot '
  .receiveViewState == "review"
  and .receivePreparedAmount == "1200"
  and .receiveConfirmEnabled == true
' >/dev/null
wait_mock_status ".receiveCreateRequests == $((before_ambiguous_receive_creates + 1))
  and .receiveCreateDroppedResponses == 1" >/dev/null
close_receive_panel "ambiguous committed preparation"

before_malformed_receive=$(curl -fsS "$base_url/__test__/status")
before_malformed_receive_creates=$(jq -r '.receiveCreateRequests' \
  <<<"$before_malformed_receive")
before_malformed_receive_responses=$(jq -r '.receiveCreateDroppedResponses' \
  <<<"$before_malformed_receive")
curl -fsS -X POST -H 'Content-Type: application/json' \
  --data '{"receiveCreateInterruption":"malformed_after_commit"}' \
  "$base_url/__test__/mode" >/dev/null
prepare_clipboard_receive "$receive_token"
wait_panel_snapshot '
  .receiveViewState == "review"
  and .receivePreparedAmount == "1200"
  and .receiveConfirmEnabled == true
' >/dev/null
wait_mock_status ".receiveCreateRequests == $((before_malformed_receive_creates + 1))
  and .receiveCreateDroppedResponses == $((before_malformed_receive_responses + 1))" >/dev/null
close_receive_panel "malformed committed preparation"

before_dismissed_ambiguous=$(curl -fsS "$base_url/__test__/status")
before_dismissed_ambiguous_cancels=$(jq -r '.receiveCancelRequests' \
  <<<"$before_dismissed_ambiguous")
before_dismissed_ambiguous_failures=$(jq -r '.receivePrepareReconcileFailures // 0' \
  <<<"$before_dismissed_ambiguous")
curl -fsS -X POST -H 'Content-Type: application/json' \
  --data '{"receiveCreateInterruption":"after_commit","receivePrepareReconcileError":true,"receiveDelayMs":300}' \
  "$base_url/__test__/mode" >/dev/null
prepare_clipboard_receive "$receive_token"
wait_panel_snapshot '.receiveViewState == "preparing"' >/dev/null
require_receive_action cancelReceive "ambiguous Receive dismissal"
wait_snapshot '.receiveState == "error"' >/dev/null
wait_mock_status ".receivePrepareReconcileFailures == $((before_dismissed_ambiguous_failures + 1))" >/dev/null
curl -fsS -X POST -H 'Content-Type: application/json' \
  --data '{"receiveDelayMs":0}' "$base_url/__test__/mode" >/dev/null
adapter_call reconnect >/dev/null
wait_snapshot '.connectionState == "connected" and .activeTransfers == []' >/dev/null
wait_mock_status ".receiveCancelRequests == $((before_dismissed_ambiguous_cancels + 1))" >/dev/null

before_unsupported_receive_cancels=$(curl -fsS "$base_url/__test__/status" \
  | jq -r '.receiveCancelRequests')
prepare_clipboard_receive "$unsupported_token"
wait_panel_snapshot '
  .receiveViewState == "error"
  and .receiveError == "Only sat-denominated Cashu tokens are supported."
  and .receiveConfirmEnabled == false
' >/dev/null
wait_mock_status ".receiveCancelRequests == $((before_unsupported_receive_cancels + 1))" >/dev/null
close_receive_panel "unsupported unit"

canonical_prepare_error='cocod could not prepare this Receive. Only tokens from a previously Trusted Mint can be reviewed.'
for token in \
  "$invalid_token" \
  "$unavailable_token" \
  "$conflicting_token" \
  "$not_registered_token" \
  "$not_trusted_token"; do
  prepare_clipboard_receive "$token"
  panel_snapshot=$(wait_panel_snapshot \
    ".receiveViewState == \"error\" and .receiveError == \"$canonical_prepare_error\" and .receiveTextPresent == false")
  if rg -Fq "$token" <<<"$(adapter_call snapshot)$panel_snapshot" \
      || rg -Fq "$token" "$shell_log" "$mock_log"; then
    fail "Receive preparation error exposed bearer-token text"
  fi
  close_receive_panel "preparation error"
done

before_successful_receive=$(curl -fsS "$base_url/__test__/status")
before_successful_receive_creates=$(jq -r '.receiveCreateRequests' \
  <<<"$before_successful_receive")
before_successful_receive_executes=$(jq -r '.receiveExecuteRequests' \
  <<<"$before_successful_receive")
curl -fsS -X POST -H 'Content-Type: application/json' \
  --data '{"resources":"ok","delayMs":150,"receiveDelayMs":150}' \
  "$base_url/__test__/mode" >/dev/null
prepare_clipboard_receive "$receive_token"
wait_panel_snapshot '.receiveViewState == "preparing" and .receiveTextPresent == false' >/dev/null
wait_panel_snapshot '.receiveViewState == "review" and .receiveConfirmEnabled == true' >/dev/null
require_receive_action confirmReceive "Prepared Receive confirmation"
wait_panel_snapshot '.receiveViewState == "executing"' >/dev/null
wait_panel_snapshot '.receiveViewState == "reconciling"' >/dev/null
adapter_snapshot=$(wait_snapshot '
  .receiveState == "success"
  and .spendableBalance == "1198"
  and .trustedMintCount == 1
  and .activeTransfers == []
')
panel_snapshot=$(wait_panel_snapshot '
  .receiveViewState == "success"
  and .receiveTextPresent == false
  and .spendableBalance == "1198"
')
status=$(wait_mock_status '
  .receiveOperationCount >= 1
')
wait_mock_status ".receiveCreateRequests == $((before_successful_receive_creates + 1))
  and .receiveExecuteRequests == $((before_successful_receive_executes + 1))" >/dev/null
if rg -Fq "$receive_token" <<<"$adapter_snapshot$panel_snapshot$status" \
    || rg -Fq "$receive_token" "$shell_log" "$mock_log"; then
  fail "successful Receive retained bearer-token text"
fi
close_receive_panel "successful execution"
curl -fsS -X POST -H 'Content-Type: application/json' \
  --data '{"resources":"ok","delayMs":0,"receiveDelayMs":0}' \
  "$base_url/__test__/mode" >/dev/null

prepare_clipboard_receive "$not_found_token"
wait_panel_snapshot '.receiveViewState == "review" and .receiveConfirmEnabled == true' >/dev/null
require_receive_action confirmReceive "Receive confirmation"
panel_snapshot=$(wait_panel_snapshot '
  .receiveViewState == "error"
  and .receiveError == "This Receive is no longer available. Canonical Wallet state was refreshed."
')
if rg -Fq "$not_found_token" <<<"$(adapter_call snapshot)$panel_snapshot" \
    || rg -Fq "$not_found_token" "$shell_log" "$mock_log"; then
  fail "Receive execution error exposed bearer-token text"
fi
close_receive_panel "structured execution error"

if rg -Fq 'Binding loop detected for property "receiveState"' "$shell_log"; then
  fail "Receive transitions triggered a receiveState binding loop"
fi

echo "runtime: canonical Prepared Receive review, cancellation, execution, and errors passed"

# Reconcile interruptions on both sides of the Wallet commit point through the
# public HTTP/SSE and diagnostics seams. The token is streamed on stdin and is
# never passed through IPC, process arguments, or projected adapter state.
before_recovery_status=$(curl -fsS "$base_url/__test__/status")
before_recovery_refreshes=$(jq -r '.receiveRefreshRequests' <<<"$before_recovery_status")
curl -fsS -X POST -H 'Content-Type: application/json' \
  --data '{"receiveInterruption":"before_commit","receiveRefreshError":"mint_unavailable","receiveDelayMs":300}' \
  "$base_url/__test__/mode" >/dev/null
before_recovery=$(prepare_receive_fixture "$recovery_token") \
  || fail "pre-commit recovery fixture preparation failed"
before_recovery_id=$(jq -er '.id' <<<"$before_recovery")
if curl -fsS -H "Authorization: Bearer $credential" -X POST \
    "$base_url/v1/operations/receive/$before_recovery_id/execute" >/dev/null 2>&1; then
  fail "pre-commit interruption reported optimistic success"
fi
wait_snapshot ".receiveRecoveryState == \"recovering\"
  and .receiveRecoveryOperationId == \"$before_recovery_id\"
  and (.activeTransfers | length) == 1
  and .activeTransfers[0].stateLabel == \"Recovering Receive\"" >/dev/null
wait_snapshot ".receiveRecoveryState == \"failed\"
  and .receiveRecoveryOperationId == \"$before_recovery_id\"
  and .spendableBalance == \"1198\"
  and (.activeTransfers | length) == 1
  and .activeTransfers[0].id == \"$before_recovery_id\"
  and .activeTransfers[0].stateLabel == \"Receive needs attention\"
  and .activeTransfers[0].detail == \"cocod could not reconcile this Receive. Retry when the Mint is available.\"" >/dev/null
wait_panel_snapshot '
  .receiveRecoveryState == "failed"
  and .receiveRecoveryMessage == "Interrupted Receive needs attention"
  and .activeTransferStateLabel == "Receive needs attention"
  and .activeTransferDetail == "cocod could not reconcile this Receive. Retry when the Mint is available."
' >/dev/null
wait_mock_status ".receiveRefreshRequests > $before_recovery_refreshes" >/dev/null
curl -fsS -X POST -H 'Content-Type: application/json' \
  --data "$(jq -cn --arg id "$before_recovery_id" '{
    receiveRefreshError: "",
    receiveDelayMs: 0,
    event: {
      type: "operation.updated",
      timestamp: "2026-08-20T12:04:00.000Z",
      data: {
        operationType: "receive",
        operationId: $id,
        mintUrl: "https://mint.slice4.test"
      }
    }
  }')" "$base_url/__test__/mode" >/dev/null
curl -fsS -X POST -H 'Content-Type: application/json' \
  --data "$(jq -cn --arg id "$before_recovery_id" '{
    event: {
      type: "operation.updated",
      timestamp: "2026-08-20T12:04:00.000Z",
      data: {
        operationType: "receive",
        operationId: $id,
        mintUrl: "https://mint.slice4.test"
      }
    }
  }')" "$base_url/__test__/resources" >/dev/null
wait_snapshot ".receiveRecoveryState == \"rolled_back\"
  and .receiveRecoveryOperationId == \"$before_recovery_id\"
  and .spendableBalance == \"1198\"
  and .activeTransfers == []" >/dev/null
wait_mock_status ".receiveRefreshRequests > $((before_recovery_refreshes + 1))" >/dev/null

curl -fsS -X POST -H 'Content-Type: application/json' \
  --data '{"receiveInterruption":"after_commit"}' \
  "$base_url/__test__/mode" >/dev/null
after_recovery=$(prepare_receive_fixture "$recovery_token") \
  || fail "post-commit recovery fixture preparation failed"
after_recovery_id=$(jq -er '.id' <<<"$after_recovery")

kill "$shell_pid"
wait "$shell_pid" 2>/dev/null || true
shell_pid=""
if curl -fsS -H "Authorization: Bearer $credential" -X POST \
    "$base_url/v1/operations/receive/$after_recovery_id/execute" >/dev/null 2>&1; then
  fail "post-commit interruption reported optimistic success"
fi
kill "$mock_pid"
wait "$mock_pid" 2>/dev/null || true
mock_pid=""

COCOD_STATE_DIR="$state_dir" python3 "$project_dir/scripts/mock-cocod.py" \
  --port "$port" >>"$mock_log" 2>&1 &
mock_pid=$!
for _attempt in {1..40}; do
  curl -fsS "$base_url/__test__/status" >/dev/null 2>&1 && break
  sleep 0.05
done
COCOD_STATE_DIR="$state_dir" OMARCHY_CASHU_DAEMON_URL="$base_url" \
  quickshell --no-color -p "$shell_qml" >>"$shell_log" 2>&1 &
shell_pid=$!

adapter_snapshot=$(wait_snapshot ".connectionState == \"connected\"
  and .receiveRecoveryState == \"finalized\"
  and .receiveRecoveryOperationId == \"$after_recovery_id\"
  and .spendableBalance == \"1597\"
  and .activeTransfers == []")
restarted_status=$(wait_mock_status '
  .receiveCreateRequests == 0
  and .receiveExecuteRequests == 0
  and .receiveRefreshRequests == 1
  and .receiveLookupRequests == 1
  and .resourceRequests.receivePrepared == 1
  and .resourceRequests.receiveInFlight == 1
  and .resourceRequests.balances == 2
')
panel_action openPanel >/dev/null
panel_snapshot=$(wait_panel_snapshot '
  .receiveRecoveryState == "finalized"
  and .receiveRecoveryMessage == "Interrupted Receive completed"
  and .spendableBalance == "1597"
  and .activeTransferCount == 0
')
if rg -Fq "$recovery_token" <<<"$adapter_snapshot$panel_snapshot$restarted_status" \
    || rg -Fq "$recovery_token" "$shell_log" "$mock_log"; then
  fail "recovered Receive exposed bearer-token text"
fi

panel_action closePanel >/dev/null
wait_panel_snapshot '.opened == false' >/dev/null
before_panel_reopen=$(curl -fsS "$base_url/__test__/status")
before_panel_prepared=$(jq -r '.resourceRequests.receivePrepared' <<<"$before_panel_reopen")
before_panel_in_flight=$(jq -r '.resourceRequests.receiveInFlight' <<<"$before_panel_reopen")
before_panel_refresh=$(adapter_call snapshot | jq -r '.refreshCount')
panel_action openPanel >/dev/null
wait_mock_status ".resourceRequests.receivePrepared > $before_panel_prepared
  and .resourceRequests.receiveInFlight > $before_panel_in_flight" >/dev/null
wait_snapshot ".refreshCount > $before_panel_refresh
  and .connectionDetail == \"Connected to cocod\"" >/dev/null

echo "runtime: interrupted Receive recovery, restart, and terminal cleanup passed"

before_named_events=$(curl -fsS "$base_url/__test__/status")
before_named_lookups=$(jq -r '.receiveLookupRequests' <<<"$before_named_events")
before_named_balances=$(jq -r '.resourceRequests.balances' <<<"$before_named_events")
before_named_creates=$(jq -r '.receiveCreateRequests' <<<"$before_named_events")
before_named_executes=$(jq -r '.receiveExecuteRequests' <<<"$before_named_events")
before_named_refreshes=$(jq -r '.receiveRefreshRequests' <<<"$before_named_events")
pending_recovery=$(prepare_receive_fixture "$pending_recovery_token") \
  || fail "named-invalidation Receive preparation failed"
pending_recovery_id=$(jq -er '.id' <<<"$pending_recovery")
wait_snapshot ".activeTransfers == [{
  \"id\": \"$pending_recovery_id\",
  \"type\": \"receive\",
  \"state\": \"prepared\",
  \"stateLabel\": \"Receive ready\",
  \"detail\": \"https://mint.slice4.test\",
  \"amount\": \"250\",
  \"unit\": \"sat\"
}]" >/dev/null

for timestamp in 2026-08-20T12:05:02.000Z 2026-08-20T12:05:01.000Z; do
  curl -fsS -X POST -H 'Content-Type: application/json' \
    --data "$(jq -cn --arg id "$pending_recovery_id" --arg timestamp "$timestamp" '{
      event: {
        type: "operation.updated",
        timestamp: $timestamp,
        data: {
          operationType: "receive",
          operationId: $id,
          mintUrl: "https://mint.slice4.test"
        }
      }
    }')" "$base_url/__test__/resources" >/dev/null
done
wait_mock_status ".receiveLookupRequests >= $((before_named_lookups + 3))
  and .resourceRequests.balances > $before_named_balances
  and .receiveCreateRequests == $((before_named_creates + 1))
  and .receiveExecuteRequests == $before_named_executes
  and .receiveRefreshRequests == $before_named_refreshes" >/dev/null
wait_snapshot "(.activeTransfers | length) == 1
  and .activeTransfers[0].id == \"$pending_recovery_id\"
  and .activeTransfers[0].amount == \"250\"" >/dev/null

panel_action closePanel >/dev/null
wait_panel_snapshot '.opened == false' >/dev/null
before_active_panel=$(curl -fsS "$base_url/__test__/status")
before_active_panel_prepared=$(jq -r '.resourceRequests.receivePrepared' \
  <<<"$before_active_panel")
before_active_panel_in_flight=$(jq -r '.resourceRequests.receiveInFlight' \
  <<<"$before_active_panel")
before_active_panel_lookups=$(jq -r '.receiveLookupRequests' \
  <<<"$before_active_panel")
panel_action openPanel >/dev/null
wait_mock_status ".resourceRequests.receivePrepared > $before_active_panel_prepared
  and .resourceRequests.receiveInFlight > $before_active_panel_in_flight
  and .receiveLookupRequests > $before_active_panel_lookups" >/dev/null
wait_snapshot ".connectionDetail == \"Connected to cocod\"
  and (.activeTransfers | any(.id == \"$pending_recovery_id\"))" >/dev/null

curl -fsS -X POST -H 'Content-Type: application/json' \
  --data '{
    "event": {
      "type":"operation.updated",
      "timestamp":"2026-08-20T12:05:00.000Z",
      "data": {
        "operationType":"receive",
        "operationId":"missing-receive",
        "mintUrl":"https://mint.slice4.test"
      }
    }
  }' "$base_url/__test__/resources" >/dev/null
wait_snapshot '.receiveRecoveryState == "failed"
  and .receiveRecoveryOperationId == "missing-receive"
  and .receiveRecoveryError == "This Receive is no longer available. Canonical Wallet state was refreshed."
  and (.activeTransfers | length) == 1' >/dev/null

before_stale_lookup=$(curl -fsS "$base_url/__test__/status")
before_stale_requests=$(jq -r '.receiveLookupRequests' <<<"$before_stale_lookup")
before_stale_responses=$(jq -r '.receiveLookupResponses' <<<"$before_stale_lookup")
curl -fsS -X POST -H 'Content-Type: application/json' \
  --data '{"receiveLookupDelayMs":2500}' "$base_url/__test__/mode" >/dev/null
curl -fsS -X POST -H 'Content-Type: application/json' \
  --data "$(jq -cn --arg id "$pending_recovery_id" '{
    event: {
      type: "operation.updated",
      timestamp: "2026-08-20T12:05:03.000Z",
      data: {
        operationType: "receive",
        operationId: $id,
        mintUrl: "https://mint.slice4.test"
      }
    }
  }')" "$base_url/__test__/resources" >/dev/null
wait_mock_status ".receiveLookupRequests > $before_stale_requests
  and .receiveLookupRequestsActive == 1" >/dev/null
curl -fsS -X POST -H 'Content-Type: application/json' --data '{}' \
  "$base_url/__test__/disconnect" >/dev/null
wait_snapshot '.connectionState == "unavailable"' >/dev/null
wait_mock_status '.streamConnections == 0' >/dev/null
curl -fsS -X POST -H 'Content-Type: application/json' \
  --data '{"receiveLookupDelayMs":0}' "$base_url/__test__/mode" >/dev/null
curl -fsS -H "Authorization: Bearer $credential" -X POST \
  "$base_url/v1/operations/receive/$pending_recovery_id/cancel" >/dev/null \
  || fail "stale-lookup Receive cleanup failed"
adapter_call reconnect >/dev/null
wait_snapshot '.connectionState == "connected" and .activeTransfers == []' >/dev/null
wait_mock_status ".receiveLookupResponses > $before_stale_responses
  and .receiveLookupRequestsActive == 0" >/dev/null
wait_snapshot '.activeTransfers == []' >/dev/null

curl -fsS -X POST -H 'Content-Type: application/json' \
  --data "$(jq -cn --arg id "$pending_recovery_id" '{
    event: {
      type: "operation.updated",
      timestamp: "2026-08-20T12:05:04.000Z",
      data: {
        operationType: "receive",
        operationId: $id,
        mintUrl: "https://mint.slice4.test"
      }
    }
  }')" "$base_url/__test__/resources" >/dev/null
wait_snapshot ".receiveRecoveryState == \"rolled_back\"
  and .receiveRecoveryOperationId == \"$pending_recovery_id\"
  and .activeTransfers == []" >/dev/null
named_event_status=$(curl -fsS "$base_url/__test__/status")
if rg -Fq "$pending_recovery_token" <<<"$(adapter_call snapshot)$named_event_status" \
    || rg -Fq "$pending_recovery_token" "$shell_log" "$mock_log"; then
  fail "named Operation invalidation exposed bearer-token text"
fi

echo "runtime: named, duplicate, missing, and reordered Receive invalidations passed"

kill "$shell_pid"
wait "$shell_pid" 2>/dev/null || true
shell_pid=""
curl -fsS -X POST -H 'Content-Type: application/json' \
  --data '{"receiveInterruption":"before_commit","receiveRefreshError":"mint_unavailable"}' \
  "$base_url/__test__/mode" >/dev/null
first_concurrent=$(prepare_receive_fixture "$pending_recovery_token") \
  || fail "first concurrent recovery fixture preparation failed"
second_concurrent=$(prepare_receive_fixture "$concurrent_recovery_token") \
  || fail "second concurrent recovery fixture preparation failed"
first_concurrent_id=$(jq -er '.id' <<<"$first_concurrent")
second_concurrent_id=$(jq -er '.id' <<<"$second_concurrent")
for concurrent_id in "$first_concurrent_id" "$second_concurrent_id"; do
  if curl -fsS -H "Authorization: Bearer $credential" -X POST \
      "$base_url/v1/operations/receive/$concurrent_id/execute" >/dev/null 2>&1; then
    fail "concurrent recovery fixture reported optimistic success"
  fi
done
COCOD_STATE_DIR="$state_dir" OMARCHY_CASHU_DAEMON_URL="$base_url" \
  quickshell --no-color -p "$shell_qml" >>"$shell_log" 2>&1 &
shell_pid=$!
wait_snapshot ".connectionState == \"connected\"
  and (.activeTransfers | length) == 2
  and (.activeTransfers | all(.stateLabel == \"Receive needs attention\"))
  and (.activeTransfers | any(.id == \"$first_concurrent_id\"))
  and (.activeTransfers | any(.id == \"$second_concurrent_id\"))" >/dev/null

curl -fsS -X POST -H 'Content-Type: application/json' \
  --data '{"receiveInterruption":"none","receiveRefreshError":""}' \
  "$base_url/__test__/mode" >/dev/null
for concurrent_id in "$first_concurrent_id" "$second_concurrent_id"; do
  curl -fsS -X POST -H 'Content-Type: application/json' \
    --data "$(jq -cn --arg id "$concurrent_id" '{
      event: {
        type: "operation.updated",
        timestamp: "2026-08-20T12:05:05.000Z",
        data: {
          operationType: "receive",
          operationId: $id,
          mintUrl: "https://mint.slice4.test"
        }
      }
    }')" "$base_url/__test__/resources" >/dev/null
done
wait_snapshot ".activeTransfers == []
  and .receiveRecoveries[\"$first_concurrent_id\"].state == \"rolled_back\"
  and .receiveRecoveries[\"$second_concurrent_id\"].state == \"rolled_back\"" >/dev/null

echo "runtime: concurrent Receive recovery projections passed"

panel_action openPanel >/dev/null
panel_action openRecoveryPhrase >/dev/null
panel_action confirmRecoveryPhrase >/dev/null
wait_panel_snapshot '.recoveryViewState == "revealed"
  and .recoveryPhraseVisible == true' >/dev/null
before_sensitive_rotation=$(adapter_call snapshot | jq -r '.rotationCount')
adapter_call rotate >/dev/null
wait_snapshot ".connectionState == \"connected\"
  and .rotationCount == $((before_sensitive_rotation + 1))
  and .canonicalRefreshInProgress == false" >/dev/null
wait_panel_snapshot '.recoveryViewState == "closed"
  and .recoveryPhraseVisible == false' >/dev/null
set_sensitive_clipboard "$receive_token"
open_receive_panel >/dev/null
panel_action pasteReceive >/dev/null
wait_panel_snapshot '.receiveViewState == "entry"
  and .receiveTextPresent == true' >/dev/null
before_receive_rotation=$(adapter_call snapshot | jq -r '.rotationCount')
adapter_call rotate >/dev/null
wait_snapshot ".connectionState == \"connected\"
  and .rotationCount == $((before_receive_rotation + 1))
  and .canonicalRefreshInProgress == false" >/dev/null
wait_panel_snapshot '.receiveViewState == "closed"
  and .receiveTextPresent == false' >/dev/null

echo "runtime: connection rotation clears sensitive non-Send presentation state"

curl -fsS -X POST -H 'Content-Type: application/json' \
  --data '{
    "balances":{"items":[
      {"mintUrl":"https://mint.init","unit":"sat","spendable":"40","reserved":"10","total":"50"}
    ]},
    "mints":{"items":[
      {"mintUrl":"https://mint.init","name":"Init Mint","trusted":true,"createdAt":"2026-08-20T12:00:00.000Z","updatedAt":"2026-08-20T12:00:00.000Z"}
    ]},
    "sendPrepared":{"items":[]},
    "sendInFlight":{"items":[{
      "id":"send-init","type":"send","state":"init","mintUrl":"https://mint.init",
      "unit":"sat","method":"default","requestedAmount":"10","createdAt":"2026-08-20T12:00:00.000Z",
      "updatedAt":"2026-08-20T12:00:00.000Z"
    }]}
  }' "$base_url/__test__/resources" >/dev/null
adapter_call reconnect >/dev/null
wait_snapshot '
  .connectionState == "connected"
  and (.activeTransfers | length) == 1
  and .activeTransfers[0].id == "send-init"
  and .activeTransfers[0].state == "init"
' >/dev/null

echo "runtime: canonical init Send accepts its state-specific safe shape"

curl -fsS -X POST -H 'Content-Type: application/json' \
  --data '{
    "balances":{"items":[
      {"mintUrl":"https://mint.prepared.test:3338/path","unit":"sat","spendable":"401","reserved":"99","total":"500"}
    ]},
    "sendPrepared":{"items":[{
      "id":"send-browse-prepared","type":"send","state":"prepared",
      "mintUrl":"https://mint.prepared.test:3338/path","unit":"sat","method":"default",
      "requestedAmount":"11","fee":"1","inputAmount":"12","needsSwap":true,
      "createdAt":"2026-08-25T00:00:00.000Z","updatedAt":"2026-08-25T00:01:00.000Z"
    }]},
    "sendInFlight":{"items":[
      {"id":"send-browse-executing","type":"send","state":"executing",
       "mintUrl":"https://mint.executing.test","unit":"sat","method":"default",
       "requestedAmount":"21","fee":"1","inputAmount":"22","needsSwap":false,
       "createdAt":"2026-08-25T00:00:00.000Z","updatedAt":"2026-08-25T00:02:00.000Z"},
      {"id":"send-browse-pending","type":"send","state":"pending",
       "mintUrl":"https://mint.pending.test","unit":"sat","method":"default",
       "requestedAmount":"31","fee":"1","inputAmount":"32","needsSwap":false,
       "createdAt":"2026-08-25T00:00:00.000Z","updatedAt":"2026-08-25T00:03:00.000Z"},
      {"id":"send-browse-reclaiming","type":"send","state":"rolling_back",
       "mintUrl":"https://mint.reclaiming.test","unit":"sat","method":"default",
       "requestedAmount":"41","fee":"1","inputAmount":"42","needsSwap":false,
       "createdAt":"2026-08-25T00:00:00.000Z","updatedAt":"2026-08-25T00:04:00.000Z"},
      {"id":"send-browse-prepared","type":"send","state":"prepared",
       "mintUrl":"https://mint.prepared.test:3338/path","unit":"sat","method":"default",
       "requestedAmount":"11","fee":"1","inputAmount":"12","needsSwap":true,
       "createdAt":"2026-08-25T00:00:00.000Z","updatedAt":"2026-08-25T00:01:00.000Z"},
      {"id":"send-browse-terminal","type":"send","state":"finalized",
       "mintUrl":"https://mint.terminal.test","unit":"sat","method":"default",
       "requestedAmount":"51","fee":"1","inputAmount":"52","needsSwap":false,
       "createdAt":"2026-08-25T00:00:00.000Z","updatedAt":"2026-08-25T00:05:00.000Z"},
      {"id":"send-browse-init","type":"send","state":"init",
       "mintUrl":"https://mint.init.test","unit":"sat","method":"default",
       "requestedAmount":"61","createdAt":"2026-08-25T00:00:00.000Z",
       "updatedAt":"2026-08-25T00:06:00.000Z"}
    ]}
  }' "$base_url/__test__/resources" >/dev/null
adapter_call reconnect >/dev/null
wait_snapshot '
  .connectionState == "connected"
  and .reservedBalance == "99"
  and (.activeSends | length) == 4
  and [.activeSends[].id] == [
    "send-browse-reclaiming","send-browse-pending",
    "send-browse-executing","send-browse-prepared"
  ]
  and [.activeSends[].stateLabel] == ["Reclaiming","Pending","Executing","Prepared"]
  and .activeSends[1].amount == "31"
  and .activeSends[1].mintHostname == "mint.pending.test"
  and .activeSends[3].mintHostname == "mint.prepared.test"
  and .activeSends[3].reservedInput == "12"
  and (.activeSends | all(.id != "send-browse-terminal" and .id != "send-browse-init"))
' >/dev/null

bar_snapshot=$(bar_call)
jq -e '
  .stateLabel == "Unlocked"
  and (.text | contains("Unlocked"))
  and (.tooltipText | contains("Active Transfer"))
  and ([.text,.tooltipText] | all(test("4|11|21|31|41|99") | not))
' <<<"$bar_snapshot" >/dev/null \
  || fail "Omarchy bar exposed an Active Sends count or transfer amount"

panel_action openPanel >/dev/null
wait_panel_snapshot '
  .activeSendsCount == 4
  and .activeSendsCountText == "4 Active Sends"
  and .activeSendsViewState == "closed"
' >/dev/null
before_active_browse=$(curl -fsS "$base_url/__test__/status")
before_active_browse_executes=$(jq -r '.sendExecuteRequests' <<<"$before_active_browse")
before_active_browse_cancels=$(jq -r '.sendCancelRequests' <<<"$before_active_browse")
before_active_browse_reclaims=$(jq -r '.sendReclaimRequests' <<<"$before_active_browse")
before_active_browse_results=$(jq -r '.sendResultRequests' <<<"$before_active_browse")
before_active_browse_refreshes=$(jq -r '.sendRefreshRequests' <<<"$before_active_browse")
[[ $(panel_action openActiveSends) == "ok" ]] \
  || fail "Active Sends count did not open its full panel subpage"
wait_panel_snapshot '
  .activeSendsViewState == "list"
  and .activeSendsBackVisible == true
  and .activeSendsEmptyVisible == false
  and [.activeSendRows[].id] == [
    "send-browse-reclaiming","send-browse-pending",
    "send-browse-executing","send-browse-prepared"
  ]
  and .activeSendRows[0].amount == "41"
  and .activeSendRows[0].mintHostname == "mint.reclaiming.test"
  and .activeSendRows[0].stateLabel == "Reclaiming"
  and (.activeSendRows | all(.relativeUpdate | startswith("Updated ")))
  and .activeSendRows[3].reservedInput == "12"
' >/dev/null
wait_mock_status ".resourceRequests.sendPrepared > $(jq -r '.resourceRequests.sendPrepared' <<<"$before_active_browse")
  and .resourceRequests.sendInFlight > $(jq -r '.resourceRequests.sendInFlight' <<<"$before_active_browse")" >/dev/null
wait_panel_snapshot '.activeSendsCanonicalSynchronized == true' >/dev/null

before_explicit_active_refresh=$(curl -fsS "$base_url/__test__/status")
[[ $(panel_action refreshActiveSends) == "ok" ]] \
  || fail "explicit Active Sends Refresh action was unavailable"
wait_mock_status ".resourceRequests.sendPrepared > $(jq -r '.resourceRequests.sendPrepared' <<<"$before_explicit_active_refresh")
  and .resourceRequests.sendInFlight > $(jq -r '.resourceRequests.sendInFlight' <<<"$before_explicit_active_refresh")" >/dev/null
wait_panel_snapshot '.activeSendsCanonicalSynchronized == true' >/dev/null

[[ $(panel_action setActiveSendsPollInterval 200) == "ok" ]] \
  || fail "Active Sends poll test interval could not be configured"
before_visible_poll=$(curl -fsS "$base_url/__test__/status")
wait_panel_snapshot '.activeSendsPolling == true and .activeSendsPollIntervalMs == 200' >/dev/null
wait_mock_status ".resourceRequests.sendPrepared > $(jq -r '.resourceRequests.sendPrepared' <<<"$before_visible_poll")
  and .resourceRequests.sendInFlight > $(jq -r '.resourceRequests.sendInFlight' <<<"$before_visible_poll")" >/dev/null
[[ $(panel_action closePanel) == "ok" ]] \
  || fail "panel could not close after visible Active Sends polling"
wait_panel_snapshot '.opened == false and .activeSendsPolling == false' >/dev/null
sleep 0.3
hidden_poll_baseline=$(curl -fsS "$base_url/__test__/status")
sleep 0.6
hidden_poll_after=$(curl -fsS "$base_url/__test__/status")
jq -e --argjson before "$(jq '.resourceRequests' <<<"$hidden_poll_baseline")" '
  .resourceRequests.sendPrepared == $before.sendPrepared
  and .resourceRequests.sendInFlight == $before.sendInFlight
' <<<"$hidden_poll_after" >/dev/null \
  || fail "background Shell Adapter polled Active Sends while the panel was hidden"
panel_action setActiveSendsPollInterval 15000 >/dev/null
panel_action openPanel >/dev/null
panel_action openActiveSends >/dev/null
wait_panel_snapshot '.activeSendsCanonicalSynchronized == true
  and .activeSendsPolling == true and .activeSendsPollIntervalMs == 15000' >/dev/null

[[ $(panel_action selectActiveSend send-browse-pending) == "ok" ]] \
  || fail "exact Pending Send row could not be selected"
wait_panel_snapshot '
  .activeSendsViewState == "detail"
  and .selectedActiveSendOperationId == "send-browse-pending"
  and .selectedActiveSend.id == "send-browse-pending"
  and .selectedActiveSend.amount == "31"
  and .selectedActiveSend.mintHostname == "mint.pending.test"
  and .activeSendDetailReadOnly == false
  and .activeSendMutationActionCount == 4
  and .activePendingCopyAvailable == true
  and .activePendingRevealAvailable == true
  and .activePendingRefreshAvailable == true
  and .activePendingReclaimAvailable == true
  and .activePendingTokenRevealed == false
' >/dev/null
wait_mock_status ".sendExecuteRequests == $before_active_browse_executes
  and .sendCancelRequests == $before_active_browse_cancels
  and .sendReclaimRequests == $before_active_browse_reclaims
  and .sendResultRequests == $before_active_browse_results
  and .sendRefreshRequests == $before_active_browse_refreshes" >/dev/null
[[ $(panel_action backActiveSends) == "ok" ]] \
  || fail "Active Send detail Back action failed"
wait_panel_snapshot '
  .activeSendsViewState == "list"
  and .activeSendsCount == 4
  and .selectedActiveSendOperationId == ""
' >/dev/null
[[ $(panel_action selectActiveSend send-browse-pending) == "ok" ]] \
  || fail "Pending Send could not be reselected for terminal reconciliation"

curl -fsS -X POST -H 'Content-Type: application/json' \
  --data '{
    "sendPrepared":{"items":[]},
    "sendInFlight":{"items":[{
      "id":"send-browse-pending","type":"send","state":"rolled_back",
      "mintUrl":"https://mint.pending.test","unit":"sat","method":"default",
      "requestedAmount":"31","fee":"1","inputAmount":"32","needsSwap":false,
      "createdAt":"2026-08-25T00:00:00.000Z","updatedAt":"2026-08-25T00:07:00.000Z"
    }]}
  }' "$base_url/__test__/resources" >/dev/null
adapter_call reconnect >/dev/null
wait_snapshot '.connectionState == "connected" and .activeSends == []' >/dev/null
wait_panel_snapshot '
  .activeSendsViewState == "detail"
  and .selectedActiveSendOperationId == "send-browse-pending"
  and .selectedActiveSend == null
  and .activePendingTerminalState == "reclaimed"
' >/dev/null
[[ $(panel_action backActiveSends) == "ok" ]] \
  || fail "terminal Send detail could not return to the collection"
wait_panel_snapshot '
  .activeSendsViewState == "list"
  and .activeSendsCount == 0
  and .activeSendsEmptyVisible == true
  and .activePendingTerminalState == ""
' >/dev/null
[[ $(panel_action backActiveSends) == "ok" ]] \
  || fail "Active Sends list Back action failed"
wait_panel_snapshot '.activeSendsViewState == "closed"' >/dev/null

echo "runtime: mixed-state Active Sends browsing, navigation, empty state, and bar privacy passed"

fund_send_fixture 300
IFS=$'\t' read -r first_pending_id first_pending_token \
  < <(create_pending_send_fixture 21)
IFS=$'\t' read -r second_pending_id second_pending_token \
  < <(create_pending_send_fixture 22)
adapter_call reconnect >/dev/null
wait_snapshot ".connectionState == \"connected\"
  and ([.activeSends[].id] | index(\"$first_pending_id\") != null)
  and ([.activeSends[].id] | index(\"$second_pending_id\") != null)" >/dev/null

set_sensitive_clipboard 'pending-send-copy-sentinel'
before_pending_detail=$(curl -fsS "$base_url/__test__/status")
before_pending_results=$(jq -r '.sendResultRequests' <<<"$before_pending_detail")
before_pending_reclaims=$(jq -r '.sendReclaimRequests' <<<"$before_pending_detail")
[[ $(panel_action openPanel) == "ok" ]] \
  || fail "panel could not open for exact Pending Send actions"
[[ $(panel_action openActiveSends) == "ok" ]] \
  || fail "Active Sends could not open for exact Pending Send actions"
[[ $(panel_action selectActiveSend "$second_pending_id") == "ok" ]] \
  || fail "second Pending Send could not be selected by exact ID"
wait_panel_snapshot ".activeSendsViewState == \"detail\"
  and .selectedActiveSendOperationId == \"$second_pending_id\"
  and .selectedActiveSend.id == \"$second_pending_id\"
  and .selectedActiveSend.amount == \"22\"
  and .activePendingActionState == \"idle\"
  and .activePendingCopyAvailable == true
  and .activePendingRevealAvailable == true
  and .activePendingRefreshAvailable == true
  and .activePendingReclaimAvailable == true
  and .activePendingTokenRevealed == false" >/dev/null
wait_mock_status ".sendResultRequests == $before_pending_results
  and .sendReclaimRequests == $before_pending_reclaims" >/dev/null
[[ $(wl-paste --no-newline) == 'pending-send-copy-sentinel' ]] \
  || fail "opening a Pending Send detail changed the clipboard"

curl -fsS -X POST -H 'Content-Type: application/json' --data '{}' \
  "$base_url/__test__/disconnect" >/dev/null
wait_snapshot '.connectionState == "unavailable"
  and .sendCanonicalSynchronized == false and (.activeSends | length) == 2' >/dev/null
wait_panel_snapshot ".activeSendsReconnecting == true
  and .selectedActiveSendOperationId == \"$second_pending_id\"
  and .selectedActiveSend.id == \"$second_pending_id\"
  and .activePendingCopyAvailable == false
  and .activePendingRevealAvailable == false
  and .activePendingRefreshAvailable == false
  and .activePendingReclaimAvailable == false" >/dev/null
wait_panel_snapshot '.connectionState == "connected"
  and .activeSendsReconnecting == false
  and .activeSendsCanonicalSynchronized == true
  and .activePendingCopyAvailable == true' >/dev/null

[[ $(panel_action copyActivePendingSend) == "ok" ]] \
  || fail "explicit Copy did not start for the selected Pending Send"
wait_mock_status ".sendResultRequests == $((before_pending_results + 1))
  and .sendResultOperationIds[-1] == \"$second_pending_id\"" >/dev/null
for _attempt in {1..200}; do
  [[ $(wl-paste --no-newline 2>/dev/null || true) == "$second_pending_token" ]] && break
  sleep 0.05
done
[[ $(wl-paste --no-newline) == "$second_pending_token" ]] \
  || fail "explicit Copy did not write the selected Pending Send token"
wait_panel_snapshot '.activePendingClipboardWrites == 1
  and .activePendingTokenRevealed == false' >/dev/null
pending_copy_snapshot=$(panel_call)
if rg -Fq "$second_pending_token" <<<"$pending_copy_snapshot" \
    || rg -q 'cashuA' <<<"$pending_copy_snapshot"; then
  fail "Pending Send token escaped into the panel diagnostics snapshot"
fi

[[ $(panel_action revealActivePendingSend) == "ok" ]] \
  || fail "explicit Reveal did not start for the selected Pending Send"
wait_mock_status ".sendResultRequests == $((before_pending_results + 2))
  and .sendResultOperationIds[-1] == \"$second_pending_id\"" >/dev/null
wait_panel_snapshot '.activePendingTokenRevealed == true' >/dev/null
revealed_pending_snapshot=$(panel_call)
[[ $revealed_pending_snapshot != *"$second_pending_token"* ]] \
  || fail "revealed Pending Send token escaped the focused presentation"

curl -fsS -X POST -H 'Content-Type: application/json' --data '{
  "status":{
    "daemon":{"version":"0.0.17","interfaceVersion":"1"},
    "wallet":{"configuredAt":"2026-08-25T14:00:00.000Z"},
    "seedAccess":{"state":"available","requiresPassphrase":false},
    "cocoSession":{"state":"running","startedAt":"2026-08-25T14:00:00.000Z","lastFailure":null}
  }
}' "$base_url/__test__/resources" >/dev/null
adapter_call reconnect >/dev/null
wait_snapshot '.connectionState == "connected"
  and .sendCanonicalSynchronized == true
  and .canonicalRefreshInProgress == false' >/dev/null
wait_panel_snapshot '.activePendingTokenRevealed == false' >/dev/null

[[ $(panel_action revealActivePendingSend) == "ok" ]] \
  || fail "Pending Send could not be revealed before credential rotation"
wait_panel_snapshot '.activePendingTokenRevealed == true' >/dev/null
panel_action backActiveSends >/dev/null
panel_action selectActiveSend "$first_pending_id" >/dev/null
curl -fsS -X POST -H 'Content-Type: application/json' \
  --data '{"sendResultUnavailableResponses":1}' \
  "$base_url/__test__/mode" >/dev/null
panel_action revealActivePendingSend >/dev/null
wait_panel_snapshot '.activePendingErrorCode == "result_not_available"' >/dev/null
panel_action backActiveSends >/dev/null
panel_action selectActiveSend "$second_pending_id" >/dev/null
panel_action revealActivePendingSend >/dev/null
wait_panel_snapshot '.activePendingTokenRevealed == true' >/dev/null
wait_snapshot '.sendOperationErrorCount == 1' >/dev/null
rotated_credential=CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC
mkdir -p "$state_dir/credentials/generation-2"
printf '%s\n' "$rotated_credential" >"$state_dir/credentials/generation-2/client"
chmod 700 "$state_dir/credentials/generation-2"
chmod 600 "$state_dir/credentials/generation-2/client"
ln -s generation-2 "$state_dir/credentials/next"
mv -Tf "$state_dir/credentials/next" "$state_dir/credentials/current"
adapter_call reconnect >/dev/null
wait_snapshot '.connectionState != "connected"
  and .activeSends == []
  and .sendOperationErrorCount == 0
  and .sendCanonicalSynchronized == false' >/dev/null
wait_panel_snapshot '.activePendingTokenRevealed == false
  and .selectedActiveSend == null
  and .activePendingErrorCode == ""' >/dev/null
ln -s generation-1 "$state_dir/credentials/next"
mv -Tf "$state_dir/credentials/next" "$state_dir/credentials/current"
adapter_call reconnect >/dev/null
wait_snapshot '.connectionState == "connected"
  and .sendCanonicalSynchronized == true
  and .canonicalRefreshInProgress == false' >/dev/null
kill "$shell_pid"
wait "$shell_pid" 2>/dev/null || true
shell_pid=""
COCOD_STATE_DIR="$state_dir" OMARCHY_CASHU_DAEMON_URL="$base_url" \
  quickshell --no-color -p "$shell_qml" >>"$shell_log" 2>&1 &
shell_pid=$!
wait_snapshot '.connectionState == "connected"
  and .sendCanonicalSynchronized == true
  and (.activeSends | length) == 2
  and .sendOperationErrorCount == 0' >/dev/null
panel_action openPanel >/dev/null
panel_action openActiveSends >/dev/null
wait_panel_snapshot '.activeSendsViewState == "list"
  and .activePendingTokenRevealed == false' >/dev/null
curl -fsS -X POST -H 'Content-Type: application/json' \
  --data '{"sendResultUnavailableResponses":1}' \
  "$base_url/__test__/mode" >/dev/null
before_post_rotation_result=$(curl -fsS "$base_url/__test__/status" \
  | jq -r '.sendResultRequests')
[[ $(panel_action selectActiveSend "$first_pending_id") == "ok" ]] \
  || fail "first Pending Send could not be selected by exact ID"
[[ $(panel_action revealActivePendingSend) == "ok" ]] \
  || fail "temporarily unavailable Pending result request did not start"
wait_mock_status ".sendResultRequests > $before_post_rotation_result" >/dev/null
wait_panel_snapshot ".selectedActiveSendOperationId == \"$first_pending_id\"
  and .selectedActiveSend.state == \"pending\"
  and .activePendingActionState == \"error\"
  and .activePendingErrorCode == \"result_not_available\"
  and .activePendingRefreshAvailable == true
  and .activePendingReclaimAvailable == true" >/dev/null
[[ $(panel_action backActiveSends) == "ok" ]] \
  || fail "Pending result error could not return to the list"
[[ $(panel_action selectActiveSend "$second_pending_id") == "ok" ]] \
  || fail "second Pending Send could not be revisited"
wait_panel_snapshot '.activePendingErrorCode == ""' >/dev/null
[[ $(panel_action backActiveSends) == "ok" ]] \
  || fail "second Pending Send could not return to the list"
[[ $(panel_action selectActiveSend "$first_pending_id") == "ok" ]] \
  || fail "first Pending Send could not be revisited"
wait_panel_snapshot '.activePendingErrorCode == "result_not_available"' >/dev/null

set_sensitive_clipboard 'late-pending-copy-must-not-land'
before_late_result=$(jq -r '.sendResultRequests' \
  <<<"$(curl -fsS "$base_url/__test__/status")")
curl -fsS -X POST -H 'Content-Type: application/json' \
  --data '{"sendResultDelayMs":400}' "$base_url/__test__/mode" >/dev/null
[[ $(panel_action copyActivePendingSend) == "ok" ]] \
  || fail "delayed exact Pending Copy did not start"
[[ $(panel_action closePanel) == "ok" ]] \
  || fail "panel close was blocked during Pending result retrieval"
wait_panel_snapshot '.opened == false
  and .activeSendsViewState == "closed"
  and .activePendingTokenRevealed == false' >/dev/null
panel_action openPanel >/dev/null
[[ $(panel_action openActiveSends) == "ok" ]] \
  || fail "Active Sends could not reopen during Pending result retrieval"
[[ $(panel_action selectActiveSend "$second_pending_id") == "ok" ]] \
  || fail "another Pending Send could not be selected during result retrieval"
[[ $(panel_action copyActivePendingSend) == "disabled" ]] \
  || fail "Pending result requests were not serialized"
wait_mock_status ".sendResultRequests == $((before_late_result + 1))
  and .sendResultOperationIds[-1] == \"$first_pending_id\"" >/dev/null
sleep 0.5
wait_panel_snapshot '.activePendingCopyAvailable == true
  and .activePendingTokenRevealed == false' >/dev/null
[[ $(wl-paste --no-newline) == 'late-pending-copy-must-not-land' ]] \
  || fail "late Pending Copy wrote after focus changed"
curl -fsS -X POST -H 'Content-Type: application/json' \
  --data '{"sendResultDelayMs":0}' "$base_url/__test__/mode" >/dev/null
[[ $(panel_action backActiveSends) == "ok" ]] \
  || fail "Pending detail could not close after serialized retrieval"
[[ $(panel_action backActiveSends) == "ok" ]] \
  || fail "Active Sends list could not close after Pending retrieval tests"

fund_send_fixture 100
IFS=$'\t' read -r reclaimed_pending_id reclaimed_pending_token \
  < <(create_pending_send_fixture 20)
adapter_call reconnect >/dev/null
wait_snapshot '.connectionState == "connected"' >/dev/null
panel_action openPanel >/dev/null
panel_action openActiveSends >/dev/null
panel_action selectActiveSend "$reclaimed_pending_id" >/dev/null
before_reclaim_count=$(jq -r '.sendReclaimRequests' \
  <<<"$(curl -fsS "$base_url/__test__/status")")
[[ $(panel_action beginActivePendingReclaim) == "ok" ]] \
  || fail "Reclaim warning did not open for a canonical Pending Send"
wait_panel_snapshot '.activePendingReclaimWarningVisible == true
  and (.activePendingReclaimWarning | contains("20 sat"))
  and (.activePendingReclaimWarning | test("recipient"; "i"))
  and (.activePendingReclaimWarning | test("race"; "i"))' >/dev/null
wait_mock_status ".sendReclaimRequests == $before_reclaim_count" >/dev/null
[[ $(panel_action confirmActivePendingReclaim) == "ok" ]] \
  || fail "confirmed exact Pending Reclaim did not start"
wait_mock_status ".sendReclaimRequests == $((before_reclaim_count + 1))
  and .sendReclaimOperationIds[-1] == \"$reclaimed_pending_id\"" >/dev/null
wait_panel_snapshot ".selectedActiveSendOperationId == \"$reclaimed_pending_id\"
  and .selectedActiveSend == null
  and .activePendingTerminalState == \"reclaimed\"" >/dev/null
wait_snapshot '.spendableBalance == "100" and .reservedBalance == "0"' >/dev/null
panel_action backActiveSends >/dev/null
wait_panel_snapshot '.activeSendsViewState == "list"
  and .activeSendsCount == 0
  and .activePendingTerminalState == ""' >/dev/null
panel_action backActiveSends >/dev/null

fund_send_fixture 100
IFS=$'\t' read -r recipient_pending_id recipient_pending_token \
  < <(create_pending_send_fixture 23)
adapter_call reconnect >/dev/null
wait_snapshot '.connectionState == "connected"' >/dev/null
panel_action openPanel >/dev/null
panel_action openActiveSends >/dev/null
panel_action selectActiveSend "$recipient_pending_id" >/dev/null
curl -fsS -X POST -H 'Content-Type: application/json' \
  --data '{"sendReclaimOutcome":"recipient_won"}' \
  "$base_url/__test__/mode" >/dev/null
panel_action beginActivePendingReclaim >/dev/null
panel_action confirmActivePendingReclaim >/dev/null
wait_panel_snapshot ".selectedActiveSendOperationId == \"$recipient_pending_id\"
  and .selectedActiveSend == null
  and .activePendingTerminalState == \"recipient_won\"" >/dev/null
wait_mock_status ".sendReclaimOperationIds[-1] == \"$recipient_pending_id\"" >/dev/null
wait_snapshot '.reservedBalance == "0"' >/dev/null
panel_action backActiveSends >/dev/null
panel_action backActiveSends >/dev/null

fund_send_fixture 100
IFS=$'\t' read -r retry_pending_id retry_pending_token \
  < <(create_pending_send_fixture 25)
adapter_call reconnect >/dev/null
wait_snapshot '.connectionState == "connected"' >/dev/null
panel_action openPanel >/dev/null
panel_action openActiveSends >/dev/null
panel_action selectActiveSend "$retry_pending_id" >/dev/null
curl -fsS -X POST -H 'Content-Type: application/json' \
  --data '{"sendReclaimOutcome":"reclaim_inconclusive"}' \
  "$base_url/__test__/mode" >/dev/null
panel_action beginActivePendingReclaim >/dev/null
panel_action confirmActivePendingReclaim >/dev/null
wait_panel_snapshot ".selectedActiveSend.id == \"$retry_pending_id\"
  and .selectedActiveSend.state == \"pending\"
  and .activePendingErrorCode == \"coco_error\"
  and .activePendingRefreshAvailable == true
  and .activePendingReclaimAvailable == true" >/dev/null

curl -fsS -X POST -H 'Content-Type: application/json' --data '{
  "sendRefreshUnavailableResponses":10
}' "$base_url/__test__/mode" >/dev/null
[[ $(panel_action refreshActivePendingSend) == "ok" ]] \
  || fail "unavailable exact Pending Refresh did not start"
wait_panel_snapshot ".selectedActiveSend.id == \"$retry_pending_id\"
  and .selectedActiveSend.state == \"pending\"
  and .activePendingErrorCode == \"refresh_unavailable\"
  and .activePendingReclaimAvailable == true" >/dev/null

curl -fsS -X POST -H 'Content-Type: application/json' --data '{
  "sendReclaimOutcome":"operation_conflict","sendCommandDelayMs":300,
  "sendRefreshUnavailableResponses":0
}' "$base_url/__test__/mode" >/dev/null
panel_action beginActivePendingReclaim >/dev/null
panel_action confirmActivePendingReclaim >/dev/null
[[ $(panel_action backActiveSends) == "ok" ]] \
  || fail "navigation was blocked during Reclaim"
[[ $(panel_action selectActiveSend "$retry_pending_id") == "ok" ]] \
  || fail "Pending Send could not be reselected while Reclaim was in flight"
wait_panel_snapshot '.activePendingActionState == "reclaiming"
  and .activePendingReclaimAvailable == false' >/dev/null
wait_panel_snapshot ".selectedActiveSend.id == \"$retry_pending_id\"
  and .activePendingErrorCode == \"operation_conflict\"
  and .activePendingReclaimAvailable == true" >/dev/null
curl -fsS -X POST -H 'Content-Type: application/json' \
  --data '{"sendCommandDelayMs":0}' "$base_url/__test__/mode" >/dev/null
panel_action beginActivePendingReclaim >/dev/null
panel_action confirmActivePendingReclaim >/dev/null
wait_panel_snapshot '.activePendingTerminalState == "reclaimed"' >/dev/null
panel_action backActiveSends >/dev/null
panel_action backActiveSends >/dev/null

fund_send_fixture 100
IFS=$'\t' read -r missing_pending_id missing_pending_token \
  < <(create_pending_send_fixture 27)
adapter_call reconnect >/dev/null
wait_snapshot '.connectionState == "connected"' >/dev/null
panel_action openPanel >/dev/null
panel_action openActiveSends >/dev/null
panel_action selectActiveSend "$missing_pending_id" >/dev/null
curl -fsS -X POST -H 'Content-Type: application/json' \
  --data '{"sendReclaimOutcome":"operation_not_found"}' \
  "$base_url/__test__/mode" >/dev/null
panel_action beginActivePendingReclaim >/dev/null
panel_action confirmActivePendingReclaim >/dev/null
wait_panel_snapshot ".selectedActiveSendOperationId == \"$missing_pending_id\"
  and .selectedActiveSend == null
  and .activePendingTerminalState == \"unavailable\"
  and .activePendingErrorCode == \"operation_not_found\"" >/dev/null
wait_mock_status ".sendReclaimOperationIds[-1] == \"$missing_pending_id\"" >/dev/null
panel_action backActiveSends >/dev/null
panel_action backActiveSends >/dev/null

final_pending_diagnostics="$(adapter_call snapshot)$(panel_call)$(curl -fsS "$base_url/__test__/status")"
if rg -q 'cashuA' <<<"$final_pending_diagnostics"; then
  fail "Pending Send bearer material escaped into diagnostics"
fi

echo "runtime: exact Pending Copy, Reveal, Refresh, Reclaim, navigation, and redaction passed"

curl -fsS -X POST -H 'Content-Type: application/json' \
  --data '{
    "balances":{"items":[
      {"mintUrl":"https://mint.one","unit":"sat","spendable":"100","reserved":"0","total":"100"},
      {"mintUrl":"https://mint.two","unit":"sat","spendable":"80","reserved":"0","total":"80"},
      {"mintUrl":"https://mint.untrusted","unit":"sat","spendable":"500","reserved":"0","total":"500"}
    ]},
    "mints":{"items":[
      {"mintUrl":"https://mint.one","name":"Mint One","trusted":true,"createdAt":"2026-08-20T12:00:00.000Z","updatedAt":"2026-08-20T12:00:00.000Z"},
      {"mintUrl":"https://mint.two","name":"Mint Two","trusted":true,"createdAt":"2026-08-20T12:00:00.000Z","updatedAt":"2026-08-20T12:00:00.000Z"},
      {"mintUrl":"https://mint.untrusted","name":"Untrusted Mint","trusted":false,"createdAt":"2026-08-20T12:00:00.000Z","updatedAt":"2026-08-20T12:00:00.000Z"}
    ]},
    "sendPrepared":{"items":[]},
    "sendInFlight":{"items":[]}
  }' "$base_url/__test__/resources" >/dev/null
adapter_call reconnect >/dev/null
wait_snapshot '
  .connectionState == "connected"
  and .spendableBalance == "680"
  and .trustedMintCount == 2
' >/dev/null
panel_action openPanel >/dev/null
wait_panel_snapshot '.opened == true
  and .walletState == "unlocked"
  and .sendViewState == "closed"
  and .receiveViewState == "closed"' >/dev/null
[[ $(panel_action openSend) == "ok" ]] \
  || fail "Send entry point was unavailable"
wait_panel_snapshot '
  .sendViewState == "entry"
  and .sendInputVisible == true
  and .sendAmount == ""
  and .sendMintOptionCount == 2
  and .sendSelectedMint == ""
  and .sendClipboardWrites == 0
' >/dev/null
[[ $(panel_action setSendAmount 60) == "ok" ]] \
  || fail "valid Send amount could not be entered"
wait_panel_snapshot '
  .sendAmount == "60"
  and .sendAmountValid == true
  and .sendMintOptionCount == 2
  and .sendSelectedMint == ""
' >/dev/null
[[ $(panel_action selectSendMint https://mint.two) == "ok" ]] \
  || fail "Cashu User could not choose between eligible Trusted Mints"
[[ $(panel_action selectSendMint https://mint.one) == "ok" ]] \
  || fail "Send mint could not be changed"
[[ $(panel_action selectSendMint https://mint.two) == "ok" ]] \
  || fail "Send mint could not be restored"
wait_panel_snapshot '
  .sendAmount == "60"
  and .sendSelectedMint == "https://mint.two"
' >/dev/null
[[ $(panel_action setSendAmount 90) == "ok" ]] \
  || fail "Send amount could not be changed"
wait_panel_snapshot '
  .sendAmount == "90"
  and .sendMintOptionCount == 1
  and .sendSelectedMint == "https://mint.one"
' >/dev/null
[[ $(panel_action cancelSend) == "ok" ]] \
  || fail "Send entry could not be closed"
wait_panel_snapshot '
  .sendViewState == "closed"
  and .sendInputFocused == false
  and .keyCatcherBlocked == false
' >/dev/null

echo "runtime: ordinary Send Mint and amount selection passed without Max"

open_send_flow 60 https://mint.one
before_send_prepare=$(curl -fsS "$base_url/__test__/status")
before_send_balances=$(jq -r '.resourceRequests.balances' <<<"$before_send_prepare")
before_send_prepared=$(jq -r '.resourceRequests.sendPrepared' <<<"$before_send_prepare")
before_send_in_flight=$(jq -r '.resourceRequests.sendInFlight' <<<"$before_send_prepare")
curl -fsS -X POST -H 'Content-Type: application/json' \
  --data '{"delayMs":400}' "$base_url/__test__/mode" >/dev/null
[[ $(panel_action prepareSend) == "ok" ]] \
  || fail "valid Send could not be prepared"
sleep 0.1
canonical_prepare_snapshot=$(panel_call)
jq -e '
  .sendViewState == "preparing"
  and .activeTransferCount == 0
' <<<"$canonical_prepare_snapshot" >/dev/null \
  || fail "command response became client-authoritative before canonical Send resources"
panel_snapshot=$(wait_panel_snapshot '
  .sendViewState == "review"
  and .sendReviewMint == "https://mint.one"
  and .sendReviewAmount == "60"
  and .sendReviewFee == "2"
  and .sendReviewInputAmount == "70"
  and .sendReviewNeedsSwap == true
  and .sendReviewSpendable == "30"
  and .sendReviewReserved == "70"
  and .spendableBalance == "610"
  and .reservedBalance == "70"
  and .activeTransferCount == 1
  and .sendInputFocused == false
  and .keyCatcherBlocked == false
')
curl -fsS -X POST -H 'Content-Type: application/json' \
  --data '{"delayMs":0}' "$base_url/__test__/mode" >/dev/null
adapter_snapshot=$(wait_snapshot '
  .sendState == "review"
  and .sendPreparedOperation.amount == "60"
  and .sendPreparedOperation.fee == "2"
  and .sendPreparedOperation.inputAmount == "70"
  and .sendPreparedOperation.needsSwap == true
  and (.activeTransfers | length) == 1
')
if rg -qi 'cashuA|proof|secret' <<<"$adapter_snapshot$panel_snapshot"; then
  fail "Prepared Send review exposed sensitive Wallet material"
fi
before_mint_revalidation=$(curl -fsS "$base_url/__test__/status" \
  | jq -r '.resourceRequests.mints')
curl -fsS -X POST -H 'Content-Type: application/json' \
  --data '{
    "mints":{"items":[
      {"mintUrl":"https://mint.one","name":"Mint One","trusted":false,"createdAt":"2026-08-20T12:00:00.000Z","updatedAt":"2026-08-20T12:06:00.000Z"},
      {"mintUrl":"https://mint.two","name":"Mint Two","trusted":true,"createdAt":"2026-08-20T12:00:00.000Z","updatedAt":"2026-08-20T12:00:00.000Z"},
      {"mintUrl":"https://mint.untrusted","name":"Untrusted Mint","trusted":false,"createdAt":"2026-08-20T12:00:00.000Z","updatedAt":"2026-08-20T12:00:00.000Z"}
    ]},
    "event":{
      "type":"mint.updated",
      "timestamp":"2026-08-20T12:06:00.000Z",
      "data":{"mintUrl":"https://mint.one"}
    }
  }' "$base_url/__test__/resources" >/dev/null
wait_mock_status ".resourceRequests.mints > $before_mint_revalidation" >/dev/null
wait_snapshot '.trustedMintCount == 1' >/dev/null
before_send_cancel=$(curl -fsS "$base_url/__test__/status")
before_send_cancel_balances=$(jq -r '.resourceRequests.balances' <<<"$before_send_cancel")
before_send_cancel_prepared=$(jq -r '.resourceRequests.sendPrepared' <<<"$before_send_cancel")
before_send_cancel_in_flight=$(jq -r '.resourceRequests.sendInFlight' <<<"$before_send_cancel")
[[ $(panel_action cancelSend) == "ok" ]] \
  || fail "Prepared Send could not be backed out"
wait_panel_snapshot '
  .sendViewState == "entry"
  and .sendReviewAmount == ""
  and .sendMintOptionCount == 1
  and .sendSelectedMint == "https://mint.two"
  and .spendableBalance == "680"
  and .reservedBalance == "0"
  and .activeTransferCount == 0
' >/dev/null
wait_mock_status ".sendCancelRequests == 1
  and .resourceRequests.balances > $before_send_cancel_balances
  and .resourceRequests.sendPrepared > $before_send_cancel_prepared
  and .resourceRequests.sendInFlight > $before_send_cancel_in_flight" >/dev/null
[[ $(panel_action cancelSend) == "ok" ]] \
  || fail "Send entry could not be closed after cancellation"
wait_panel_snapshot '.sendViewState == "closed"' >/dev/null

echo "runtime: Prepared Send review, reservation, and cancellation passed"

fund_send_fixture 80
open_send_flow 60
before_revoked_mint_prepare=$(curl -fsS "$base_url/__test__/status" \
  | jq -r '.sendCreateRequests')
curl -fsS -X POST -H 'Content-Type: application/json' \
  --data '{
    "mints":{"items":[{
      "mintUrl":"https://mint.one","name":"Mint One","trusted":false,
      "createdAt":"2026-08-20T12:00:00.000Z","updatedAt":"2026-08-20T12:07:00.000Z"
    }]},
    "event":{
      "type":"mint.updated","timestamp":"2026-08-20T12:07:00.000Z",
      "data":{"mintUrl":"https://mint.one"}
    }
  }' "$base_url/__test__/resources" >/dev/null
wait_snapshot '.trustedMintCount == 0' >/dev/null
wait_panel_snapshot '
  .sendViewState == "entry"
  and .sendSelectedMint == ""
  and .sendPrepareEnabled == false
' >/dev/null
[[ $(panel_action prepareSend) == "disabled" ]] \
  || fail "stale local selection authorized a revoked Mint"
wait_mock_status ".sendCreateRequests == $before_revoked_mint_prepare" >/dev/null
panel_action cancelSend >/dev/null
wait_panel_snapshot '.sendViewState == "closed"' >/dev/null

echo "runtime: canonical Known Mint trust gates ordinary Send"

fund_send_fixture 100
open_send_flow 60
curl -fsS -X POST -H 'Content-Type: application/json' \
  --data '{"delayMs":800}' "$base_url/__test__/mode" >/dev/null
curl -fsS -X POST -H 'Content-Type: application/json' \
  --data '{"event":{
    "type":"operation.updated","timestamp":"2026-08-20T12:00:00.000Z",
    "data":{"operationType":"send","operationId":"stale-send","mintUrl":"https://mint.one"}
  }}' "$base_url/__test__/resources" >/dev/null
curl -fsS -X POST -H 'Content-Type: application/json' \
  --data '{"event":{
    "type":"balance.updated","timestamp":"2026-08-20T12:00:00.000Z",
    "data":{"mintUrl":"https://mint.one"}
  }}' "$base_url/__test__/resources" >/dev/null
wait_mock_status '.resourceRequestsActive > 0' >/dev/null
curl -fsS -X POST -H 'Content-Type: application/json' \
  --data '{"delayMs":0,"sendCreateInterruption":"malformed_after_commit"}' \
  "$base_url/__test__/mode" >/dev/null
[[ $(panel_action prepareSend) == "disabled" ]] \
  || fail "Send mutation was enabled before targeted canonical synchronization"
wait_panel_snapshot '.activeSendsCanonicalSynchronized == true' >/dev/null
[[ $(panel_action prepareSend) == "ok" ]] \
  || fail "Send mutation did not recover after targeted canonical synchronization"
wait_panel_snapshot '.sendViewState == "error" and .sendErrorCode == "invalid_response"
  and .activeSendsCount == 1' >/dev/null
[[ $(panel_action retrySend) == "ok" ]] \
  || fail "ambiguous malformed Send could not retry its exact intent"
wait_panel_snapshot '.sendViewState == "review" and .sendReviewAmount == "60"' >/dev/null
wait_mock_status '.resourceRequestsActive == 0' >/dev/null
wait_panel_snapshot '
  .sendViewState == "review"
  and .sendReviewAmount == "60"
  and .reservedBalance == "70"
  and .activeTransferCount == 1
' >/dev/null
panel_action cancelSend >/dev/null
wait_panel_snapshot '.sendViewState == "entry" and .reservedBalance == "0"' >/dev/null
panel_action cancelSend >/dev/null
wait_panel_snapshot '.sendViewState == "closed"' >/dev/null

echo "runtime: Send reconciliation supersedes stale collection fetches"

fund_send_fixture 100
open_send_flow 60
before_queued_send_event=$(curl -fsS "$base_url/__test__/status" \
  | jq -r '.resourceRequests.sendPrepared')
curl -fsS -X POST -H 'Content-Type: application/json' \
  --data '{"sendCreateDelayMs":800,"sendCreateInterruption":"malformed_after_commit"}' \
  "$base_url/__test__/mode" >/dev/null
panel_action prepareSend >/dev/null
wait_panel_snapshot '.sendViewState == "preparing"' >/dev/null
curl -fsS -X POST -H 'Content-Type: application/json' \
  --data '{"event":{
    "type":"operation.updated","timestamp":"2026-08-20T12:00:00.000Z",
    "data":{"operationType":"send","operationId":"external-send","mintUrl":"https://mint.one"}
  }}' "$base_url/__test__/resources" >/dev/null
curl -fsS -X POST -H 'Content-Type: application/json' \
  --data '{"sendCreateDelayMs":0}' "$base_url/__test__/mode" >/dev/null
wait_panel_snapshot '.sendViewState == "error" and .sendErrorCode == "invalid_response"' >/dev/null
panel_action retrySend >/dev/null
wait_panel_snapshot '.sendViewState == "review" and .sendReviewAmount == "60"' >/dev/null
wait_mock_status ".resourceRequests.sendPrepared >= $((before_queued_send_event + 2))" >/dev/null
panel_action cancelSend >/dev/null
wait_panel_snapshot '.sendViewState == "entry" and .reservedBalance == "0"' >/dev/null
panel_action cancelSend >/dev/null
wait_panel_snapshot '.sendViewState == "closed"' >/dev/null

echo "runtime: Send invalidations are replayed after mutation reconciliation"

fund_send_fixture 100
open_send_flow 60
before_preparing_rotation=$(adapter_call snapshot | jq -r '.rotationCount')
before_preparing_rotation_fetch=$(curl -fsS "$base_url/__test__/status" \
  | jq -r '.resourceRequests.openapi')
before_preparing_rotation_cancel=$(curl -fsS "$base_url/__test__/status" \
  | jq -r '.sendCancelRequests')
curl -fsS -X POST -H 'Content-Type: application/json' \
  --data '{"sendCreateDelayMs":1500}' "$base_url/__test__/mode" >/dev/null
panel_action prepareSend >/dev/null
wait_panel_snapshot '.sendViewState == "preparing"' >/dev/null
adapter_call rotate >/dev/null
adapter_call reconnect >/dev/null
sleep 0.1
wait_panel_snapshot '.sendViewState == "preparing"' >/dev/null
wait_mock_status ".resourceRequests.openapi == $before_preparing_rotation_fetch
  and .sendCancelRequests == $before_preparing_rotation_cancel" >/dev/null
curl -fsS -X POST -H 'Content-Type: application/json' \
  --data '{"sendCreateDelayMs":0}' "$base_url/__test__/mode" >/dev/null
wait_panel_snapshot '.sendViewState == "review" and .sendReviewAmount == "60"' >/dev/null
wait_snapshot ".connectionState == \"connected\"
  and .rotationCount == $((before_preparing_rotation + 1))
  and .streamRotationScheduled == true
  and .sendState == \"review\"
  and .canonicalRefreshInProgress == false" >/dev/null
wait_mock_status ".resourceRequests.openapi > $before_preparing_rotation_fetch
  and .sendCancelRequests == $before_preparing_rotation_cancel" >/dev/null
panel_action cancelSend >/dev/null
wait_panel_snapshot '.sendViewState == "entry" and .reservedBalance == "0"' >/dev/null
panel_action cancelSend >/dev/null
wait_panel_snapshot '.sendViewState == "closed"' >/dev/null

fund_send_fixture 100
prepare_send_flow 60
before_review_rotation=$(adapter_call snapshot | jq -r '.rotationCount')
before_review_rotation_cancel=$(curl -fsS "$base_url/__test__/status" \
  | jq -r '.sendCancelRequests')
adapter_call rotate >/dev/null
wait_snapshot ".connectionState == \"connected\"
  and .rotationCount == $((before_review_rotation + 1))
  and .sendState == \"review\"
  and .canonicalRefreshInProgress == false" >/dev/null
wait_panel_snapshot '.sendViewState == "review" and .sendReviewAmount == "60"' >/dev/null
wait_mock_status ".sendCancelRequests == $before_review_rotation_cancel" >/dev/null
panel_action cancelSend >/dev/null
wait_panel_snapshot '.sendViewState == "entry" and .reservedBalance == "0"' >/dev/null
panel_action cancelSend >/dev/null
wait_panel_snapshot '.sendViewState == "closed"' >/dev/null

echo "runtime: stream rotation preserves preparing and reviewed Sends"

fund_send_fixture 100
reloaded_send=$(curl -fsS -H "Authorization: Bearer $credential" -X POST \
  -H 'Content-Type: application/json' \
  --data '{"mintUrl":"https://mint.one","unit":"sat","amount":"60"}' \
  "$base_url/v1/operations/send")
reloaded_send_id=$(jq -er '.id' <<<"$reloaded_send")
adapter_call reconnect >/dev/null
wait_snapshot ".activeTransfers[0].id == \"$reloaded_send_id\"
  and .activeTransfers[0].state == \"prepared\"" >/dev/null
panel_action openPanel >/dev/null
[[ $(panel_action openSend) == "ok" ]] \
  || fail "fresh Send entry did not open beside a canonical Prepared Send"
wait_panel_snapshot ".sendViewState == \"entry\"
  and .sendAmount == \"\"
  and .sendReviewAmount == \"\"
  and .reservedBalance == \"70\"
  and .activeSendsCount == 1
  and .sendInputFocused == true" >/dev/null
panel_action setSendAmount 20 >/dev/null
[[ $(panel_action prepareSend) == "ok" ]] \
  || fail "existing Prepared Send blocked a fundable fresh Send"
wait_panel_snapshot ".sendViewState == \"review\"
  and .sendReviewAmount == \"20\"
  and .sendOperationId != \"$reloaded_send_id\"
  and .activeSendsCount == 2
  and .spendableBalance == \"0\" and .reservedBalance == \"100\"" >/dev/null
panel_action cancelSend >/dev/null
wait_panel_snapshot '.sendViewState == "entry" and .activeSendsCount == 1
  and .spendableBalance == "30" and .reservedBalance == "70"' >/dev/null
panel_action cancelSend >/dev/null
wait_panel_snapshot '.sendViewState == "closed"' >/dev/null
before_explicit_prepared_cancel=$(curl -fsS "$base_url/__test__/status" \
  | jq -r '.sendCancelRequests')
panel_action openActiveSends >/dev/null
panel_action selectActiveSend "$reloaded_send_id" >/dev/null
wait_panel_snapshot ".activeSendsViewState == \"detail\"
  and .selectedActiveSend.id == \"$reloaded_send_id\"
  and .selectedActiveSend.state == \"prepared\"
  and .selectedActiveSend.requestedAmount == \"60\"
  and .selectedActiveSend.fee == \"2\"
  and .selectedActiveSend.inputAmount == \"70\"
  and .selectedActiveSend.needsSwap == true
  and .activePreparedBalanceSpendable == \"30\"
  and .activePreparedBalanceReserved == \"70\"
  and .activePreparedConfirmAvailable == true
  and .activePreparedCancelAvailable == true" >/dev/null
[[ $(panel_action cancelActivePreparedSend) == "ok" ]] \
  || fail "exact Prepared Send Cancel was unavailable"
wait_panel_snapshot '.activePreparedTerminalState == "cancelled"
  and .spendableBalance == "100" and .reservedBalance == "0"' >/dev/null
wait_mock_status ".sendCancelRequests == $((before_explicit_prepared_cancel + 1))" >/dev/null
panel_action backActiveSends >/dev/null
panel_action backActiveSends >/dev/null

echo "runtime: primary Send stays fresh and Prepared detail cancels exact Operation"

fund_send_fixture 300
first_prepared=$(curl -fsS -H "Authorization: Bearer $credential" \
  -H 'Idempotency-Key: runtime-prepared-one' -H 'Content-Type: application/json' \
  -X POST --data '{"mintUrl":"https://mint.one","unit":"sat","amount":"60"}' \
  "$base_url/v1/operations/send")
first_prepared_id=$(jq -er '.id' <<<"$first_prepared")
second_prepared=$(curl -fsS -H "Authorization: Bearer $credential" \
  -H 'Idempotency-Key: runtime-prepared-two' -H 'Content-Type: application/json' \
  -X POST --data '{"mintUrl":"https://mint.one","unit":"sat","amount":"60"}' \
  "$base_url/v1/operations/send")
second_prepared_id=$(jq -er '.id' <<<"$second_prepared")
adapter_call reconnect >/dev/null
wait_snapshot "(.activeSends | length) == 2
  and ([.activeSends[].id] | index(\"$first_prepared_id\") != null)
  and ([.activeSends[].id] | index(\"$second_prepared_id\") != null)
  and .spendableBalance == \"160\" and .reservedBalance == \"140\"" >/dev/null
panel_action openPanel >/dev/null
panel_action openActiveSends >/dev/null
panel_action selectActiveSend "$first_prepared_id" >/dev/null
curl -fsS -X POST -H 'Content-Type: application/json' \
  --data '{"sendCommandDelayMs":800}' "$base_url/__test__/mode" >/dev/null
[[ $(panel_action confirmActivePreparedSend) == "ok" ]] \
  || fail "first exact Prepared Send could not be confirmed"
wait_panel_snapshot ".activePreparedActionState == \"executing\"
  and .selectedActiveSendOperationId == \"$first_prepared_id\"" >/dev/null
[[ $(panel_action backActiveSends) == "ok" ]] \
  || fail "navigation was blocked during Prepared Send confirmation"
[[ $(panel_action selectActiveSend "$second_prepared_id") == "ok" ]] \
  || fail "unrelated Prepared Send was not browseable during confirmation"
wait_panel_snapshot ".selectedActiveSendOperationId == \"$second_prepared_id\"
  and .activePreparedConfirmAvailable == false
  and .activePreparedCancelAvailable == false" >/dev/null
curl -fsS -X POST -H 'Content-Type: application/json' \
  --data '{"sendCommandDelayMs":0}' "$base_url/__test__/mode" >/dev/null
wait_snapshot "(.activeSends | any(.id == \"$first_prepared_id\" and .state == \"pending\"))
  and (.activeSends | any(.id == \"$second_prepared_id\" and .state == \"prepared\"))" >/dev/null
wait_panel_snapshot ".selectedActiveSendOperationId == \"$second_prepared_id\"
  and .selectedActiveSend.id == \"$second_prepared_id\"
  and .activePreparedCancelAvailable == true" >/dev/null
curl -fsS -X POST -H 'Content-Type: application/json' \
  --data '{"sendCommandDelayMs":800}' "$base_url/__test__/mode" >/dev/null
[[ $(panel_action cancelActivePreparedSend) == "ok" ]] \
  || fail "second exact Prepared Send could not be cancelled"
wait_panel_snapshot '.activePreparedActionState == "cancelling"' >/dev/null
[[ $(panel_action backActiveSends) == "ok" ]] \
  || fail "navigation was blocked during Prepared Send cancellation"
curl -fsS -X POST -H 'Content-Type: application/json' \
  --data '{"sendCommandDelayMs":0}' "$base_url/__test__/mode" >/dev/null
wait_snapshot "(.activeSends | length) == 1
  and .activeSends[0].id == \"$first_prepared_id\"
  and .activeSends[0].state == \"pending\"
  and .spendableBalance == \"230\" and .reservedBalance == \"70\"" >/dev/null
panel_action backActiveSends >/dev/null
curl -fsS -H "Authorization: Bearer $credential" -X POST \
  "$base_url/v1/operations/send/$first_prepared_id/reclaim" >/dev/null
adapter_call reconnect >/dev/null
wait_snapshot '.activeSends == [] and .reservedBalance == "0"' >/dev/null

echo "runtime: multiple Prepared Sends mutate exactly and remain browseable in one lane"

for external_send_state in removed pending; do
  fund_send_fixture 100
  prepare_send_flow 60
  external_send_id=$(curl -fsS -H "Authorization: Bearer $credential" \
    "$base_url/v1/operations/send/prepared" | jq -er '.items[0].id')
  before_external_cancel=$(curl -fsS "$base_url/__test__/status" \
    | jq -r '.sendCancelRequests')
  if [[ $external_send_state == pending ]]; then
    curl -fsS -H "Authorization: Bearer $credential" -X POST \
      "$base_url/v1/operations/send/$external_send_id/execute" >/dev/null
    external_send_error=operation_conflict
  else
    curl -fsS -X POST -H 'Content-Type: application/json' \
      --data "$(jq -cn --arg id "$external_send_id" '{operationId:$id}')" \
      "$base_url/__test__/remove-send" >/dev/null
    external_send_error=operation_not_found
  fi
  wait_panel_snapshot ".sendViewState == \"error\"
    and .sendErrorCode == \"$external_send_error\"
    and .sendReviewAmount == \"\"" >/dev/null
  [[ $(panel_action cancelSend) == "ok" ]] \
    || fail "externally $external_send_state Send could not leave stale review"
  wait_panel_snapshot '.sendViewState == "closed"' >/dev/null
  wait_mock_status ".sendCancelRequests == $before_external_cancel" >/dev/null
done

echo "runtime: externally changed Prepared Sends clear stale review focus"

fund_send_fixture 100
open_send_flow 60
curl -fsS -X POST -H 'Content-Type: application/json' \
  --data '{"sendCreateInterruption":"malformed_after_commit"}' \
  "$base_url/__test__/mode" >/dev/null
panel_action prepareSend >/dev/null
wait_panel_snapshot '
  .sendViewState == "error"
  and .sendErrorCode == "invalid_response"
  and .activeSendsCount == 1
  and .sendReviewAmount == ""
' >/dev/null
panel_action retrySend >/dev/null
wait_panel_snapshot '.sendViewState == "review" and .sendReviewAmount == "60"
  and .sendReviewReserved == "70"' >/dev/null
panel_action cancelSend >/dev/null
wait_panel_snapshot '
  .sendViewState == "entry"
  and .spendableBalance == "100"
  and .reservedBalance == "0"
' >/dev/null
panel_action cancelSend >/dev/null
wait_panel_snapshot '.sendViewState == "closed"' >/dev/null

echo "runtime: malformed committed Send retries by Idempotency-Key"

fund_send_fixture 100
open_send_flow 60
before_ambiguous_status=$(curl -fsS "$base_url/__test__/status")
before_ambiguous_create=$(jq -r '.sendCreateRequests' <<<"$before_ambiguous_status")
before_ambiguous_unique=$(jq -r '.sendIdempotencyUniqueKeys' <<<"$before_ambiguous_status")
before_ambiguous_replays=$(jq -r '.sendIdempotencyReplays' <<<"$before_ambiguous_status")
curl -fsS -X POST -H 'Content-Type: application/json' \
  --data '{"sendCreateInterruption":"after_commit"}' \
  "$base_url/__test__/mode" >/dev/null
panel_action prepareSend >/dev/null
wait_panel_snapshot '
  .sendViewState == "error"
  and .sendErrorCode == "transport_unavailable"
  and .sendReviewAmount == ""
  and .activeSendsCount == 1
' >/dev/null
wait_mock_status ".sendCreateRequests == $((before_ambiguous_create + 1))" >/dev/null
[[ $(panel_action prepareSend) == "disabled" ]] \
  || fail "ambiguous Send creation allowed an unkeyed duplicate preparation"
[[ $(panel_action retrySend) == "ok" ]] \
  || fail "ambiguous Send creation did not expose Retry"
wait_panel_snapshot '.sendViewState == "review" and .sendReviewAmount == "60"
  and .sendReviewReserved == "70"' >/dev/null
wait_mock_status ".sendCreateRequests == $((before_ambiguous_create + 2))
  and .sendIdempotencyUniqueKeys == $((before_ambiguous_unique + 1))
  and .sendIdempotencyReplays == $((before_ambiguous_replays + 1))" >/dev/null
panel_action cancelSend >/dev/null
wait_panel_snapshot '
  .sendViewState == "entry"
  and .spendableBalance == "100"
  and .reservedBalance == "0"
' >/dev/null
panel_action cancelSend >/dev/null
wait_panel_snapshot '.sendViewState == "closed"' >/dev/null

echo "runtime: ambiguous Send retry reuses one Idempotency-Key and reservation"

fund_send_fixture 100
open_send_flow 60
before_deferred_ambiguous_cancel=$(curl -fsS "$base_url/__test__/status" \
  | jq -r '.sendCancelRequests')
curl -fsS -X POST -H 'Content-Type: application/json' \
  --data '{
    "delayMs":400,
    "sendCreateInterruption":"after_commit",
    "sendPrepareReconcileError":true
  }' "$base_url/__test__/mode" >/dev/null
panel_action prepareSend >/dev/null
wait_panel_snapshot '.sendViewState == "preparing"' >/dev/null
panel_action closePanel >/dev/null
curl -fsS -X POST -H 'Content-Type: application/json' \
  --data '{"delayMs":0}' "$base_url/__test__/mode" >/dev/null
wait_snapshot '
  .sendState == "error"
  and .activeTransfers == []
' >/dev/null
adapter_call reconnect >/dev/null
wait_mock_status ".sendCancelRequests == $before_deferred_ambiguous_cancel" >/dev/null
wait_snapshot '
  .connectionState == "connected"
  and .sendState == "error"
  and .spendableBalance == "30"
  and .reservedBalance == "70"
  and (.activeSends | length) == 1
' >/dev/null
deferred_ambiguous_id=$(curl -fsS -H "Authorization: Bearer $credential" \
  "$base_url/v1/operations/send/prepared" | jq -er '.items[0].id')
curl -fsS -H "Authorization: Bearer $credential" -X POST \
  "$base_url/v1/operations/send/$deferred_ambiguous_id/cancel" >/dev/null
adapter_call reconnect >/dev/null
wait_snapshot '.reservedBalance == "0" and .activeSends == []' >/dev/null

echo "runtime: closing an ambiguous Send never cancels its durable reservation"

fund_send_fixture 100
open_send_flow 60
before_uncertain_prepare=$(curl -fsS "$base_url/__test__/status" \
  | jq -r '.sendCancelRequests')
curl -fsS -X POST -H 'Content-Type: application/json' \
  --data '{"sendPrepareReconcileError":true}' \
  "$base_url/__test__/mode" >/dev/null
panel_action prepareSend >/dev/null
wait_panel_snapshot '
  .sendViewState == "error"
  and .sendError != ""
  and .activeTransferCount == 0
' >/dev/null
[[ $(panel_action cancelSend) == "ok" ]] \
  || fail "unreconciled Prepared Send could not be backed out"
wait_mock_status ".sendCancelRequests == $((before_uncertain_prepare + 1))" >/dev/null
wait_panel_snapshot '
  .sendViewState == "entry"
  and .spendableBalance == "100"
  and .reservedBalance == "0"
  and .activeTransferCount == 0
' >/dev/null
panel_action cancelSend >/dev/null
wait_panel_snapshot '.sendViewState == "closed"' >/dev/null

echo "runtime: unreconciled Prepared Send remains cancellable"

fund_send_fixture 100
open_send_flow 60
before_deferred_cancel=$(curl -fsS "$base_url/__test__/status" \
  | jq -r '.sendCancelRequests')
curl -fsS -X POST -H 'Content-Type: application/json' \
  --data '{"delayMs":400,"sendPrepareReconcileError":true}' \
  "$base_url/__test__/mode" >/dev/null
panel_action prepareSend >/dev/null
wait_panel_snapshot '.sendViewState == "preparing"' >/dev/null
[[ $(panel_action closePanel) == "ok" ]] \
  || fail "panel could not close while Send preparation was reconciling"
curl -fsS -X POST -H 'Content-Type: application/json' \
  --data '{"delayMs":0}' "$base_url/__test__/mode" >/dev/null
wait_mock_status ".sendCancelRequests == $before_deferred_cancel" >/dev/null
adapter_call reconnect >/dev/null
wait_snapshot '
  .spendableBalance == "30"
  and .reservedBalance == "70"
  and (.activeSends | length) == 1
' >/dev/null
deferred_prepared_id=$(curl -fsS -H "Authorization: Bearer $credential" \
  "$base_url/v1/operations/send/prepared" | jq -er '.items[0].id')
curl -fsS -H "Authorization: Bearer $credential" -X POST \
  "$base_url/v1/operations/send/$deferred_prepared_id/cancel" >/dev/null
adapter_call reconnect >/dev/null
wait_snapshot '.reservedBalance == "0" and .activeSends == []' >/dev/null

echo "runtime: hidden preparation remains durable after reconciliation failure"

prepare_send_flow 60 https://mint.one
curl -fsS -X POST -H 'Content-Type: application/json' \
  --data '{"sendCancelError":"operation_conflict"}' \
  "$base_url/__test__/mode" >/dev/null
before_hidden_cancel=$(curl -fsS "$base_url/__test__/status" \
  | jq -r '.sendCancelRequests')
panel_action closePanel >/dev/null
sleep 0.25
after_hidden_cancel=$(curl -fsS "$base_url/__test__/status" \
  | jq -r '.sendCancelRequests')
[[ $after_hidden_cancel -eq $before_hidden_cancel ]] \
  || fail "panel dismissal signalled Prepared Send cancellation"
curl -fsS -X POST -H 'Content-Type: application/json' \
  --data '{"sendCancelError":""}' "$base_url/__test__/mode" >/dev/null
hidden_prepared_id=$(curl -fsS -H "Authorization: Bearer $credential" \
  "$base_url/v1/operations/send/prepared" | jq -er '.items[0].id')
curl -fsS -H "Authorization: Bearer $credential" -X POST \
  "$base_url/v1/operations/send/$hidden_prepared_id/cancel" >/dev/null
adapter_call reconnect >/dev/null
wait_snapshot '.activeTransfers == [] and .reservedBalance == "0"' >/dev/null

echo "runtime: panel dismissal never cancels a Prepared Send"

prepare_send_flow 60 https://mint.one
wait_panel_snapshot '.sendReviewAmount == "60"' >/dev/null
clipboard_sentinel='send-clipboard-must-stay-unchanged'
set_sensitive_clipboard "$clipboard_sentinel"
before_send_execute=$(curl -fsS "$base_url/__test__/status")
before_send_execute_count=$(jq -r '.sendExecuteRequests' <<<"$before_send_execute")
curl -fsS -X POST -H 'Content-Type: application/json' \
  --data '{"delayMs":400,"sendCommandDelayMs":400}' \
  "$base_url/__test__/mode" >/dev/null
[[ $(panel_action confirmSend) == "ok" ]] \
  || fail "Prepared Send could not be explicitly confirmed"
wait_panel_snapshot '.sendViewState == "executing"' >/dev/null
wait_mock_status ".sendExecuteRequests > $before_send_execute_count" >/dev/null
sleep 0.1
canonical_execute_snapshot=$(panel_call)
jq -e '
  .sendViewState == "result"
  and .activeTransferStateLabel == "Send ready"
' <<<"$canonical_execute_snapshot" >/dev/null \
  || fail "execute response became client-authoritative before canonical Send resources"
panel_snapshot=$(wait_panel_snapshot '
  .sendViewState == "result"
  and .sendCopyAvailable == true
  and .sendClipboardWrites == 0
  and .activeTransferCount == 1
  and .activeTransferStateLabel == "Pending Send"
')
curl -fsS -X POST -H 'Content-Type: application/json' \
  --data '{"delayMs":0,"sendCommandDelayMs":0}' \
  "$base_url/__test__/mode" >/dev/null
adapter_snapshot=$(wait_snapshot '
  .sendState == "result"
  and .sendPreparedOperation == null
  and (.activeTransfers | length) == 1
  and .activeTransfers[0].type == "send"
  and .activeTransfers[0].state == "pending"
')
[[ $(wl-paste --no-newline) == "$clipboard_sentinel" ]] \
  || fail "Send confirmation wrote the clipboard automatically"
if rg -qi 'cashuA|proof|secret' <<<"$adapter_snapshot$panel_snapshot"; then
  fail "outgoing Send token entered generic adapter or panel diagnostics"
fi
[[ $(panel_action copySend) == "ok" ]] \
  || fail "explicit outgoing-token Copy action was unavailable"
copied_send_token=$(wl-paste --no-newline)
[[ $copied_send_token == cashuA* && $copied_send_token != "$clipboard_sentinel" ]] \
  || fail "explicit Copy did not write the outgoing Cashu token"
wait_panel_snapshot '
  .sendViewState == "result"
  and .sendCopyAvailable == true
  and .sendClipboardWrites == 1
' >/dev/null
send_status=$(curl -fsS "$base_url/__test__/status")
safe_send_prepared=$(curl -fsS -H "Authorization: Bearer $credential" \
  "$base_url/v1/operations/send/prepared")
safe_send_in_flight=$(curl -fsS -H "Authorization: Bearer $credential" \
  "$base_url/v1/operations/send/in-flight")
if rg -Fq "$copied_send_token" \
    <<<"$(adapter_call snapshot)$(panel_call)$send_status$safe_send_prepared$safe_send_in_flight" \
    || rg -Fq "$copied_send_token" "$shell_log" "$mock_log"; then
  fail "outgoing Send token escaped the explicit copy interaction"
fi
[[ $(panel_action doneSend) == "ok" ]] \
  || fail "completed Send result could not be dismissed"
wait_panel_snapshot '
  .sendViewState == "closed"
  and .sendCopyAvailable == false
' >/dev/null
[[ $(wl-paste --no-newline) == "$copied_send_token" ]] \
  || fail "dismissing Send unexpectedly rewrote the explicit clipboard result"

echo "runtime: Send execution, redaction, and explicit Copy passed"

fund_send_fixture 100
prepare_send_flow 60
reconcile_close_sentinel='send-reconcile-close-must-not-copy'
set_sensitive_clipboard "$reconcile_close_sentinel"
curl -fsS -X POST -H 'Content-Type: application/json' \
  --data '{"delayMs":800,"sendExecuteSuppressEvents":true}' \
  "$base_url/__test__/mode" >/dev/null
panel_action confirmSend >/dev/null
wait_panel_snapshot '
  .sendViewState == "result"
  and .sendCopyAvailable == true
' >/dev/null
[[ $(panel_action doneSend) == "ok" ]] \
  || fail "Send result could not close during canonical reconciliation"
wait_panel_snapshot '
  .sendViewState == "closed"
  and .sendCopyAvailable == false
' >/dev/null
[[ $(wl-paste --no-newline) == "$reconcile_close_sentinel" ]] \
  || fail "closing a reconciling Send result copied its token"
curl -fsS -X POST -H 'Content-Type: application/json' \
  --data '{"delayMs":0}' "$base_url/__test__/mode" >/dev/null
wait_snapshot '
  .sendState == "idle"
  and (.activeTransfers | length) == 1
  and .activeTransfers[0].type == "send"
  and .activeTransfers[0].state == "pending"
' >/dev/null

echo "runtime: closing a Send result preserves canonical reconciliation"

curl -fsS -X POST -H 'Content-Type: application/json' \
  --data '{"sendPrepared":{"items":[]},"sendInFlight":{"items":[]}}' \
  "$base_url/__test__/resources" >/dev/null
adapter_call reconnect >/dev/null
wait_snapshot '.connectionState == "connected" and .activeTransfers == []' >/dev/null

fund_send_fixture 100
prepare_send_flow 60
refresh_failure_sentinel='send-refresh-failure-must-not-copy-automatically'
set_sensitive_clipboard "$refresh_failure_sentinel"
curl -fsS -X POST -H 'Content-Type: application/json' \
  --data '{"resources":"unavailable"}' "$base_url/__test__/mode" >/dev/null
panel_action confirmSend >/dev/null
wait_panel_snapshot '
  .sendViewState == "result"
  and .sendCopyAvailable == true
  and .sendClipboardWrites == 0
' >/dev/null
[[ $(wl-paste --no-newline) == "$refresh_failure_sentinel" ]] \
  || fail "failed post-execute refresh copied the Send token automatically"
curl -fsS -X POST -H 'Content-Type: application/json' \
  --data '{"resources":"ok"}' "$base_url/__test__/mode" >/dev/null
[[ $(panel_action copySend) == "ok" ]] \
  || fail "valid Send result disappeared after canonical refresh failure"
refresh_failure_token=$(wl-paste --no-newline)
[[ $refresh_failure_token == cashuA* ]] \
  || fail "surviving Send result did not copy its outgoing token"
panel_action doneSend >/dev/null
adapter_call reconnect >/dev/null
wait_snapshot '.connectionState == "connected"' >/dev/null

echo "runtime: Send result survives post-execute refresh failure"

fund_send_fixture 100
panel_action closePanel >/dev/null
curl -fsS -X POST -H 'Content-Type: application/json' \
  --data '{"delayMs":800}' "$base_url/__test__/mode" >/dev/null
before_overlapping_prepare=$(curl -fsS "$base_url/__test__/status" \
  | jq -r '.sendCreateRequests')
panel_action openPanel >/dev/null
wait_mock_status '.resourceRequestsActive > 0' >/dev/null
panel_action openSend >/dev/null
panel_action setSendAmount 60 >/dev/null
panel_action selectSendMint https://mint.one >/dev/null
wait_panel_snapshot '.sendPrepareEnabled == false' >/dev/null
[[ $(panel_action prepareSend) == "disabled" ]] \
  || fail "Send preparation overlapped an older full canonical fetch"
wait_mock_status ".sendCreateRequests == $before_overlapping_prepare" >/dev/null
curl -fsS -X POST -H 'Content-Type: application/json' \
  --data '{"delayMs":0}' "$base_url/__test__/mode" >/dev/null
wait_mock_status '.resourceRequestsActive == 0' >/dev/null
wait_snapshot '.connectionState == "connected"
  and .canonicalRefreshInProgress == false' >/dev/null
wait_panel_snapshot '
  .sendViewState == "entry"
  and .sendAmount == "60"
  and .sendSelectedMint == "https://mint.one"
  and .sendPrepareEnabled == true
' >/dev/null
[[ $(panel_action prepareSend) == "ok" ]] \
  || fail "Send preparation did not recover after canonical fetch completion"
wait_panel_snapshot '.sendViewState == "review"' >/dev/null
before_overlapping_execute=$(curl -fsS "$base_url/__test__/status" \
  | jq -r '.sendExecuteRequests')
before_refresh_dismiss_cancel=$(curl -fsS "$base_url/__test__/status" \
  | jq -r '.sendCancelRequests')
curl -fsS -X POST -H 'Content-Type: application/json' \
  --data '{"delayMs":800}' "$base_url/__test__/mode" >/dev/null
adapter_call reconnect >/dev/null
wait_mock_status '.resourceRequestsActive > 0' >/dev/null
wait_panel_snapshot '.sendViewState == "review" and .sendConfirmEnabled == false' >/dev/null
[[ $(panel_action confirmSend) == "disabled" ]] \
  || fail "reviewed Send executed during a full canonical fetch"
wait_mock_status ".sendExecuteRequests == $before_overlapping_execute" >/dev/null
[[ $(panel_action closePanel) == "ok" ]] \
  || fail "reviewed Send could not be dismissed during a canonical refresh"
curl -fsS -X POST -H 'Content-Type: application/json' \
  --data '{"delayMs":0}' "$base_url/__test__/mode" >/dev/null
wait_snapshot '.connectionState == "connected"
  and .canonicalRefreshInProgress == false
  and .sendState == "idle"
  and .reservedBalance == "70"
  and (.activeSends | length) == 1' >/dev/null
wait_mock_status ".sendCancelRequests == $before_refresh_dismiss_cancel" >/dev/null
refresh_dismissed_id=$(curl -fsS -H "Authorization: Bearer $credential" \
  "$base_url/v1/operations/send/prepared" | jq -er '.items[0].id')
curl -fsS -H "Authorization: Bearer $credential" -X POST \
  "$base_url/v1/operations/send/$refresh_dismissed_id/cancel" >/dev/null
adapter_call reconnect >/dev/null
wait_snapshot '.reservedBalance == "0" and .activeSends == []' >/dev/null

echo "runtime: Send commands wait for full canonical fetch completion"

fund_send_fixture 100
panel_action openPanel >/dev/null
panel_action openSend >/dev/null
for invalid_send_amount in 0 01 -1 1.5; do
  panel_action setSendAmount "$invalid_send_amount" >/dev/null
  wait_panel_snapshot '.sendAmountValid == false and .sendPrepareEnabled == false' >/dev/null
  [[ $(panel_action prepareSend) == "disabled" ]] \
    || fail "invalid Send amount $invalid_send_amount reached cocod"
done
panel_action setSendAmount 60 >/dev/null
before_stale_send=$(curl -fsS "$base_url/__test__/status")
before_stale_balances=$(jq -r '.resourceRequests.balances' <<<"$before_stale_send")
curl -fsS -X POST -H 'Content-Type: application/json' \
  --data '{"balances":{"items":[{"mintUrl":"https://mint.one","unit":"sat","spendable":"50","reserved":"0","total":"50"}]}}' \
  "$base_url/__test__/resources" >/dev/null
panel_action setSendAmount 60 >/dev/null
[[ $(panel_action prepareSend) == "ok" ]] \
  || fail "ordinary Send preparation did not reach cocod"
wait_panel_snapshot '
  .sendViewState == "error"
  and .sendErrorCode == "coco_error"
  and .sendError != ""
  and .spendableBalance == "50"
' >/dev/null
wait_mock_status ".resourceRequests.balances > $before_stale_balances" >/dev/null
panel_action cancelSend >/dev/null
wait_panel_snapshot '.sendViewState == "closed"' >/dev/null

for send_create_error in mint_not_registered mint_not_trusted mint_unavailable; do
  fund_send_fixture 100
  open_send_flow 60
  curl -fsS -X POST -H 'Content-Type: application/json' \
    --data "$(jq -cn --arg code "$send_create_error" '{sendCreateError:$code}')" \
    "$base_url/__test__/mode" >/dev/null
  panel_action prepareSend >/dev/null
  wait_panel_snapshot ".sendViewState == \"error\"
    and .sendErrorCode == \"coco_error\"
    and .sendError != \"\"" >/dev/null
  panel_action cancelSend >/dev/null
  wait_panel_snapshot '.sendViewState == "closed"' >/dev/null
done

fund_send_fixture 100
open_send_flow 60
curl -fsS -X POST -H 'Content-Type: application/json' \
  --data '{"sendCreateEmptyId":true}' "$base_url/__test__/mode" >/dev/null
panel_action prepareSend >/dev/null
wait_panel_snapshot '
  .sendViewState == "error"
  and .sendErrorCode == "invalid_response"
  and .activeTransferCount == 0
' >/dev/null
panel_action cancelSend >/dev/null
wait_panel_snapshot '.sendViewState == "closed"' >/dev/null

for send_command_error in operation_not_found operation_conflict; do
  fund_send_fixture 100
  prepare_send_flow 60
  curl -fsS -X POST -H 'Content-Type: application/json' \
    --data "$(jq -cn --arg code "$send_command_error" '{sendCommandError:$code}')" \
    "$base_url/__test__/mode" >/dev/null
  panel_action confirmSend >/dev/null
  wait_panel_snapshot ".sendViewState == \"error\"
    and .sendErrorCode == \"$send_command_error\"
    and .sendError != \"\"" >/dev/null
  send_error_cancel=$(panel_action cancelSend || true)
  [[ $send_error_cancel == "ok" ]] \
    || fail "$send_command_error dismissal returned ${send_error_cancel:-<empty>}"
  if [[ $send_command_error == operation_conflict ]]; then
    wait_panel_snapshot '.sendViewState == "entry" and .reservedBalance == "0"' >/dev/null
    panel_action cancelSend >/dev/null
  fi
  wait_panel_snapshot '.sendViewState == "closed"' >/dev/null
done

lossless_send_amount='90071992547409931234567890'
fund_send_fixture "$lossless_send_amount"
open_send_flow "$lossless_send_amount"
wait_panel_snapshot ".sendAmount == \"$lossless_send_amount\"
  and .sendAmountValid == true
  and .sendSelectedMint == \"https://mint.one\"" >/dev/null
panel_action prepareSend >/dev/null
wait_panel_snapshot ".sendViewState == \"review\"
  and .sendReviewAmount == \"$lossless_send_amount\"
  and .sendReviewFee == \"0\"
  and .sendReviewInputAmount == \"$lossless_send_amount\"
  and .sendReviewNeedsSwap == false" >/dev/null
panel_action cancelSend >/dev/null
wait_panel_snapshot ".sendViewState == \"entry\"
  and .spendableBalance == \"$lossless_send_amount\"
  and .reservedBalance == \"0\"" >/dev/null
panel_action cancelSend >/dev/null
wait_panel_snapshot '.sendViewState == "closed"' >/dev/null

echo "runtime: stale balances, structured Send errors, and lossless decimal strings passed"

fund_send_fixture 100
prepare_send_flow 60
before_dropped_send=$(curl -fsS "$base_url/__test__/status")
before_dropped_send_creates=$(jq -r '.sendCreateRequests' <<<"$before_dropped_send")
before_dropped_send_executes=$(jq -r '.sendExecuteRequests' <<<"$before_dropped_send")
curl -fsS -X POST -H 'Content-Type: application/json' \
  --data '{"sendExecuteInterruption":"after_commit"}' \
  "$base_url/__test__/mode" >/dev/null
panel_action confirmSend >/dev/null
wait_mock_status ".sendExecuteRequests == $((before_dropped_send_executes + 1))" >/dev/null
wait_panel_snapshot '.sendViewState == "error"
  and .sendErrorCode == "transport_unavailable"' >/dev/null
adapter_call reconnect >/dev/null
wait_panel_snapshot '.sendViewState == "result"
  and .sendCopyAvailable == true
  and .spendableBalance == "30"
  and .reservedBalance == "70"
  and .activeTransferCount == 1
  and .activeTransferStateLabel == "Pending Send"' >/dev/null
wait_mock_status ".sendCreateRequests == $before_dropped_send_creates
  and .sendExecuteRequests == $((before_dropped_send_executes + 1))
  and .sendResultRequests >= 1" >/dev/null
panel_action doneSend >/dev/null
wait_panel_snapshot '.sendViewState == "closed"' >/dev/null
panel_action closePanel >/dev/null

kill "$shell_pid"
wait "$shell_pid" 2>/dev/null || true
shell_pid=""
COCOD_STATE_DIR="$state_dir" OMARCHY_CASHU_DAEMON_URL="$base_url" \
  quickshell --no-color -p "$shell_qml" >>"$shell_log" 2>&1 &
shell_pid=$!
wait_snapshot '.connectionState == "connected"
  and .activeTransfers[0].state == "pending"
  and .spendableBalance == "30"
  and .reservedBalance == "70"' >/dev/null
panel_action openPanel >/dev/null
wait_panel_snapshot '.opened == true
  and .walletState == "unlocked"
  and .sendViewState == "closed"
  and .receiveViewState == "closed"' >/dev/null
curl -fsS -X POST -H 'Content-Type: application/json' \
  --data '{"sendResultUnavailableResponses":1}' \
  "$base_url/__test__/mode" >/dev/null
[[ $(panel_action openSend) == "ok" ]] \
  || fail "fresh Send entry did not open beside a reloaded Pending Send"
wait_panel_snapshot '.sendViewState == "entry" and .sendAmount == ""
  and .activeTransferStateLabel == "Pending Send"' >/dev/null
panel_action cancelSend >/dev/null
reloaded_pending_id=$(curl -fsS -H "Authorization: Bearer $credential" \
  "$base_url/v1/operations/send/in-flight" | jq -er '.items[0].id')
panel_action openActiveSends >/dev/null
panel_action selectActiveSend "$reloaded_pending_id" >/dev/null
[[ $(panel_action copyActivePendingSend) == "ok" ]] \
  || fail "exact reloaded Pending Send result could not be requested"
wait_panel_snapshot '.activePendingActionState == "error"
  and .activePendingErrorCode == "result_not_available"
  and .activePendingError != ""
  and .activePendingCopyAvailable == true' >/dev/null
[[ $(panel_action copyActivePendingSend) == "ok" ]] \
  || fail "retryable exact Pending Send result could not be requested again"
wait_panel_snapshot '.activePendingActionState == "idle"' >/dev/null
wait_mock_status ".sendCreateRequests == $before_dropped_send_creates
  and .sendExecuteRequests == $((before_dropped_send_executes + 1))
  and .sendResultRequests >= 3" >/dev/null
[[ $(panel_action beginActivePendingReclaim) == "ok" ]] \
  || fail "Pending Send did not offer Reclaim"
wait_panel_snapshot '.activePendingReclaimWarningVisible == true
  and (.activePendingReclaimWarning | test("race"; "i"))' >/dev/null
[[ $(panel_action confirmActivePendingReclaim) == "ok" ]] \
  || fail "warned Pending Send Reclaim could not begin"
wait_panel_snapshot '.activePendingTerminalState == "reclaimed"
  and .spendableBalance == "100"
  and .reservedBalance == "0"
  and .activeTransferCount == 0' >/dev/null
panel_action backActiveSends >/dev/null
panel_action backActiveSends >/dev/null
panel_action closePanel >/dev/null

echo "runtime: dropped Send recovery, reload, explicit result, and warned Reclaim passed"

fund_send_fixture 100
invalidated_send=$(jq -cn '{mintUrl:"https://mint.one",unit:"sat",amount:"60"}' \
  | curl -fsS -H "Authorization: Bearer $credential" -X POST \
      -H 'Content-Type: application/json' --data-binary @- \
      "$base_url/v1/operations/send")
invalidated_send_id=$(jq -er '.id' <<<"$invalidated_send")
invalidated_send_execution=$(curl -fsS -H "Authorization: Bearer $credential" -X POST \
  "$base_url/v1/operations/send/$invalidated_send_id/execute")
invalidated_send_token=$(jq -er '.result.token' <<<"$invalidated_send_execution")
adapter_call reconnect >/dev/null
wait_snapshot ".activeTransfers[0].id == \"$invalidated_send_id\"
  and .activeTransfers[0].state == \"pending\"
  and .spendableBalance == \"30\"
  and .reservedBalance == \"70\"" >/dev/null
before_send_invalidation=$(curl -fsS "$base_url/__test__/status")
before_send_lookup=$(jq -r '.sendLookupRequests' <<<"$before_send_invalidation")
before_send_refresh=$(jq -r '.sendRefreshRequests' <<<"$before_send_invalidation")
before_send_balance=$(jq -r '.resourceRequests.balances' <<<"$before_send_invalidation")
before_send_invalidation_creates=$(jq -r '.sendCreateRequests' <<<"$before_send_invalidation")
before_send_invalidation_executes=$(jq -r '.sendExecuteRequests' <<<"$before_send_invalidation")
for _duplicate in 1 2; do
  jq -cn --arg id "$invalidated_send_id" '{event:{
    type:"operation.updated",timestamp:"2026-08-20T12:08:00.000Z",
    data:{operationType:"send",operationId:$id,mintUrl:"https://mint.one"}
  }}' | curl -fsS -X POST -H 'Content-Type: application/json' --data-binary @- \
    "$base_url/__test__/resources" >/dev/null
done
wait_mock_status ".sendLookupRequests > $before_send_lookup
  and .sendRefreshRequests > $before_send_refresh
  and .resourceRequests.balances > $before_send_balance
  and .sendCreateRequests == $before_send_invalidation_creates
  and .sendExecuteRequests == $before_send_invalidation_executes" >/dev/null
after_operation_invalidation=$(curl -fsS "$base_url/__test__/status")
after_operation_lookup=$(jq -r '.sendLookupRequests' <<<"$after_operation_invalidation")
after_operation_refresh=$(jq -r '.sendRefreshRequests' <<<"$after_operation_invalidation")
jq -cn '{event:{
  type:"balance.updated",timestamp:"2026-08-20T12:08:01.000Z",
  data:{mintUrl:"https://mint.one"}
}}' | curl -fsS -X POST -H 'Content-Type: application/json' --data-binary @- \
  "$base_url/__test__/resources" >/dev/null
wait_mock_status ".sendLookupRequests > $after_operation_lookup
  and .sendRefreshRequests > $after_operation_refresh" >/dev/null
curl -fsS -X POST -H 'Content-Type: application/json' \
  --data "$(jq -cn --arg id "$invalidated_send_id" \
    '{operationId:$id,suppressEvents:true}')" \
  "$base_url/__test__/redeem-send" >/dev/null \
  || fail "recipient redemption fixture failed"
sleep 0.3
wait_snapshot ".activeTransfers | any(.id == \"$invalidated_send_id\")" >/dev/null
panel_action openPanel >/dev/null
wait_snapshot "(.activeTransfers | all(.id != \"$invalidated_send_id\"))
  and .spendableBalance == \"30\"
  and .reservedBalance == \"0\"" >/dev/null
panel_action closePanel >/dev/null
if rg -Fq "$invalidated_send_token" \
    <<<"$(adapter_call snapshot)$(panel_call)$(curl -fsS "$base_url/__test__/status")" \
    || rg -Fq "$invalidated_send_token" "$shell_log" "$mock_log"; then
  fail "redeemed Pending Send token escaped its explicit result resource"
fi

echo "runtime: duplicate and missed Send invalidations reconcile canonically"

fund_send_fixture 100
prepare_send_flow 60
panel_action confirmSend >/dev/null
wait_panel_snapshot '.sendViewState == "result" and .sendCopyAvailable == true
  and .activeTransferStateLabel == "Pending Send"
  and .sendReclaimAvailable == true
  and .sendOperationId != ""' >/dev/null
curl -fsS -X POST -H 'Content-Type: application/json' \
  --data '{"sendReclaimOutcome":"reclaim_inconclusive"}' \
  "$base_url/__test__/mode" >/dev/null
panel_action beginReclaimSend >/dev/null
wait_panel_snapshot '.sendViewState == "reclaim-warning"' >/dev/null
panel_action confirmReclaimSend >/dev/null
wait_panel_snapshot '.sendViewState == "error"
  and .sendErrorCode == "coco_error"
  and .sendError != ""
  and .sendCopyAvailable == false
  and .activeTransferStateLabel == "Pending Send"
  and .spendableBalance == "30"
  and .reservedBalance == "70"' >/dev/null
panel_action retrySend >/dev/null
wait_panel_snapshot '.sendViewState == "result" and .sendCopyAvailable == true
  and .activeTransferStateLabel == "Pending Send"
  and .sendReclaimAvailable == true' >/dev/null
panel_action beginReclaimSend >/dev/null
wait_panel_snapshot '.sendViewState == "reclaim-warning"' >/dev/null
recipient_race_id=$(curl -fsS -H "Authorization: Bearer $credential" \
  "$base_url/v1/operations/send/in-flight" | jq -er '.items[0].id')
curl -fsS -X POST -H 'Content-Type: application/json' \
  --data "$(jq -cn --arg id "$recipient_race_id" \
    '{operationId:$id,suppressEvents:true}')" \
  "$base_url/__test__/redeem-send" >/dev/null \
  || fail "concurrent recipient redemption fixture failed"
panel_action confirmReclaimSend >/dev/null
wait_panel_snapshot '.sendViewState == "error"
  and .sendErrorCode == "operation_not_found"
  and .sendError != ""
  and .sendCopyAvailable == false
  and .activeTransferCount == 0
  and .spendableBalance == "30"
  and .reservedBalance == "0"' >/dev/null
panel_action cancelSend >/dev/null
wait_panel_snapshot '.sendViewState == "closed"' >/dev/null

fund_send_fixture 100
prepare_send_flow 60
panel_action confirmSend >/dev/null
wait_panel_snapshot '.sendViewState == "result" and .sendCopyAvailable == true
  and .activeTransferStateLabel == "Pending Send"
  and .sendReclaimAvailable == true' >/dev/null
pending_unavailable_id=$(curl -fsS -H "Authorization: Bearer $credential" \
  "$base_url/v1/operations/send/in-flight" | jq -er '.items[0].id')
curl -fsS -X POST -H 'Content-Type: application/json' \
  --data '{"sendRefreshError":"mint_unavailable"}' \
  "$base_url/__test__/mode" >/dev/null
jq -cn --arg id "$pending_unavailable_id" '{event:{
  type:"operation.updated",timestamp:"2026-08-20T12:09:00.000Z",
  data:{operationType:"send",operationId:$id,mintUrl:"https://mint.one"}
}}' | curl -fsS -X POST -H 'Content-Type: application/json' --data-binary @- \
  "$base_url/__test__/resources" >/dev/null
wait_panel_snapshot '.sendViewState == "error"
  and .sendErrorCode == "coco_error"
  and .sendCopyAvailable == false
  and .activeTransferStateLabel == "Pending Send"
  and .spendableBalance == "30"
  and .reservedBalance == "70"' >/dev/null
panel_action retrySend >/dev/null
wait_panel_snapshot '.sendViewState == "result" and .sendCopyAvailable == true' >/dev/null
panel_action beginReclaimSend >/dev/null
wait_panel_snapshot '.sendViewState == "reclaim-warning"' >/dev/null
panel_action confirmReclaimSend >/dev/null
wait_panel_snapshot '.sendViewState == "reclaimed"
  and .spendableBalance == "100" and .reservedBalance == "0"' >/dev/null
panel_action doneSend >/dev/null
panel_action closePanel >/dev/null

for reclaim_error in operation_conflict operation_not_found; do
  fund_send_fixture 100
  prepare_send_flow 60
  panel_action confirmSend >/dev/null
  wait_panel_snapshot '.sendViewState == "result" and .sendCopyAvailable == true
    and .activeTransferStateLabel == "Pending Send"
    and .sendReclaimAvailable == true' >/dev/null
  curl -fsS -X POST -H 'Content-Type: application/json' \
    --data "$(jq -cn --arg outcome "$reclaim_error" \
      '{sendReclaimOutcome:$outcome}')" \
    "$base_url/__test__/mode" >/dev/null
  panel_action beginReclaimSend >/dev/null
  wait_panel_snapshot '.sendViewState == "reclaim-warning"' >/dev/null
  panel_action confirmReclaimSend >/dev/null
  wait_panel_snapshot ".sendViewState == \"error\"
    and .sendErrorCode == \"$reclaim_error\"
    and .sendError != \"\"" >/dev/null
  if [[ $reclaim_error == operation_conflict ]]; then
    wait_panel_snapshot '.activeTransferStateLabel == "Pending Send"
      and .spendableBalance == "30" and .reservedBalance == "70"' >/dev/null
    panel_action retrySend >/dev/null
    wait_panel_snapshot '.sendViewState == "result"' >/dev/null
    panel_action beginReclaimSend >/dev/null
    wait_panel_snapshot '.sendViewState == "reclaim-warning"' >/dev/null
    panel_action confirmReclaimSend >/dev/null
    wait_panel_snapshot '.sendViewState == "reclaimed"' >/dev/null
    panel_action doneSend >/dev/null
  else
    wait_panel_snapshot '.activeTransferCount == 0
      and .spendableBalance == "100" and .reservedBalance == "0"' >/dev/null
    panel_action cancelSend >/dev/null
  fi
  wait_panel_snapshot '.sendViewState == "closed"' >/dev/null
  panel_action closePanel >/dev/null
done

echo "runtime: Pending Send Reclaim outcomes and recoverable errors passed"

kill "$shell_pid"
wait "$shell_pid" 2>/dev/null || true
shell_pid=""
COCOD_STATE_DIR="$state_dir" OMARCHY_CASHU_DAEMON_URL="$base_url" \
  quickshell --no-color -p "$shell_qml" >>"$shell_log" 2>&1 &
shell_pid=$!
wait_snapshot '.connectionState == "connected"
  and .canonicalRefreshInProgress == false' >/dev/null

before_balance=$(curl -fsS "$base_url/__test__/status")
before_status_requests=$(jq -r '.resourceRequests.status' <<<"$before_balance")
before_balance_requests=$(jq -r '.resourceRequests.balances' <<<"$before_balance")
before_mint_requests=$(jq -r '.resourceRequests.mints' <<<"$before_balance")
curl -fsS -X POST -H 'Content-Type: application/json' \
  --data '{
    "balances":{"items":[
      {"mintUrl":"https://mint.one","unit":"sat","spendable":"90071992547409931234567890","reserved":"7","total":"90071992547409931234567897"},
      {"mintUrl":"https://mint.two","unit":"sat","spendable":"10","reserved":"3","total":"13"}
    ]},
    "event":{"type":"balance.updated","timestamp":"2026-08-20T12:01:00.000Z","data":{"mintUrl":"https://mint.one"}},
    "delivery":"partial"
  }' "$base_url/__test__/resources" >/dev/null
wait_snapshot '
  .spendableBalance == "90071992547409931234567900"
  and .reservedBalance == "10"
  and .unit == "sat"
  and .heartbeatCount > 0
' >/dev/null
wait_panel_snapshot '
  .spendableBalance == "90071992547409931234567900"
  and .reservedBalance == "10"
  and (.spendableText | gsub("[^0-9]"; "")) == "90071992547409931234567900"
' >/dev/null
wait_mock_status \
  ".resourceRequests.balances > $before_balance_requests
   and .resourceRequests.status == $before_status_requests
   and .resourceRequests.mints == $before_mint_requests" >/dev/null

before_operation=$(curl -fsS "$base_url/__test__/status")
before_send_lookup=$(jq -r '.sendLookupRequests' <<<"$before_operation")
before_send_refresh=$(jq -r '.sendRefreshRequests' <<<"$before_operation")
before_send_balance=$(jq -r '.resourceRequests.balances' <<<"$before_operation")
before_receive_prepared=$(jq -r '.resourceRequests.receivePrepared' <<<"$before_operation")
canonical_invalidation_send=$(jq -cn \
  '{mintUrl:"https://mint.one",unit:"sat",amount:"60"}' \
  | curl -fsS -H "Authorization: Bearer $credential" -X POST \
      -H 'Content-Type: application/json' --data-binary @- \
      "$base_url/v1/operations/send")
canonical_invalidation_send_id=$(jq -er '.id' <<<"$canonical_invalidation_send")
wait_snapshot "
  (.activeTransfers | length) == 1
  and .activeTransfers[0].id == \"$canonical_invalidation_send_id\"
  and .activeTransfers[0].amount == \"60\"
  and .barActive == true
" >/dev/null
wait_mock_status \
  ".sendLookupRequests > $before_send_lookup
   and .sendRefreshRequests > $before_send_refresh
   and .resourceRequests.balances > $before_send_balance
   and .resourceRequests.receivePrepared == $before_receive_prepared" >/dev/null
curl -fsS -H "Authorization: Bearer $credential" -X POST \
  "$base_url/v1/operations/send/$canonical_invalidation_send_id/cancel" >/dev/null
wait_snapshot ".activeTransfers | all(.id != \"$canonical_invalidation_send_id\")" \
  >/dev/null

before_mint=$(curl -fsS "$base_url/__test__/status")
before_mint_requests=$(jq -r '.resourceRequests.mints' <<<"$before_mint")
curl -fsS -X POST -H 'Content-Type: application/json' \
  --data '{
    "mints":{"items":[{"mintUrl":"https://mint.one","name":"Mint One","trusted":true,"createdAt":"2026-08-20T12:00:00.000Z","updatedAt":"2026-08-20T12:00:00.000Z"}]},
    "event":{"type":"mint.updated","timestamp":"2026-08-20T12:01:02.000Z","data":{"mintUrl":"https://mint.one"}}
  }' "$base_url/__test__/resources" >/dev/null
wait_snapshot '.trustedMintCount == 1' >/dev/null
wait_mock_status ".resourceRequests.mints > $before_mint_requests" >/dev/null

before_parse_failure=$(curl -fsS "$base_url/__test__/status")
before_parse_status=$(jq -r '.resourceRequests.status' <<<"$before_parse_failure")
before_parse_balances=$(jq -r '.resourceRequests.balances' <<<"$before_parse_failure")
curl -fsS -X POST -H 'Content-Type: application/json' \
  --data '{"rawEvent":"{not-json","delivery":"partial"}' \
  "$base_url/__test__/resources" >/dev/null
wait_mock_status \
  ".resourceRequests.status > $before_parse_status
   and .resourceRequests.balances > $before_parse_balances" >/dev/null
wait_snapshot '.connectionState == "connected" and .lastErrorCode == ""' >/dev/null

locked_status='{"daemon":{"version":"0.0.17","interfaceVersion":"1"},"wallet":{"configuredAt":"2026-08-20T12:00:00.000Z"},"seedAccess":{"state":"locked","requiresPassphrase":true},"cocoSession":{"state":"stopped","startedAt":null,"lastFailure":null}}'
curl -fsS -X POST -H 'Content-Type: application/json' \
  --data "{\"status\":$locked_status}" "$base_url/__test__/resources" >/dev/null
adapter_call reconnect >/dev/null
wait_snapshot '
  .walletState == "locked"
  and .walletStateLabel == "Locked"
  and .barAttention == true
' >/dev/null

running_status='{"daemon":{"version":"0.0.17","interfaceVersion":"1"},"wallet":{"configuredAt":"2026-08-20T12:00:00.000Z"},"seedAccess":{"state":"available","requiresPassphrase":false},"cocoSession":{"state":"running","startedAt":"2026-08-20T12:00:00.000Z","lastFailure":null}}'
curl -fsS -X POST -H 'Content-Type: application/json' \
  --data "{\"status\":$running_status}" "$base_url/__test__/resources" >/dev/null
adapter_call reconnect >/dev/null
wait_snapshot '.walletState == "unlocked" and .connectionState == "connected"' >/dev/null

rotation_receive=$(prepare_receive_fixture "$rotation_recovery_token") \
  || fail "rotation recovery fixture preparation failed"
rotation_receive_id=$(jq -er '.id' <<<"$rotation_receive")
wait_snapshot ".activeTransfers | any(.id == \"$rotation_receive_id\")" >/dev/null
before_rotation=$(curl -fsS "$base_url/__test__/status")
before_rotation_status=$(jq -r '.resourceRequests.status' <<<"$before_rotation")
before_rotation_balances=$(jq -r '.resourceRequests.balances' <<<"$before_rotation")
before_rotation_receive_prepared=$(jq -r '.resourceRequests.receivePrepared' <<<"$before_rotation")
before_rotation_receive_in_flight=$(jq -r '.resourceRequests.receiveInFlight' <<<"$before_rotation")
before_rotation_receive_lookups=$(jq -r '.receiveLookupRequests' <<<"$before_rotation")
before_rotation_receive_creates=$(jq -r '.receiveCreateRequests' <<<"$before_rotation")
before_rotation_receive_executes=$(jq -r '.receiveExecuteRequests' <<<"$before_rotation")
before_rotation_count=$(adapter_call snapshot | jq -r '.rotationCount')
adapter_call rotate >/dev/null
wait_snapshot ".connectionState == \"connected\"
  and .rotationCount == $((before_rotation_count + 1))
  and .canonicalRefreshInProgress == false" >/dev/null
wait_mock_status \
  ".resourceRequests.status > $before_rotation_status
   and .resourceRequests.balances > $before_rotation_balances
   and .resourceRequests.receivePrepared > $before_rotation_receive_prepared
   and .resourceRequests.receiveInFlight > $before_rotation_receive_in_flight
   and .receiveLookupRequests > $before_rotation_receive_lookups
   and .receiveCreateRequests == $before_rotation_receive_creates
   and .receiveExecuteRequests == $before_rotation_receive_executes
   and .streamConnections >= 1
  " >/dev/null

before_reconnect=$(curl -fsS "$base_url/__test__/status")
before_reconnect_status=$(jq -r '.resourceRequests.status' <<<"$before_reconnect")
before_reconnect_balances=$(jq -r '.resourceRequests.balances' <<<"$before_reconnect")
before_reconnect_receive_prepared=$(jq -r '.resourceRequests.receivePrepared' <<<"$before_reconnect")
before_reconnect_receive_in_flight=$(jq -r '.resourceRequests.receiveInFlight' <<<"$before_reconnect")
before_reconnect_receive_lookups=$(jq -r '.receiveLookupRequests' <<<"$before_reconnect")
before_reconnect_receive_creates=$(jq -r '.receiveCreateRequests' <<<"$before_reconnect")
before_reconnect_receive_executes=$(jq -r '.receiveExecuteRequests' <<<"$before_reconnect")
curl -fsS -X POST -H 'Content-Type: application/json' --data '{}' \
  "$base_url/__test__/disconnect" >/dev/null
wait_snapshot '.connectionState == "unavailable" and .retryAttempt >= 1' >/dev/null
wait_snapshot '.connectionState == "connected"
  and .reconnectCount >= 1
  and .canonicalRefreshInProgress == false' >/dev/null
wait_mock_status \
  ".resourceRequests.status > $before_reconnect_status
   and .resourceRequests.balances > $before_reconnect_balances
   and .resourceRequests.receivePrepared > $before_reconnect_receive_prepared
   and .resourceRequests.receiveInFlight > $before_reconnect_receive_in_flight
   and .receiveLookupRequests > $before_reconnect_receive_lookups
   and .receiveCreateRequests == $before_reconnect_receive_creates
   and .receiveExecuteRequests == $before_reconnect_receive_executes
   and .streamConnections >= 1
  " >/dev/null

before_rotation_cleanup_lookup=$(curl -fsS "$base_url/__test__/status" \
  | jq -r '.receiveLookupRequests')
curl -fsS -H "Authorization: Bearer $credential" -X POST \
  "$base_url/v1/operations/receive/$rotation_receive_id/cancel" >/dev/null \
  || fail "rotation recovery fixture cleanup failed"
jq -cn --arg id "$rotation_receive_id" '{
  event:{
    type:"operation.updated",timestamp:"2026-08-20T12:07:00.000Z",
    data:{operationType:"receive",operationId:$id,mintUrl:"https://mint.one"}
  }
}' | curl -fsS -X POST -H 'Content-Type: application/json' --data-binary @- \
  "$base_url/__test__/resources" >/dev/null
wait_mock_status ".receiveLookupRequests > $before_rotation_cleanup_lookup" >/dev/null
wait_snapshot ".activeTransfers | all(.id != \"$rotation_receive_id\")" >/dev/null

curl -fsS -X POST -H 'Content-Type: application/json' \
  --data '{"resources":"unavailable"}' "$base_url/__test__/mode" >/dev/null
adapter_call reconnect >/dev/null
wait_snapshot '
  .connectionState == "unavailable"
  and .lastErrorCode == "internal_error"
  and .walletState == "unavailable"
' >/dev/null
curl -fsS -X POST -H 'Content-Type: application/json' \
  --data '{"resources":"ok"}' "$base_url/__test__/mode" >/dev/null
adapter_call reconnect >/dev/null
wait_snapshot '.connectionState == "connected" and .lastErrorCode == ""' >/dev/null

curl -fsS -X POST -H 'Content-Type: application/json' \
  --data '{"resources":"incompatible"}' "$base_url/__test__/mode" >/dev/null
adapter_call reconnect >/dev/null
wait_snapshot '
  .compatibilityState == "incompatible"
  and .walletState == "unavailable"
  and .setupTitle == "Incompatible cocod contract"
' >/dev/null
curl -fsS -X POST -H 'Content-Type: application/json' \
  --data '{"resources":"ok"}' "$base_url/__test__/mode" >/dev/null
adapter_call reconnect >/dev/null
wait_snapshot '.connectionState == "connected" and .compatibilityState == "compatible"' >/dev/null

final_adapter=$(adapter_call snapshot)
final_panel=$(panel_call)
final_mock=$(curl -fsS "$base_url/__test__/status")
if rg -Fq "$credential" <<<"$final_adapter$final_panel$final_mock" \
    || rg -q 'abandon|generatedMnemonic|mnemonic' <<<"$final_adapter$final_panel$final_mock"; then
  fail "Wallet Client state retained a transport credential or Recovery Phrase"
fi

kill "$shell_pid"
wait "$shell_pid" 2>/dev/null || true
shell_pid=""
COCOD_STATE_DIR="$missing_state_dir" OMARCHY_CASHU_DAEMON_URL="$base_url" \
  quickshell --no-color -p "$shell_qml" >"$shell_log" 2>&1 &
shell_pid=$!
wait_snapshot '
  .connectionState == "error"
  and .lastErrorCode == "credential_unavailable"
  and .retryAttempt == 0
' >/dev/null

kill "$shell_pid"
wait "$shell_pid" 2>/dev/null || true
shell_pid=""
COCOD_STATE_DIR="$state_dir" OMARCHY_CASHU_DAEMON_URL="http://example.com:38433" \
  quickshell --no-color -p "$shell_qml" >"$shell_log" 2>&1 &
shell_pid=$!
wait_snapshot '
  .daemonUrlAllowed == false
  and .connectionState == "error"
  and .walletState == "unavailable"
  and .retryAttempt == 0
' >/dev/null

echo "runtime: cocod v1 composition, lifecycle, decimals, invalidation, reconnect, rotation, and redaction passed"
