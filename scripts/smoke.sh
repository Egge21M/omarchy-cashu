#!/usr/bin/env bash

set -euo pipefail

project_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
plugin_id=io.github.egge21m.omarchy-cashu
state_target="$plugin_id.state"

"$project_dir/scripts/check.sh"

if [[ ${1:-} != "--live" ]]; then
  echo "smoke: static checks passed (use --live after installing and enabling the plugin)"
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
  local expected_fixture_id=$1
  local expected_screen_name=$2
  local value=""
  for _attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    value=$(omarchy-shell shell call "$plugin_id" smokeSnapshot '' 2>/dev/null || true)
    if jq -e --arg fixture_id "$expected_fixture_id" --arg screen_name "$expected_screen_name" '
      .opened == true
      and .anchored == true
      and .requestedScreenName == $screen_name
      and .anchorScreenName == $screen_name
      and .fixtureId == $fixture_id
      and .revision == 1
      and .walletState == "unlocked"
    ' <<<"$value" >/dev/null 2>&1; then
      printf '%s\n' "$value"
      return 0
    fi
    sleep 0.1
  done
  fail "panel did not reach its expected anchored fixture state; last response: ${value:-<empty>}"
}

omarchy-shell shell ping | rg -qx 'ok' || fail "omarchy-shell is not healthy"

plugin_record=$(omarchy-shell shell listPlugins \
  | jq -c --arg id "$plugin_id" '.[] | select(.id == $id)')
[[ -n $plugin_record ]] || fail "plugin is not installed; copy it to ~/.config/omarchy/plugins/$plugin_id"
jq -e '.enabled == true and ((.kinds | sort) == (["bar-widget", "panel", "service"] | sort))' \
  <<<"$plugin_record" >/dev/null || fail "plugin is not enabled with all Slice 1 kinds"

service_snapshot=$(omarchy-shell "$state_target" snapshot)
jq -e '
  .fixtureId == "slice-1-wallet-state"
  and .revision == 1
  and .fixtureBacked == true
  and .walletState == "unlocked"
' <<<"$service_snapshot" >/dev/null || fail "shared fixture Wallet State is unavailable"

target_screen=$(hyprctl -j monitors | jq -er '.[0].name') \
  || fail "no active monitor is available for the panel anchor check"
panel_payload=$(jq -cn --arg screenName "$target_screen" '{screenName: $screenName}')

# The bar's left-click handler calls this exact shell toggle path.
omarchy-shell shell hide "$plugin_id"
wait_for false omarchy-shell "$state_target" panelOpen
trap 'omarchy-shell -q shell hide "$plugin_id"' EXIT
omarchy-shell shell toggle "$plugin_id" "$panel_payload"
wait_for true omarchy-shell "$state_target" panelOpen

panel_snapshot=$(wait_for_panel_snapshot \
  "$(jq -r .fixtureId <<<"$service_snapshot")" "$target_screen")

omarchy-shell shell toggle "$plugin_id" '{}'
wait_for false omarchy-shell "$state_target" panelOpen
trap - EXIT

echo "smoke: plugin loaded, shared state matched, and bar toggle contract opened and closed the panel"
