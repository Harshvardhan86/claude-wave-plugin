#!/usr/bin/env bash
# undelivered-closing-subagent.sh — W-UNDELIVERED is emitted by the closing
# SubagentStop, once, on stderr, and composes with W-LEFTOVER / W-SCORECARD.
#
# Composition (lib.sh wv_close_announce, the same function
# stop.sh uses in solo mode, where the warnings share one JSON object instead
# of stderr; a full/demo Stop never announces). The full cell-by-cell
# matrix with every marker is undelivered-close-matrix.sh:
#   SubagentStop stderr may carry more than one warning; stdout stays empty.
#   leftover  -> W-LEFTOVER, not W-SCORECARD (leftover already names the scorecard)
#   clean     -> W-SCORECARD
#   undelivered/unverified -> W-UNDELIVERED IN ADDITION, never instead
#   order: W-LEFTOVER, then W-UNDELIVERED, then W-SCORECARD
set -u
source "$(dirname "$0")/../lib/assert.sh"
name="${WV_CASE_NAME:-$(basename "$0" .sh)}"
log="${WV_CASE_LOG:-$WV_RUN_TMP/logs/$name.log}"
rc=0
fail() { printf 'ASSERT FAIL: %s\n' "$*" >&2; rc=1; }
source "$WV_TESTS_DIR/lib/stop.sh"
printf 'RAN subagent-stop.sh %s decision=multi\n' "$name" >> "$log"

ALWAYS="AC ACB TDE-RED TDE-GREEN BC SEA DS BSEA OA TEET-TC TEET BTEET BTEET-X VB COMMIT CL CCP"
done_except() {
  local skip=" $* "
  local c
  {
    for c in $ALWAYS; do
      case "$skip" in *" $c "*) continue ;; esac
      printf '%s\n' "$c"
    done
    printf '%s\n' BEN DR BEN-CLOSE
  } | jq -R . | jq -s 'map(select(length>0) | {(.): {status:"done", at:"2026-09-09T12:10:00Z", agent:"a0"}}) | add'
}

drive_close() {
  local extras="$1"
  WV_PROJECT="$(mkproj)"
  local st c
  st="$WV_RUN_TMP/$name-state.json"
  c="$WV_RUN_TMP/$name.json"
  stop_state "$st" ".behaviour_change = true | .active = {a1: $(stop_active CL executor sonnet)} | .phases = $(done_except CL)" || return 1
  stop_case "$c" "$(printf '.seed.state = "%s" | .seed.files = {".wave/ben-close.md": "BENEFIT: UNDELIVERED\\norphan readers: 0\\n"} %s' "$st" "$extras") | .seed.files += $(stop_findings_zero)" || return 1
  run_hook subagent-stop.sh "$c" || { fail "run_hook: $WV_LAST_STDERR"; return 1; }
}

# Positive: closing stop, undelivered, clean leftovers -> W-UNDELIVERED and W-SCORECARD on stderr.
drive_close ""
assert_allow || rc=1
[ -z "$WV_LAST_STDOUT" ] || fail "stdout must be empty, got '$WV_LAST_STDOUT'"
assert_state '.status == "closed" and .delivery == "undelivered"' || rc=1
assert_stderr_contains W-UNDELIVERED || rc=1
assert_stderr_contains W-SCORECARD || rc=1
case "$WV_LAST_STDERR" in
  *W-LEFTOVER*) fail 'clean undelivered close printed W-LEFTOVER' ;;
esac
case "$WV_LAST_STDERR" in
  *'[W-UNDELIVERED]'*'[W-SCORECARD]'*) : ;;
  *) fail "clean undelivered close: want W-UNDELIVERED before W-SCORECARD, got '$WV_LAST_STDERR'" ;;
esac
[ -f "$WV_PROJECT/.wave/.scorecard-printed" ] || fail 'clean undelivered close: the scorecard marker must be written in the same call'
[ -f "$WV_PROJECT/.wave/.undelivered-warned" ] || fail 'once-per-wave undelivered marker missing'

# Once: a later Stop on the closed wave is silent (wv_state_read refuses closed).
stop_c="$WV_RUN_TMP/$name-stop.json"
jq -n '{script:"stop.sh", stdin:{hook_event_name:"Stop", background_tasks:[], session_crons:[]}}' > "$stop_c"
run_hook stop.sh "$stop_c" || fail "Stop after close: $WV_LAST_STDERR"
assert_silent || fail "Stop after close must be silent, got stdout='$WV_LAST_STDOUT' stderr='$WV_LAST_STDERR'"

# Composition: leftover + undelivered, no W-SCORECARD.
drive_close '| .stdin.background_tasks += [{id:"lo-shell",type:"shell",status:"running"}] | .stdin.session_crons = [{id:"lo-cron"}]'
assert_allow || rc=1
[ -z "$WV_LAST_STDOUT" ] || fail "leftover undelivered: stdout must be empty"
assert_stderr_contains W-LEFTOVER || rc=1
assert_stderr_contains W-UNDELIVERED || rc=1
case "$WV_LAST_STDERR" in
  *W-SCORECARD*) fail 'leftover+undelivered must not print W-SCORECARD' ;;
esac
case "$WV_LAST_STDERR" in
  *'[W-LEFTOVER]'*'[W-UNDELIVERED]'*) : ;;
  *) fail "leftover+undelivered: want W-LEFTOVER before W-UNDELIVERED, got '$WV_LAST_STDERR'" ;;
esac

# Negative: delivered close does not print W-UNDELIVERED.
WV_PROJECT="$(mkproj)"
st="$WV_RUN_TMP/$name-deliv-state.json"
c="$WV_RUN_TMP/$name-deliv.json"
stop_state "$st" ".behaviour_change = true | .active = {a1: $(stop_active CL executor sonnet)} | .phases = $(done_except CL)" || exit 1
stop_case "$c" "$(printf '.seed.state = "%s" | .seed.files = {".wave/ben-close.md": "BENEFIT: DELIVERED\\n"}' "$st") | .seed.files += $(stop_findings_zero)" || exit 1
run_hook subagent-stop.sh "$c" || fail "delivered close: $WV_LAST_STDERR"
assert_allow || rc=1
assert_state '.delivery == "delivered"' || rc=1
case "$WV_LAST_STDERR" in
  *W-UNDELIVERED*) fail 'delivered close printed W-UNDELIVERED' ;;
esac
assert_stderr_contains W-SCORECARD || rc=1

exit $rc
