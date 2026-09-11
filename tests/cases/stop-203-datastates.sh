#!/usr/bin/env bash
# tests/cases/stop-203-datastates.sh — AC-203, all three data states of the
# hand-off artifact at the AC reviewer's stop.
#
#   empty   (.wave/ac.md absent)              -> block(W-ARTIFACT) naming the file
#   partial (present, no ^AC-<n> line)        -> block(W-MARKER)
#   full    (present and matching)            -> done
#
# In every one of the three the ledger line is still appended: spend is recorded
# even when the phase fails its artifact check, because the tokens were spent
# either way and a wave that hides failed spend cannot be scored.
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
  # drive <step> <case filter> — a fresh project, the AC-reviewer state, one stop.
  WV_PROJECT=""
  local st="$WV_RUN_TMP/$name-$1-state.json" c="$WV_RUN_TMP/$name-$1.json"
  stop_state "$st" ".active = {a1: $(stop_active AC reviewer opus)}" || return 1
  stop_case "$c" "$(printf '.seed.state = "%s" | %s' "$st" "$2")" || return 1
  run_hook subagent-stop.sh "$c" || { fail "step $1: run_hook: $WV_LAST_STDERR"; return 1; }
  return 0
}

# --- empty: no artifact at all ---------------------------------------------
if drive empty '.'; then
  assert_block W-ARTIFACT || fail "empty: want block(W-ARTIFACT)"
  assert_reason_contains '.wave/ac.md' || fail "empty: the reason must name the artifact"
  [ "$(stop_phase_status AC)" = "artifact-missing" ] || \
    fail "empty: phases.AC.status is '$(stop_phase_status AC)', want artifact-missing"
  [ "$(stop_ledger_count)" = "1" ] || fail "empty: ledger has $(stop_ledger_count) line(s), want 1"
fi

# --- partial: present, but no line matches the marker ----------------------
if drive partial '.seed.files = {".wave/ac.md": "criteria to follow\n"}'; then
  assert_block W-MARKER || fail "partial: want block(W-MARKER)"
  [ "$(stop_phase_status AC)" != "done" ] || fail "partial: AC must not be done"
  [ "$(stop_ledger_count)" = "1" ] || fail "partial: ledger has $(stop_ledger_count) line(s), want 1"
fi

# --- full: present and matching -------------------------------------------
if drive full '.seed.files = {".wave/ac.md": "AC-1 records the spend\n"}'; then
  assert_allow || fail "full: want no block"
  [ "$(stop_phase_status AC)" = "done" ] || \
    fail "full: phases.AC.status is '$(stop_phase_status AC)', want done"
  [ "$(stop_ledger_count)" = "1" ] || fail "full: ledger has $(stop_ledger_count) line(s), want 1"
fi

exit $rc
