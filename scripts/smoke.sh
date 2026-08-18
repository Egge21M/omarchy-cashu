#!/usr/bin/env bash

set -euo pipefail

project_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
plugin_id=io.github.egge21m.omarchy-cashu
state_target="$plugin_id.state"

"$project_dir/scripts/check.sh"
"$project_dir/tests/contract.sh"
"$project_dir/tests/runtime.sh"

if [[ ${1:-} != "--live" ]]; then
  echo "smoke: contract and supported-runtime checks passed (use --live after installing and enabling the plugin)"
  exit 0
fi

fail() {
  echo "smoke: $*" >&2
  exit 1
}

wait_for() {
  local expected=$1
  shift
  local value=""
  for _attempt in 1 2 3 4 5 6 7 8 9 10; do
    value=$("$@" 2>/dev/null || true)
    [[ $value == "$expected" ]] && return 0
    sleep 0.1
  done
  fail "expected '$expected', got '${value:-<empty>}' from: $*"
}

wait_for_panel_snapshot() {
  local expected_revision=$1
  local expected_screen_name=$2
  local value=""
  for _attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    value=$(omarchy-shell shell call "$plugin_id" smokeSnapshot '' 2>/dev/null || true)
    if jq -e --argjson revision "$expected_revision" --arg screen_name "$expected_screen_name" '
      .opened == true
      and .anchored == true
      and .requestedScreenName == $screen_name
      and .anchorScreenName == $screen_name
      and .revision == $revision
      and .walletState == "unlocked"
      and .connectionState == "connected"
      and .compatibilityState == "compatible"
    ' <<<"$value" >/dev/null 2>&1; then
      printf '%s\n' "$value"
      return 0
    fi
    sleep 0.1
  done
  fail "panel did not reach its expected anchored live state; last response: ${value:-<empty>}"
}

omarchy-shell shell ping | rg -qx 'ok' || fail "omarchy-shell is not healthy"

plugin_record=$(omarchy-shell shell listPlugins \
  | jq -c --arg id "$plugin_id" '.[] | select(.id == $id)')
[[ -n $plugin_record ]] || fail "plugin is not installed; copy it to ~/.config/omarchy/plugins/$plugin_id"
jq -e '.enabled == true and ((.kinds | sort) == (["bar-widget", "panel", "service"] | sort))' \
  <<<"$plugin_record" >/dev/null || fail "plugin is not enabled with all Slice 1 kinds"

service_snapshot=$(omarchy-shell "$state_target" snapshot)
jq -e '
  .apiVersion == "1"
  and .revision >= 1
  and .fixtureBacked == false
  and .walletState == "unlocked"
  and .connectionState == "connected"
  and .compatibilityState == "compatible"
' <<<"$service_snapshot" >/dev/null || fail "shared live Wallet State is unavailable; is mock cocod running on 127.0.0.1:38421?"

target_screen=$(hyprctl -j monitors | jq -er '.[0].name') \
  || fail "no active monitor is available for the panel anchor check"

omarchy-shell shell hide "$plugin_id"
wait_for false omarchy-shell "$state_target" panelOpen
trap 'omarchy-shell -q shell hide "$plugin_id"' EXIT

# Enter through WidgetButton.triggerPress so the bar handler creates and sends
# the real initiating-screen payload.
clicked_screen=$(omarchy-shell "$state_target" clickBar "$target_screen")
[[ $clicked_screen == "$target_screen" ]] \
  || fail "bar click did not target the initiating screen: ${clicked_screen:-<empty>}"
wait_for true omarchy-shell "$state_target" panelOpen

panel_snapshot=$(wait_for_panel_snapshot \
  "$(jq -r .revision <<<"$service_snapshot")" "$target_screen")

omarchy-shell "$state_target" clickBar "$target_screen" >/dev/null
wait_for false omarchy-shell "$state_target" panelOpen
trap - EXIT

echo "smoke: plugin loaded, live shared state matched, and the bar handler opened and closed the anchored panel"
