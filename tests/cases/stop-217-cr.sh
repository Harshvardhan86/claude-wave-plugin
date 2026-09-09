#!/usr/bin/env bash
# tests/cases/stop-217-cr.sh — AC-217: CR is expressed as one `reviewer`
# dispatch, so its reviewer is its closing role; `.wave/cr.md` carrying
# `CR-VERIFIED` completes it and its absence blocks(W-ARTIFACT).
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
  stop_state "$st" ".active = {a1: $(stop_active CR reviewer sonnet)} | .cr_enabled = true" || return 1
  stop_case "$c" "$(printf '.seed.state = "%s" | %s' "$st" "$2")" || return 1
  run_hook subagent-stop.sh "$c" || { fail "step $1: run_hook: $WV_LAST_STDERR"; return 1; }
  return 0
}

if drive present '.seed.files = {".wave/cr.md": "CR-VERIFIED\n"}'; then
  assert_allow || fail "present: want no block"
  [ "$(stop_phase_status CR)" = "done" ] || fail "present: status is '$(stop_phase_status CR)', want done"
fi

if drive absent '.'; then
  assert_block W-ARTIFACT || fail "absent: want block(W-ARTIFACT)"
  assert_reason_contains '.wave/cr.md' || fail "absent: the reason must name the artifact"
  [ "$(stop_phase_status CR)" = "artifact-missing" ] || \
    fail "absent: status is '$(stop_phase_status CR)', want artifact-missing"
fi

exit $rc
