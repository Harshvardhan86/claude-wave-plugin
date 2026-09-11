#!/usr/bin/env bash
# tests/cases/marker-208-acb-third-line.sh — AC-208: the match domain is "ANY
# line of the artifact under `command grep -E`", identically for every row. So
# a marker on the third line satisfies it, and a line that merely reads like the
# marker in prose ("ACB verified") does not.
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
  stop_state "$st" ".active = {a1: $(stop_active ACB reviewer opus)}" || return 1
  stop_case "$c" "$(printf '.seed.state = "%s" | %s' "$st" "$2")" || return 1
  run_hook subagent-stop.sh "$c" || { fail "step $1: run_hook: $WV_LAST_STDERR"; return 1; }
  return 0
}

if drive third '.seed.files = {".wave/acb.md": "reviewed the criteria\nfound three gaps\nACB-VERIFIED 12 criteria hardened\n"}'; then
  assert_allow || fail "third line: want no block"
  [ "$(stop_phase_status ACB)" = "done" ] || \
    fail "third line: phases.ACB.status is '$(stop_phase_status ACB)', want done"
fi

if drive prose '.seed.files = {".wave/acb.md": "ACB verified\n"}'; then
  assert_block W-MARKER || fail "prose: want block(W-MARKER)"
  assert_reason_contains '^ACB-VERIFIED' || fail "prose: the reason must quote the regex"
  [ "$(stop_phase_status ACB)" != "done" ] || fail "prose: ACB must not be done"
fi

exit $rc
