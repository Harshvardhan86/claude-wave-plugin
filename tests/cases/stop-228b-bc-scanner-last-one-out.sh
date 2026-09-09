#!/usr/bin/env bash
# tests/cases/stop-228b-bc-scanner-last-one-out.sh — the last-one-out predicate on
# a phase whose CLOSING role is the one that fans out.
#
# BC has `fanout` 3 and defines neither lead nor reviewer, so its executor
# column (which `scanner` resolves to) is its closing role. Three concurrent BC
# scanners are one round and the findings file is only complete when the last of
# them has stopped — so the artifact check must run at the LAST scanner's stop
# and at none of the earlier ones. Without the predicate the first scanner out
# blocks on a findings file its siblings are still writing.
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

rounds() { jq -r '(.rounds["BC/scanner"] // "unset") | tostring' "$WV_PROJECT/.wave/state.json"; }

WV_PROJECT="$(mkproj)"
st="$WV_RUN_TMP/$name-state.json"
stop_state "$st" ".active = {a1: $(stop_active BC scanner sonnet),
                             a2: $(stop_active BC scanner sonnet)}" || exit 1

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

if stop a1; then
  assert_allow || fail "a1: want no block — a2 of the same phase is still running"
  [ "$(stop_phase_status BC)" = "" ] || fail "a1: no status may be written yet"
  [ "$(rounds)" = "unset" ] || fail "a1: rounds moved while a2 is still running"
fi

if stop a2 live; then
  assert_block W-ARTIFACT || fail "a2 (last one out): want block(W-ARTIFACT)"
  assert_reason_contains '.wave/findings/BC.md' || fail "a2: the reason must name the findings file"
  [ "$(stop_phase_status BC)" = "artifact-missing" ] || \
    fail "a2: status is '$(stop_phase_status BC)', want artifact-missing"
  [ "$(rounds)" = "1" ] || fail "a2: rounds is '$(rounds)', want 1"
fi

exit $rc
