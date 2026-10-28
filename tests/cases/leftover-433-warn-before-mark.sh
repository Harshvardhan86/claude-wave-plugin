#!/usr/bin/env bash
# leftover-433 — the once-per-wave W-LEFTOVER marker must be written only AFTER
# the warning has actually been queued for emission.
#
# `.wave/.leftover-warned` silences every later Stop / SubagentStop in the wave.
# If it is written BEFORE wv_rule_warn (or without checking that the call
# succeeded), an emit that fails leaves the wave permanently marked warned for a
# warning the operator never saw — the inventory keeps refreshing in
# leftovers-stop.md, but nothing ever says it is there again.
#
# The emit helper is forced to fail through BASH_ENV: a readonly replacement of
# wv_rule_warn is installed before the hook sources lib.sh, so lib.sh's own
# definition is refused and the hook calls a version that reports failure and
# emits nothing (the same shape a broken output channel or a future refactor
# would take). The marker must be absent afterwards and the NEXT fire must still
# deliver the warning.
set -u
source "$(dirname "$0")/../lib/assert.sh"
name="${WV_CASE_NAME:-$(basename "$0" .sh)}"
log="${WV_CASE_LOG:-$WV_RUN_TMP/logs/$name.log}"
rc=0
fail() { printf 'ASSERT FAIL: %s\n' "$*" >&2; rc=1; }
source "$WV_TESTS_DIR/fixtures/leftover-case.sh"
source "$WV_TESTS_DIR/lib/stop.sh"

emit_fail="$WV_RUN_TMP/$name-emit-fail.sh"
cat > "$emit_fail" <<'SHIM'
# Sourced by bash (BASH_ENV) before the hook script runs, so this definition is
# in place before lib.sh is sourced; `readonly -f` makes lib.sh's redefinition a
# refused no-op. The emit reports failure and writes nothing.
wv_rule_warn() { return 1; }
readonly -f wv_rule_warn
SHIM

lo_shim_on() {
  jq --arg p "$emit_fail" '.env.BASH_ENV = $p' "$lo_c" > "$lo_c.tmp" \
    && mv "$lo_c.tmp" "$lo_c" || exit 1
}
lo_marker() { printf '%s' "$WV_PROJECT/.wave/.leftover-warned"; }
lo_no_leftover_in() {
  case "$2" in
    *W-LEFTOVER*) fail "$1 carried W-LEFTOVER while the emit was forced to fail" ;;
  esac
}

# ---- Stop: a failed emit must not mark the wave warned ---------------------
WV_PROJECT="$(mkproj)"
lo_case '.'
lo_shim_on
lo_run stop.sh
lo_no_leftover_in stdout "$WV_LAST_STDOUT"
lo_no_leftover_in stderr "$WV_LAST_STDERR"
[ -e "$(lo_marker)" ] && fail 'Stop marked the wave warned although the emit failed'
lo_checkpoint   # the inventory still landed

# The next Stop must retry and deliver the warning.
lo_case '.'
lo_run stop.sh
assert_warn W-LEFTOVER || rc=1
[ -e "$(lo_marker)" ] || fail 'Stop did not mark the wave warned after a successful emit'

# ---- Stop: the success path stays once-per-wave ----------------------------
WV_PROJECT="$(mkproj)"
lo_case '.'
lo_run stop.sh
assert_warn W-LEFTOVER || rc=1
[ -e "$(lo_marker)" ] || fail 'marker missing after the first successful Stop warning'
lo_case '.'
lo_run stop.sh
case "$WV_LAST_STDOUT" in
  *W-LEFTOVER*) fail 'leftover warning repeated after a successful emit' ;;
esac

# ---- SubagentStop: the NON-closing final-row inventory (artifact-missing) ---
# The final demo row (TEET) comes back without its artifact while every other
# demo row is settled: the hook blocks W-ARTIFACT, takes the inventory and
# warns W-LEFTOVER itself (this call does not close the wave), and the wave
# stays active. A failed emit there must leave the wave unmarked, and a retry
# on that SAME still-active wave must deliver the warning and only then mark.
lo_r5_case() {
  st="$WV_RUN_TMP/$name-r5-state.json"
  teet_active="$(stop_active TEET reviewer sonnet)"
  stop_state "$st" ".mode = \"demo\" | .ui = true | .behaviour_change = true | .phases = {AC:{status:\"done\",at:\"2026-09-09T12:00:00Z\",agent:\"a0\"},DR:{status:\"done\",at:\"2026-09-09T12:00:00Z\",agent:\"a0\"},\"TDE-RED\":{status:\"done\",at:\"2026-09-09T12:00:00Z\",agent:\"a0\"},\"TDE-GREEN\":{status:\"done\",at:\"2026-09-09T12:00:00Z\",agent:\"a0\"}} | .active = {a1: $teet_active}" || exit 1
  stop_case "$lo_c" ".seed.state = \"$st\" | .stdin.background_tasks += [{id:\"lo-shell\",type:\"shell\",status:\"running\"}] | .stdin.session_crons = [{id:\"lo-cron\"}]" || exit 1
}

WV_PROJECT="$(mkproj)"
lo_r5_case
lo_shim_on
lo_run subagent-stop.sh
assert_block W-ARTIFACT || fail 'artifact-missing final row (emit failing): the W-ARTIFACT block must still be returned'
lo_no_leftover_in stdout "$WV_LAST_STDOUT"
lo_no_leftover_in stderr "$WV_LAST_STDERR"
[ -e "$(lo_marker)" ] && fail 'non-closing SubagentStop marked the wave warned although the emit failed'
assert_state '.status == "active" and .phases.TEET.status == "artifact-missing"' || fail 'artifact-missing final row must leave the wave active'
lo_checkpoint
lo_contains lo-shell

# Retry on the same, still-active wave (no shim): the warning is delivered
# and only now is the wave marked warned.
lo_r5_case
lo_run subagent-stop.sh
assert_state '.status == "active"' || fail 'retry: the wave must still be active (the retry is on the same wave)'
assert_stderr_contains W-LEFTOVER || fail 'retry: the non-closing SubagentStop did not deliver W-LEFTOVER'
[ -e "$(lo_marker)" ] || fail 'non-closing SubagentStop did not mark the wave warned after a successful emit'

# ---- SubagentStop: same emit-first-mark-second on the closing stop ---------
# The wave closes in the same invocation, so a failed emit cannot retry on
# SubagentStop (wv_state_read refuses a closed wave). The Stop path above
# is the retry proof. This leg only proves the marker is absent when emit
# failed, even though the wave is then closed.
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
lo_sa_case() {
  st="$WV_RUN_TMP/$name-sa-state.json"
  stop_state "$st" ".active = {a1: $(stop_active CL executor sonnet)} | .phases = $(done_except CL)" || exit 1
  stop_case "$lo_c" ".seed.state = \"$st\" | .seed.files += $(stop_findings_zero) | .stdin.background_tasks += [{id:\"lo-shell\",type:\"shell\",status:\"running\"}] | .stdin.session_crons = [{id:\"lo-cron\"}]" || exit 1
}

WV_PROJECT="$(mkproj)"
lo_sa_case
lo_shim_on
lo_run subagent-stop.sh
lo_no_leftover_in stdout "$WV_LAST_STDOUT"
lo_no_leftover_in stderr "$WV_LAST_STDERR"
[ -e "$(lo_marker)" ] && fail 'SubagentStop marked the wave warned although the emit failed'
lo_checkpoint
lo_contains lo-shell

# Success path: a fresh complete-except-CL project, emit allowed, marker written.
WV_PROJECT="$(mkproj)"
lo_sa_case
lo_run subagent-stop.sh
assert_stderr_contains W-LEFTOVER || rc=1
[ -e "$(lo_marker)" ] || fail 'SubagentStop did not mark the wave warned after a successful emit'

exit $rc
