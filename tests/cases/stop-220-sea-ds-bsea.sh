#!/usr/bin/env bash
# tests/cases/stop-220-sea-ds-bsea.sh — AC-220: the findings path is derived from
# the ROW's `findings` column, never hard-coded to BC. SEA, DS and BSEA each get
# their own `.wave/findings/<PHASE>.md`, and BSEA's closing role is its reviewer
# (it is the one scan row that defines all three roles) while SEA's and DS's is
# their executor.
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
  # drive <phase> <role> <model> <count>
  WV_PROJECT=""
  local phase="$1" role="$2" model="$3" count="$4"
  local st="$WV_RUN_TMP/$name-$phase-state.json" c="$WV_RUN_TMP/$name-$phase.json"
  stop_state "$st" ".active = {a1: $(stop_active "$phase" "$role" "$model")}" || return 1
  stop_case "$c" "$(printf '.seed.state = "%s" | .seed.files = {".wave/findings/%s.md": "FINDINGS: %s\\n"}' \
    "$st" "$phase" "$count")" || return 1
  run_hook subagent-stop.sh "$c" || { fail "$phase: run_hook: $WV_LAST_STDERR"; return 1; }
  local got
  got="$(jq -r --arg p "$phase" '(.phases[$p].findings // "unset") | tostring' "$WV_PROJECT/.wave/state.json")"
  assert_allow || fail "$phase: want no block"
  [ "$(stop_phase_status "$phase")" = "done" ] || \
    fail "$phase: status is '$(stop_phase_status "$phase")', want done"
  [ "$got" = "$count" ] || fail "$phase: recorded findings is '$got', want $count"
  return 0
}

drive SEA executor sonnet 3
drive DS executor sonnet 0
drive BSEA reviewer opus 7

exit $rc
