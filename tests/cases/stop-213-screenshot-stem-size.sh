#!/usr/bin/env bash
# tests/cases/stop-213-screenshot-stem-size.sh — AC-213: the screenshot marker
# requires a NON-EMPTY stem and a size greater than zero. `green-.png` satisfies
# a lazy `green-*.png` glob and must not satisfy this; a 0-byte `green-home.png`
# is what a screenshot tool leaves behind when it fails, and is the exact shape
# a check that only tests for existence would pass.
set -u

# shellcheck source=tests/lib/assert.sh
source "$(dirname "$0")/../lib/assert.sh"
# shellcheck source=tests/lib/stop.sh
source "$(dirname "$0")/../lib/stop.sh"

name="${WV_CASE_NAME:-$(basename "$0" .sh)}"
log="${WV_CASE_LOG:-$WV_RUN_TMP/logs/$name.log}"
rc=0
fail() { printf 'ASSERT FAIL: %s\n' "$*" >&2; rc=1; }
printf 'RAN subagent-stop.sh %s decision=multi\n' "$name" >> "$log"

drive() {
  WV_PROJECT=""
  local st="$WV_RUN_TMP/$name-$1-state.json" c="$WV_RUN_TMP/$name-$1.json"
  stop_state "$st" ".active = {a1: $(stop_active TDE-GREEN reviewer opus)} | .ui = true" || return 1
  stop_case "$c" "$(printf '.seed.state = "%s" | .seed.files = {".wave/green.md": "GREEN-VERIFIED passing=42 failing=0\\n"} | %s' "$st" "$2")" || return 1
  run_hook subagent-stop.sh "$c" || { fail "step $1: run_hook: $WV_LAST_STDERR"; return 1; }
  return 0
}

if drive emptystem '.seed.files[".wave/screenshots/green-.png"] = "PNGBYTES"'; then
  assert_block W-ARTIFACT || fail "green-.png: want block(W-ARTIFACT)"
  [ "$(stop_phase_status TDE-GREEN)" != "done" ] || fail "green-.png: TDE-GREEN must not be done"
fi

if drive zerobyte '.seed.files[".wave/screenshots/green-home.png"] = ""'; then
  assert_block W-ARTIFACT || fail "0-byte png: want block(W-ARTIFACT)"
  assert_reason_contains '0 bytes' || fail "0-byte png: the reason must name the zero size"
  [ "$(stop_phase_status TDE-GREEN)" != "done" ] || fail "0-byte png: TDE-GREEN must not be done"
fi

if drive nonempty '.seed.files[".wave/screenshots/green-home.png"] = "PNGBYTES"'; then
  assert_allow || fail "non-empty png: want no block"
  [ "$(stop_phase_status TDE-GREEN)" = "done" ] || \
    fail "non-empty png: status is '$(stop_phase_status TDE-GREEN)', want done"
fi

exit $rc
