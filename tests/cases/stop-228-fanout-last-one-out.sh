#!/usr/bin/env bash
# tests/cases/stop-228-fanout-last-one-out.sh — AC-228 under the controller's
# ruling, plus the round half of the fan-out.
#
# TEET-TC has `fanout` 3 and defines a reviewer, so its CLOSING role is that
# reviewer and a `writer` stop never runs the artifact check — not the first
# writer's and not the last one's either. That is the ruling AC-229 states in
# general form ("never at an executor/writer/scanner stop"), and it is what lets
# the framework's PDT fan-out of three parallel writers each stop cleanly with
# `.wave/teet-tc.md` not yet written.
#
# What the last writer out DOES do is move the round counter once, for the whole
# group (spec section 8.7).
#
# The last-one-out predicate for the ARTIFACT check — the property AC-228's
# second half was written to protect — is asserted in
# stop-228b-bc-scanner-last-one-out.sh on a phase whose closing role is the one
# that fans out.
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

rounds() { jq -r '(.rounds["TEET-TC/writer"] // "unset") | tostring' "$WV_PROJECT/.wave/state.json"; }

WV_PROJECT="$(mkproj)"
st="$WV_RUN_TMP/$name-state.json"
stop_state "$st" ".active = {a1: $(stop_active TEET-TC writer sonnet),
                             a2: $(stop_active TEET-TC writer sonnet)}" || exit 1

stop() { # stop <agent> [seed]
  # Only the FIRST stop seeds the state fixture. A second seed would copy the
  # fixture back over the live state and resurrect the sibling agent as still
  # running, which is precisely the condition the last-one-out predicate reads.
  local c="$WV_RUN_TMP/$name-$1.json"
  if [ "${2:-seed}" = "seed" ]; then
    stop_case "$c" "$(printf '.seed.state = "%s" | .stdin.agent_id = "%s"' "$st" "$1")" || return 1
  else
    stop_case "$c" "$(printf '.stdin.agent_id = "%s"' "$1")" || return 1
  fi
  run_hook subagent-stop.sh "$c" || { fail "$1: run_hook: $WV_LAST_STDERR"; return 1; }
  return 0
}

# The first writer out: nothing to check, nothing to close, one ledger line.
if stop a1; then
  assert_allow || fail "a1: want no block"
  [ -z "$WV_LAST_STDOUT" ] || fail "a1: stdout must be empty, got '$WV_LAST_STDOUT'"
  [ "$(stop_phase_status TEET-TC)" = "" ] || \
    fail "a1: no phase status may be written yet, got '$(stop_phase_status TEET-TC)'"
  [ "$(stop_ledger_count)" = "1" ] || fail "a1: ledger has $(stop_ledger_count) line(s), want 1"
  [ "$(rounds)" = "unset" ] || fail "a1: rounds moved to '$(rounds)' while a2 is still running"
fi

# The last writer out: still no artifact check (a writer is not the closing
# role), and the round counter moves exactly once for the group.
# The state file the second run seeds is the LIVE one, not the fixture: seeding
# the fixture again would resurrect a1 as running.
if stop a2 live; then
  assert_allow || fail "a2: want no block — a writer stop never runs the artifact check"
  [ -z "$WV_LAST_STDOUT" ] || fail "a2: stdout must be empty, got '$WV_LAST_STDOUT'"
  [ "$(stop_phase_status TEET-TC)" = "" ] || \
    fail "a2: TEET-TC must have no status, got '$(stop_phase_status TEET-TC)'"
  [ "$(stop_ledger_count)" = "2" ] || fail "a2: ledger has $(stop_ledger_count) line(s), want 2"
  [ "$(rounds)" = "1" ] || fail "a2: rounds is '$(rounds)', want 1 — three writers are ONE round"
fi

exit $rc
