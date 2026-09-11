#!/usr/bin/env bash
# tests/cases/marker-209-red-failing.sh — AC-209: `RED-VERIFIED failing=7` is a
# RED phase; `RED-VERIFIED failing=0` is not. This is the anti-false-green case
# — a RED phase that reports zero failing tests has not proved anything, and the
# marker `^RED-VERIFIED failing=[1-9][0-9]*$` is what refuses it.
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
  stop_state "$st" ".active = {a1: $(stop_active TDE-RED reviewer sonnet)}" || return 1
  stop_case "$c" "$(printf '.seed.state = "%s" | %s' "$st" "$2")" || return 1
  run_hook subagent-stop.sh "$c" || { fail "step $1: run_hook: $WV_LAST_STDERR"; return 1; }
  return 0
}

if drive seven '.seed.files = {".wave/red.md": "RED-VERIFIED failing=7\n"}'; then
  assert_allow || fail "failing=7: want no block"
  [ "$(stop_phase_status TDE-RED)" = "done" ] || \
    fail "failing=7: status is '$(stop_phase_status TDE-RED)', want done"
fi

if drive zero '.seed.files = {".wave/red.md": "RED-VERIFIED failing=0\n"}'; then
  assert_block W-MARKER || fail "failing=0: want block(W-MARKER)"
  assert_reason_contains '^RED-VERIFIED failing=[1-9][0-9]*$' || \
    fail "failing=0: the reason must quote the regex"
  [ "$(stop_phase_status TDE-RED)" != "done" ] || fail "failing=0: TDE-RED must not be done"
fi

exit $rc
