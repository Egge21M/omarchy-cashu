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

mkdir -p "$state_dir/credentials/generation-1"
printf '%s\n' "$credential" >"$state_dir/credentials/generation-1/client"
chmod 700 "$state_dir" "$state_dir/credentials" "$state_dir/credentials/generation-1"
chmod 600 "$state_dir/credentials/generation-1/client"
ln -s generation-1 "$state_dir/credentials/current"

cp "$project_dir/Service.qml" "$runtime_dir/Service.qml"
cp "$project_dir/Panel.qml" "$runtime_dir/Panel.qml"
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
  and .resourceRequests.capabilities >= 1
  and .resourceRequests.status >= 1
  and .resourceRequests.balances == 0
' >/dev/null

curl -fsS -X POST -H 'Content-Type: application/json' \
  --data '{"resources":"ok","createDelayMs":250}' "$base_url/__test__/mode" >/dev/null
[[ $(panel_action createWallet) == "ok" ]] \
  || fail "explicit Create Wallet action was unavailable"
wait_snapshot '.creating == true and .walletState == "uninitialized"' >/dev/null
[[ $(panel_action createWallet) == "disabled" ]] \
  || fail "duplicate Create Wallet action remained available"
wait_mock_status '.createRequests == 1' >/dev/null

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
    "event":{"type":"balance.updated","timestamp":"2026-08-20T12:01:00Z","data":{"mintUrl":"https://mint.one"}},
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
before_send_prepared=$(jq -r '.resourceRequests.sendPrepared' <<<"$before_operation")
before_send_in_flight=$(jq -r '.resourceRequests.sendInFlight' <<<"$before_operation")
before_receive_prepared=$(jq -r '.resourceRequests.receivePrepared' <<<"$before_operation")
curl -fsS -X POST -H 'Content-Type: application/json' \
  --data '{
    "sendPrepared":{"items":[{"id":"send-1","type":"send","state":"prepared","mintUrl":"https://mint.one","unit":"sat","amount":"60","fee":"2","inputAmount":"70","needsSwap":true,"createdAt":"2026-08-20T12:00:00Z","updatedAt":"2026-08-20T12:00:00Z"}]},
    "event":{"type":"operation.updated","timestamp":"2026-08-20T12:01:01Z","data":{"operationType":"send","operationId":"send-1","mintUrl":"https://mint.one"}}
  }' "$base_url/__test__/resources" >/dev/null
wait_snapshot '
  (.activeTransfers | length) == 1
  and .activeTransfers[0].id == "send-1"
  and .activeTransfers[0].amount == "60"
  and .barActive == true
' >/dev/null
wait_mock_status \
  ".resourceRequests.sendPrepared > $before_send_prepared
   and .resourceRequests.sendInFlight > $before_send_in_flight
   and .resourceRequests.receivePrepared == $before_receive_prepared" >/dev/null

before_mint=$(curl -fsS "$base_url/__test__/status")
before_mint_requests=$(jq -r '.resourceRequests.mints' <<<"$before_mint")
curl -fsS -X POST -H 'Content-Type: application/json' \
  --data '{
    "mints":{"items":[{"mintUrl":"https://mint.one","name":"Mint One","trusted":true,"createdAt":"2026-08-20T12:00:00Z","updatedAt":"2026-08-20T12:00:00Z"}]},
    "event":{"type":"mint.updated","timestamp":"2026-08-20T12:01:02Z","data":{"mintUrl":"https://mint.one"}}
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

locked_status='{"daemon":{"version":"0.0.17","interfaceVersion":"1"},"wallet":{"configuredAt":"2026-08-20T12:00:00Z"},"seedAccess":{"state":"locked","requiresPassphrase":true},"cocoSession":{"state":"stopped","startedAt":null,"lastFailure":null}}'
curl -fsS -X POST -H 'Content-Type: application/json' \
  --data "{\"status\":$locked_status}" "$base_url/__test__/resources" >/dev/null
adapter_call reconnect >/dev/null
wait_snapshot '
  .walletState == "locked"
  and .walletStateLabel == "Locked"
  and .barAttention == true
' >/dev/null

running_status='{"daemon":{"version":"0.0.17","interfaceVersion":"1"},"wallet":{"configuredAt":"2026-08-20T12:00:00Z"},"seedAccess":{"state":"available","requiresPassphrase":false},"cocoSession":{"state":"running","startedAt":"2026-08-20T12:00:00Z","lastFailure":null}}'
curl -fsS -X POST -H 'Content-Type: application/json' \
  --data "{\"status\":$running_status}" "$base_url/__test__/resources" >/dev/null
adapter_call reconnect >/dev/null
wait_snapshot '.walletState == "unlocked" and .connectionState == "connected"' >/dev/null

before_rotation=$(curl -fsS "$base_url/__test__/status")
before_rotation_status=$(jq -r '.resourceRequests.status' <<<"$before_rotation")
before_rotation_balances=$(jq -r '.resourceRequests.balances' <<<"$before_rotation")
adapter_call rotate >/dev/null
wait_snapshot '.connectionState == "connected" and .rotationCount == 1' >/dev/null
wait_mock_status \
  ".resourceRequests.status > $before_rotation_status
   and .resourceRequests.balances > $before_rotation_balances
   and .streamConnections >= 1
  " >/dev/null

before_reconnect=$(curl -fsS "$base_url/__test__/status")
before_reconnect_status=$(jq -r '.resourceRequests.status' <<<"$before_reconnect")
before_reconnect_balances=$(jq -r '.resourceRequests.balances' <<<"$before_reconnect")
curl -fsS -X POST -H 'Content-Type: application/json' --data '{}' \
  "$base_url/__test__/disconnect" >/dev/null
wait_snapshot '.connectionState == "unavailable" and .retryAttempt >= 1' >/dev/null
wait_snapshot '.connectionState == "connected" and .reconnectCount >= 1' >/dev/null
wait_mock_status \
  ".resourceRequests.status > $before_reconnect_status
   and .resourceRequests.balances > $before_reconnect_balances
   and .streamConnections >= 1
  " >/dev/null

curl -fsS -X POST -H 'Content-Type: application/json' \
  --data '{"resources":"unavailable"}' "$base_url/__test__/mode" >/dev/null
adapter_call reconnect >/dev/null
wait_snapshot '
  .connectionState == "unavailable"
  and .lastErrorCode == "temporarily_unavailable"
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
