#!/usr/bin/env bash
# complete-ad-no-close.sh — an AD stop never closes a wave, not even one
# whose phase rows are already all settled.
#
# AD is an `anytime` row. The completeness walk leaves anytime rows out, so
# the close trigger must also require the TRIGGERING row to be a
# `when=phase` row: otherwise an AD stop on a complete-but-still-active wave
# (reachable after a failed closer, or after a scope change skipped the
# remaining rows) closes it, writes a delivery verdict and fires the
# close-time warnings and their markers.
#
# Negative control: full-all-done (every phase row settled, every scan
# FINDINGS: 0), wave still active, an AD executor stops -> AD is recorded
# done, the wave stays active, no ended, no delivery, no close-time marker,
# and nothing announces a close. Positive control on the same seed with CCP
# removed: the CCP stop closes it, so this instrument can see a close.
set -u
source "$(dirname "$0")/../lib/assert.sh"
source "$(dirname "$0")/../lib/stop.sh"
name="${WV_CASE_NAME:-$(basename "$0" .sh)}"
log="${WV_CASE_LOG:-$WV_RUN_TMP/logs/$name.log}"
rc=0
fail() { printf 'ASSERT FAIL: %s\n' "$*" >&2; rc=1; }
printf 'RAN subagent-stop.sh %s decision=multi\n' "$name" >> "$log"

full="$WV_TESTS_DIR/fixtures/state/full-all-done.json"
st="$WV_RUN_TMP/$name-state.json"
c="$WV_RUN_TMP/$name.json"

stop_on() {
  # stop_on <phase> <model> <jq filter over full-all-done's phases>
  WV_PROJECT=""
  jq --argjson act "$(stop_active "$1" executor "$2")" ".active = {a1: \$act} | .phases |= ($3)" "$full" > "$st" || return 1
  stop_case "$c" "$(printf '.seed.state = "%s" | .seed.files = {".wave/checkpoints/1-ccp.md": "ccp\\n", ".wave/ledger.jsonl": ""}' "$st") | .seed.files += $(stop_findings_zero)" || return 1
  run_hook subagent-stop.sh "$c" || { fail "$1: run_hook: $WV_LAST_STDERR"; return 1; }
}

# ---- negative control: AD on a complete, active wave ------------------------
if stop_on AD haiku 'del(.AD)'; then
  assert_allow || fail "AD: want no block"
  [ -z "$WV_LAST_STDOUT" ] || fail "AD: stdout must be empty, got '$WV_LAST_STDOUT'"
  [ "$(stop_phase_status AD)" = "done" ] || fail "AD: status is '$(stop_phase_status AD)', want done"
  s="$WV_PROJECT/.wave/state.json"
  [ "$(jq -r '.status' "$s")" = "active" ] || fail "AD: an AD stop closed a complete wave (status '$(jq -r '.status' "$s")'); only a when=phase row may trigger the close"
  [ "$(jq -r '(.ended // "null")' "$s")" = "null" ] || fail "AD: .ended must stay null"
  [ "$(jq -r '(.delivery // "unset")' "$s")" = "unset" ] || fail "AD: no delivery verdict may be written by an AD stop"
  for m in .leftover-warned .undelivered-warned .scorecard-printed; do
    [ ! -e "$WV_PROJECT/.wave/$m" ] || fail "AD: close-time marker $m was written"
  done
  case "$WV_LAST_STDERR" in
    *W-SCORECARD*|*W-UNDELIVERED*|*W-LEFTOVER*) fail "AD: close-time warnings were announced: $WV_LAST_STDERR" ;;
  esac
fi

# ---- positive control: a phase row's stop on the same seed closes ----------
if stop_on CCP sonnet 'del(.CCP)'; then
  [ "$(stop_phase_status CCP)" = "done" ] || fail "CCP: status is '$(stop_phase_status CCP)', want done"
  [ "$(jq -r '.status' "$WV_PROJECT/.wave/state.json")" = "closed" ] || fail "control: the CCP stop must close this wave, else the AD leg proves nothing"
fi

exit $rc
