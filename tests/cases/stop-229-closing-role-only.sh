#!/usr/bin/env bash
# tests/cases/stop-229-closing-role-only.sh — AC-229: the artifact check runs at
# the CLOSING role's stop and nowhere else. TDE-GREEN defines lead, executor and
# reviewer, so its reviewer closes it: the executor stopping with `.wave/green.md`
# absent is not a failure (the reviewer has not run yet, and blocking the
# executor would demand an artifact that is not its job), while the reviewer
# stopping in the same state is.
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
  # drive <role>
  WV_PROJECT=""
  local role="$1" model="$2"
  local st="$WV_RUN_TMP/$name-$role-state.json" c="$WV_RUN_TMP/$name-$role.json"
  stop_state "$st" ".active = {a1: $(stop_active TDE-GREEN "$role" "$model")}" || return 1
  stop_case "$c" "$(printf '.seed.state = "%s"' "$st")" || return 1
  run_hook subagent-stop.sh "$c" || { fail "$role: run_hook: $WV_LAST_STDERR"; return 1; }
  return 0
}

if drive executor sonnet; then
  assert_allow || fail "executor: want no block"
  [ -z "$WV_LAST_STDOUT" ] || fail "executor: stdout must be empty, got '$WV_LAST_STDOUT'"
  [ "$(stop_phase_status TDE-GREEN)" != "done" ] || fail "executor: the phase must not be marked done"
  [ "$(stop_phase_status TDE-GREEN)" = "" ] || \
    fail "executor: no status may be written at all, got '$(stop_phase_status TDE-GREEN)'"
  [ "$(stop_ledger_count)" = "1" ] || fail "executor: ledger has $(stop_ledger_count) line(s), want 1"
fi

if drive reviewer opus; then
  assert_block W-ARTIFACT || fail "reviewer: want block(W-ARTIFACT)"
  assert_reason_contains '.wave/green.md' || fail "reviewer: the reason must name the artifact"
  [ "$(stop_phase_status TDE-GREEN)" = "artifact-missing" ] || \
    fail "reviewer: status is '$(stop_phase_status TDE-GREEN)', want artifact-missing"
fi

exit $rc
