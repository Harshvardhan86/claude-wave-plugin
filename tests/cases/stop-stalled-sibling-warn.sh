#!/usr/bin/env bash
# tests/cases/stop-stalled-sibling-warn.sh — fix round 1, item 5.
#
# The closing role's stop is skipped while a sibling of the same phase is still
# running. That is right for a live fan-out — and it is a silent stall when the
# sibling never stops at all (killed, rate-limited, its SubagentStop lost). The
# wave then waits for an event that will not arrive, with nothing in any record
# saying so.
#
# So the skip is REPORTED: a W-STATE warning naming the agent ids still held
# open, and the remedy. SubagentStop has no additionalContext channel, so the
# warning goes to stderr.
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

WV_PROJECT="$(mkproj)"
st="$WV_RUN_TMP/$name-state.json"
stop_state "$st" ".active = {a1: $(stop_active BC scanner sonnet),
                             a2stalled: $(stop_active BC scanner sonnet),
                             a3stalled: $(stop_active BC scanner sonnet)}" || exit 1

c="$WV_RUN_TMP/$name.json"
stop_case "$c" "$(printf '.seed.state = "%s" | .seed.files = {".wave/findings/BC.md": "FINDINGS: 0\\n"}' "$st")" || exit 1
run_hook subagent-stop.sh "$c" || { fail "run_hook: $WV_LAST_STDERR"; exit 1; }

assert_allow || fail "want no block — the check is skipped, not failed"
[ -z "$WV_LAST_STDOUT" ] || fail "stdout must be empty, got '$WV_LAST_STDOUT'"
[ "$(stop_phase_status BC)" = "" ] || \
  fail "no phase status may be written while siblings are running, got '$(stop_phase_status BC)'"

case "$WV_LAST_STDERR" in
  *W-STATE*) : ;;
  *) fail "the skipped check must be reported as W-STATE, stderr was '$WV_LAST_STDERR'" ;;
esac
case "$WV_LAST_STDERR" in
  *a2stalled*) : ;;
  *) fail "the warning must name the sibling still running (a2stalled), stderr was '$WV_LAST_STDERR'" ;;
esac
case "$WV_LAST_STDERR" in
  *a3stalled*) : ;;
  *) fail "the warning must name EVERY sibling still running (a3stalled), stderr was '$WV_LAST_STDERR'" ;;
esac
case "$WV_LAST_STDERR" in
  *wave-set.sh*|*re-dispatch*) : ;;
  *) fail "the warning must name a remedy, stderr was '$WV_LAST_STDERR'" ;;
esac
[ "$(stop_ledger_count)" = "1" ] || fail "ledger has $(stop_ledger_count) line(s), want 1"

# The negative control: the LAST one out is not a stall, and says nothing.
c2="$WV_RUN_TMP/$name-last.json"
jq '.active = (.active | del(.a2stalled) | del(.a3stalled))' "$WV_PROJECT/.wave/state.json" \
  > "$WV_RUN_TMP/$name-live.json" && mv "$WV_RUN_TMP/$name-live.json" "$WV_PROJECT/.wave/state.json" || exit 1
jq '.active.a4 = .active.a1 | .active.a4.status = "launched"' "$WV_PROJECT/.wave/state.json" \
  > "$WV_RUN_TMP/$name-live2.json" && mv "$WV_RUN_TMP/$name-live2.json" "$WV_PROJECT/.wave/state.json" || exit 1
stop_case "$c2" '.stdin.agent_id = "a4"' || exit 1
run_hook subagent-stop.sh "$c2" || { fail "last-one-out: $WV_LAST_STDERR"; exit 1; }
[ "$(stop_phase_status BC)" = "done" ] || \
  fail "last-one-out: status is '$(stop_phase_status BC)', want done"
case "$WV_LAST_STDERR" in
  *W-STATE*) fail "last-one-out: nothing is stalled, so no W-STATE may be emitted: '$WV_LAST_STDERR'" ;;
esac

exit $rc
