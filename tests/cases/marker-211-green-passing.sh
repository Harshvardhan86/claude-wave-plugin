#!/usr/bin/env bash
# tests/cases/marker-211-green-passing.sh — AC-211: the GREEN marker demands at
# least one passing test AND zero failing ones. `passing=42 failing=1` and
# `passing=0 failing=0` are both refused; the second is the case a suite that
# ran nothing at all would produce.
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
  stop_state "$st" ".active = {a1: $(stop_active TDE-GREEN reviewer opus)}" || return 1
  stop_case "$c" "$(printf '.seed.state = "%s" | %s' "$st" "$2")" || return 1
  run_hook subagent-stop.sh "$c" || { fail "step $1: run_hook: $WV_LAST_STDERR"; return 1; }
  return 0
}

if drive pass '.seed.files = {".wave/green.md": "GREEN-VERIFIED passing=42 failing=0\n"}'; then
  assert_allow || fail "42/0: want no block"
  [ "$(stop_phase_status TDE-GREEN)" = "done" ] || \
    fail "42/0: status is '$(stop_phase_status TDE-GREEN)', want done"
fi

if drive onefail '.seed.files = {".wave/green.md": "GREEN-VERIFIED passing=42 failing=1\n"}'; then
  assert_block W-MARKER || fail "42/1: want block(W-MARKER)"
  [ "$(stop_phase_status TDE-GREEN)" != "done" ] || fail "42/1: TDE-GREEN must not be done"
fi

if drive nothing '.seed.files = {".wave/green.md": "GREEN-VERIFIED passing=0 failing=0\n"}'; then
  assert_block W-MARKER || fail "0/0: want block(W-MARKER)"
  [ "$(stop_phase_status TDE-GREEN)" != "done" ] || fail "0/0: TDE-GREEN must not be done"
fi

exit $rc
