#!/usr/bin/env bash
# leftover-431 — leftover inventory at the SubagentStop that completes the wave.
#
# Protects: inventory + W-LEFTOVER (or a clean checkpoint) happen when the
# last unsettled when=phase row is recorded done, not when AD (anytime) stops.
# And (the done|failed|artifact-missing trigger, kept for a final row):
# the closing role's stop of a FINAL row (a when=phase row no other row of
# the mode names in `after`) inventories WHATEVER its resulting status, as
# long as every OTHER when=phase row of the mode is settled — a wave that
# ends on a failed or artifact-missing final row never completes, and it is
# the wave most likely to leave runaway work behind. The wave stays active
# (nothing closes it but a person). A final row whose siblings are NOT all
# settled does not inventory. stdout stays empty on every non-block path.
set -u
source "$(dirname "$0")/../lib/assert.sh"
name="${WV_CASE_NAME:-$(basename "$0" .sh)}"
log="${WV_CASE_LOG:-$WV_RUN_TMP/logs/$name.log}"
rc=0
fail() { printf 'ASSERT FAIL: %s\n' "$*" >&2; rc=1; }
source "$WV_TESTS_DIR/fixtures/leftover-case.sh"
source "$WV_TESTS_DIR/lib/stop.sh"

ALWAYS="AC ACB TDE-RED TDE-GREEN BC SEA DS BSEA OA TEET-TC TEET BTEET BTEET-X VB COMMIT CL CCP"

done_except() {
  local skip=" $* "
  local c
  {
    for c in $ALWAYS; do
      case "$skip" in *" $c "*) continue ;; esac
      printf '%s\n' "$c"
    done
  } | jq -R . | jq -s 'map(select(length>0) | {(.): {status:"done", at:"2026-09-09T12:10:00Z", agent:"a0"}}) | add'
}

for variant in leftover self-only; do
  WV_PROJECT="$(mkproj)"
  st="$WV_RUN_TMP/$name-state.json"
  stop_state "$st" ".active = {a1: $(stop_active CL executor sonnet)} | .phases = $(done_except CL)" || exit 1
  stop_case "$lo_c" " .seed.state = \"$st\" | .seed.files += $(stop_findings_zero) " || exit 1
  if [ "$variant" = leftover ]; then
    jq '.stdin.background_tasks += [{id:"lo-shell",type:"shell",status:"running"}] | .stdin.session_crons = [{id:"lo-cron"}]' "$lo_c" > "$lo_c.tmp" && mv "$lo_c.tmp" "$lo_c"
  fi
  lo_run subagent-stop.sh
  assert_allow || rc=1
  [ -z "$WV_LAST_STDOUT" ] || fail 'closing stop wrote stdout'
  assert_state '.status == "closed" and .phases.CL.status == "done"' || rc=1
  lo_checkpoint
  lo_contains '(SubagentStop)'
  if [ "$variant" = leftover ]; then
    assert_stderr_contains W-LEFTOVER || rc=1
    case "$WV_LAST_STDERR" in
      *W-SCORECARD*) fail 'leftover close must not also print W-SCORECARD' ;;
    esac
    lo_contains lo-shell
    lo_contains lo-cron
  else
    assert_stderr_contains W-SCORECARD || rc=1
    case "$WV_LAST_STDERR" in
      *W-LEFTOVER*) fail 'clean close printed W-LEFTOVER' ;;
    esac
    lo_contains 'tasks=none; crons=none; watchers=none; unavailable=none'
  fi
done

# Final row (demo TEET) with a missing artifact, every other demo row
# settled: blocks W-ARTIFACT, INVENTORIES (W-LEFTOVER + checkpoint), stays
# active.
WV_PROJECT="$(mkproj)"
st="$WV_RUN_TMP/$name-fail-state.json"
teet_active="$(stop_active TEET reviewer sonnet)"
demo_done='AC:{status:"done",at:"2026-09-09T12:00:00Z",agent:"a0"},DR:{status:"done",at:"2026-09-09T12:00:00Z",agent:"a0"},"TDE-RED":{status:"done",at:"2026-09-09T12:00:00Z",agent:"a0"}'
stop_state "$st" ".mode = \"demo\" | .ui = true | .behaviour_change = true | .phases = {$demo_done,\"TDE-GREEN\":{status:\"done\",at:\"2026-09-09T12:00:00Z\",agent:\"a0\"}} | .active = {a1: $teet_active}" || exit 1
stop_case "$lo_c" ".seed.state = \"$st\" | .stdin.background_tasks += [{id:\"lo-shell\",type:\"shell\",status:\"running\"}] | .stdin.session_crons = [{id:\"lo-cron\"}]" || exit 1
lo_run subagent-stop.sh
assert_block W-ARTIFACT || rc=1
assert_stderr_contains W-LEFTOVER || rc=1
lo_checkpoint
lo_contains lo-shell
lo_contains lo-cron
assert_state '.status == "active" and .phases.TEET.status == "artifact-missing"' || rc=1
[ -f "$WV_PROJECT/.wave/.leftover-warned" ] || fail 'final-row artifact-missing inventory did not mark the wave warned'

# Final row (full CCP) recorded FAILED (its agent was already blocked for the
# missing checkpoint and came back without it), every other full row settled:
# no block, INVENTORIES, stays active, no close-time pointer or verdict.
WV_PROJECT="$(mkproj)"
st="$WV_RUN_TMP/$name-failed-state.json"
ccp_active="$(stop_active CCP executor sonnet | jq -c '. + {blocked: ["W-ARTIFACT"]}')"
stop_state "$st" ".active = {a1: $ccp_active} | .phases = $(done_except CCP)" || exit 1
stop_case "$lo_c" ".seed.state = \"$st\" | .seed.files += $(stop_findings_zero) | .stdin.background_tasks += [{id:\"lo-shell\",type:\"shell\",status:\"running\"}] | .stdin.session_crons = [{id:\"lo-cron\"}]" || exit 1
lo_run subagent-stop.sh
[ -z "$WV_LAST_STDOUT" ] || fail "final-row failed: stdout must be empty, got '$WV_LAST_STDOUT'"
assert_state '.status == "active" and .phases.CCP.status == "failed"' || rc=1
assert_stderr_contains W-LEFTOVER || rc=1
lo_checkpoint
lo_contains lo-shell
case "$WV_LAST_STDERR" in
  *W-SCORECARD*|*W-UNDELIVERED*) fail "final-row failed: the wave did not close, so no pointer or verdict: '$WV_LAST_STDERR'" ;;
esac

# Final row with a missing artifact while ANOTHER row is unsettled (demo
# TDE-GREEN not done): no inventory, no checkpoint.
WV_PROJECT="$(mkproj)"
st="$WV_RUN_TMP/$name-early-state.json"
stop_state "$st" ".mode = \"demo\" | .ui = true | .behaviour_change = true | .phases = {$demo_done} | .active = {a1: $teet_active}" || exit 1
stop_case "$lo_c" ".seed.state = \"$st\" | .stdin.background_tasks += [{id:\"lo-shell\",type:\"shell\",status:\"running\"}] | .stdin.session_crons = [{id:\"lo-cron\"}]" || exit 1
lo_run subagent-stop.sh
assert_block W-ARTIFACT || rc=1
case "$WV_LAST_STDERR" in
  *W-LEFTOVER*) fail 'a final row with an unsettled sibling must not inventory leftovers' ;;
esac
assert_state '.status == "active"' || rc=1
[ ! -d "$WV_PROJECT/.wave/checkpoints" ] || fail 'a final row with an unsettled sibling wrote a leftovers checkpoint'

# A NON-final row with a missing artifact, everything else settled (full BC
# scanner last, no findings file): no inventory either — only final rows and
# the completing stop take it.
WV_PROJECT="$(mkproj)"
st="$WV_RUN_TMP/$name-nonfinal-state.json"
stop_state "$st" ".active = {a1: $(stop_active BC executor sonnet)} | .phases = $(done_except BC)" || exit 1
stop_case "$lo_c" ".seed.state = \"$st\" | .seed.files += ($(stop_findings_zero) | del(.[\".wave/findings/BC.md\"])) | .stdin.background_tasks += [{id:\"lo-shell\",type:\"shell\",status:\"running\"}] | .stdin.session_crons = [{id:\"lo-cron\"}]" || exit 1
lo_run subagent-stop.sh
case "$WV_LAST_STDERR" in
  *W-LEFTOVER*) fail 'a non-final row must not inventory leftovers' ;;
esac
assert_state '.status == "active"' || rc=1
[ ! -d "$WV_PROJECT/.wave/checkpoints" ] || fail 'a non-final row wrote a leftovers checkpoint'

exit $rc
