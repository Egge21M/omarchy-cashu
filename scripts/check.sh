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
' "$manifest" >/dev/null || fail "manifest contract does not match Slice 1"

if rg -n 'spendableBalance|reservedBalance' "$project_dir/BarWidget.qml"; then
  fail "the bar must not expose balances"
fi

if rg -n '(^|[^A-Za-z])(Process|FileView|Socket|WebSocket|NetworkAccessManager)[[:space:]]*\{' \
  "$project_dir"/*.qml; then
  fail "Slice 1 must not execute processes or perform network/filesystem IO"
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

for qml_file in "$project_dir"/*.qml; do
  qmlformat -n "$qml_file" >/dev/null \
    || fail "QML parser rejected ${qml_file##*/}"
  qmllint "$qml_file" \
    || fail "QML lint rejected ${qml_file##*/}"
done

echo "check: manifest, architecture guardrails, and QML syntax passed"
