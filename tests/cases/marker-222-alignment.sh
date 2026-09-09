#!/usr/bin/env bash
# tests/cases/marker-222-alignment.sh — AC-222: OA's marker is
# `^ALIGNMENT: [0-9]+%$`. A bare number and a spelled-out one are both refused,
# and the reason quotes both the regex and the offending line verbatim, because
# "the marker did not match" is not something the agent can act on.
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
  stop_state "$st" ".active = {a1: $(stop_active OA reviewer opus)}" || return 1
  stop_case "$c" "$(printf '.seed.state = "%s" | .seed.files = {".wave/oa.md": "%s\\n"}' "$st" "$2")" || return 1
  run_hook subagent-stop.sh "$c" || { fail "step $1: run_hook: $WV_LAST_STDERR"; return 1; }
  return 0
}

if drive percent 'ALIGNMENT: 97%'; then
  assert_allow || fail "97%: want no block"
  [ "$(stop_phase_status OA)" = "done" ] || fail "97%: status is '$(stop_phase_status OA)', want done"
fi

if drive nopercent 'ALIGNMENT: 97'; then
  assert_block W-MARKER || fail "no %: want block(W-MARKER)"
  assert_reason_contains '^ALIGNMENT: [0-9]+%$' || fail "no %: the reason must quote the regex"
  assert_reason_contains 'ALIGNMENT: 97' || fail "no %: the reason must quote the offending line"
  [ "$(stop_phase_status OA)" != "done" ] || fail "no %: OA must not be done"
fi

if drive spelled 'ALIGNMENT: ninety'; then
  assert_block W-MARKER || fail "spelled: want block(W-MARKER)"
  assert_reason_contains 'ALIGNMENT: ninety' || fail "spelled: the reason must quote the offending line"
fi

exit $rc
