#!/usr/bin/env bash

set -euo pipefail

project_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
manifest="$project_dir/manifest.json"
validator=/usr/share/omarchy/bin/omarchy-plugin-validate
plugin_id=io.github.egge21m.omarchy-cashu

fail() {
  echo "check: $*" >&2
  exit 1
}

[[ -x $validator ]] || fail "Omarchy plugin validator not found: $validator"
"$validator" "$project_dir"

jq -e --arg id "$plugin_id" '
  .schemaVersion == 1
  and .id == $id
  and ((.kinds | sort) == (["bar-widget", "panel", "service"] | sort))
  and .entryPoints.barWidget == "BarWidget.qml"
  and .entryPoints.panel == "Panel.qml"
  and .entryPoints.service == "Service.qml"
' "$manifest" >/dev/null || fail "manifest contract does not match the Wallet Client"

if rg -n 'spendableBalance|reservedBalance' "$project_dir/BarWidget.qml"; then
  fail "the bar must not expose balances"
fi

if rg -n '(^|[^A-Za-z])(Process|FileView|Socket|WebSocket|NetworkAccessManager)[[:space:]]*\{' \
  "$project_dir/BarWidget.qml" "$project_dir/Panel.qml"; then
  fail "bar and panel must not execute processes or own filesystem/socket primitives"
fi

if rg -n '(^|[^A-Za-z])(Process|Socket|WebSocket|NetworkAccessManager)[[:space:]]*\{' \
  "$project_dir/Service.qml"; then
  fail "the Shell Adapter must use only XHR and its narrow credential file loader"
fi

[[ $(rg -c 'FileView[[:space:]]*\{' "$project_dir/Service.qml") == 1 ]] \
  || fail "Shell Adapter must own exactly one credential FileView"
rg -q 'id: credentialFile' "$project_dir/Service.qml" \
  || fail "Shell Adapter credential loader is missing"
rg -q 'path: root\.credentialPath' "$project_dir/Service.qml" \
  || fail "Shell Adapter credential loader reads an unexpected path"
rg -q 'blockAllReads: true' "$project_dir/Service.qml" \
  || fail "Shell Adapter credential reads are not synchronous and narrow"

if rg -n 'daemonBaseUrl|credential|XMLHttpRequest|text/event-stream|reconnectTimer' \
  "$project_dir/BarWidget.qml" "$project_dir/Panel.qml"; then
  fail "transport details escaped the Shell Adapter"
fi

rg -q 'new XMLHttpRequest' "$project_dir/Service.qml" \
  || fail "Shell Adapter does not own HTTP/SSE transport"
rg -q 'Authorization.*Bearer' "$project_dir/Service.qml" \
  || fail "Shell Adapter does not authenticate cocod requests"
rg -q '/credentials/current/client' "$project_dir/Service.qml" \
  || fail "Shell Adapter does not use cocod credential discovery"
rg -q '/v1/status' "$project_dir/Service.qml" \
  || fail "Shell Adapter does not fetch lifecycle status"
rg -q '/v1/balances' "$project_dir/Service.qml" \
  || fail "Shell Adapter does not fetch canonical balances"
rg -q '/v1/mints' "$project_dir/Service.qml" \
  || fail "Shell Adapter does not fetch Known Mints"
rg -q '/v1/operations/receive/prepared' "$project_dir/Service.qml" \
  || fail "Shell Adapter does not discover Receive Operations"
rg -q '/v1/operations/send/in-flight' "$project_dir/Service.qml" \
  || fail "Shell Adapter does not discover Send Operations"
rg -q 'isSafeInvalidation' "$project_dir/Service.qml" \
  || fail "Shell Adapter does not validate invalidation metadata"
rg -q 'isLoopbackBaseUrl' "$project_dir/Service.qml" \
  || fail "Shell Adapter does not restrict cocod transport to loopback"
rg -q 'http://127\.0\.0\.1:62626' "$project_dir/Service.qml" \
  || fail "Shell Adapter does not default to cocod port 62626"
rg -q 'default=62626' "$project_dir/scripts/mock-cocod.py" \
  || fail "mock cocod does not default to port 62626"
rg -q 'addDecimalStrings' "$project_dir/Service.qml" \
  || fail "Shell Adapter does not aggregate amounts losslessly"

if rg -n --glob '!scripts/check.sh' --glob '!docs/reference/**' \
  'Last-Event-ID|/v1/wallet/snapshot|/v1/wallet/create|/v1/wallet/recovery-phrase/reveal|/v1/receives/' \
  "$project_dir"; then
  fail "the provisional snapshot, command, or event-replay contract remains"
fi

if rg -n -- '--arg token' "$project_dir/tests/contract.sh" \
    || rg -n 'function (setClipboardText|setReceiveText)' \
      "$project_dir/tests/runtime-shell.qml"; then
  fail "Receive bearer tokens must not travel through process arguments or diagnostics IPC"
fi

if rg -n 'Number\([^)]*(amount|balance|spendable|reserved)' \
  "$project_dir/Service.qml" "$project_dir/Panel.qml"; then
  fail "wallet amounts must never be coerced to JavaScript Number"
fi
rg -q 'barStateLabel' "$project_dir/BarWidget.qml" \
  || fail "bar does not separate setup status from Wallet State"
rg -q 'balancesAvailable' "$project_dir/Panel.qml" \
  || fail "panel does not distinguish unavailable balances"
if rg -n --glob '!scripts/check.sh' 'QML_XHR_DUMP' "$project_dir"; then
  fail "QML_XHR_DUMP can expose Wallet material"
fi

if rg -n -i '\b(restore|passphrase|unlock|reset|delete|clipboard|copy)\b' \
  "$project_dir/Panel.qml"; then
  fail "panel exposes a deferred, destructive, or Recovery Phrase clipboard control"
fi

rg -q 'serviceFor\(root\.moduleName\)' "$project_dir/BarWidget.qml" \
  || fail "bar widget does not read the shared service"
rg -q 'property var service: null' "$project_dir/Panel.qml" \
  || fail "panel does not accept the shared service injection"
rg -q 'onPressed: function\(buttonCode\)' "$project_dir/BarWidget.qml" \
  || fail "bar widget has no press handler"
rg -q 'root\.togglePanel\(\)' "$project_dir/BarWidget.qml" \
  || fail "bar press does not route to the panel toggle"
rg -q 'screenName: screenName' "$project_dir/BarWidget.qml" \
  || fail "bar toggle does not preserve the initiating screen"
rg -q 'moduleWidgets\(pluginId\)' "$project_dir/Panel.qml" \
  || fail "panel does not resolve its initiating bar widget"
rg -q 'button\.triggerPress\(Qt\.LeftButton\)' "$project_dir/BarWidget.qml" \
  || fail "bar smoke path does not exercise the WidgetButton press handler"

python3 "$project_dir/scripts/mock-cocod.py" --help >/dev/null \
  || fail "mock cocod is not executable Python"

for qml_file in "$project_dir"/*.qml; do
  qmlformat -n "$qml_file" >/dev/null \
    || fail "QML parser rejected ${qml_file##*/}"
  qmllint "$qml_file" \
    || fail "QML lint rejected ${qml_file##*/}"
done

echo "check: manifest, adapter seam, security guardrails, and QML syntax passed"
