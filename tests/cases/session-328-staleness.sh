#!/usr/bin/env bash
# tests/cases/session-328-staleness.sh - AC-328.
#
# `started` is an ISO-8601 timestamp in state.json and the check compares it with
# lib.sh's wv_now_epoch. This case derives BOTH its timestamps from the same clock
# the hook reads, so the two move together and the case cannot rot: a 25h-old
# `started` warns and names scripts/wave-close.sh, a 2h-old one does not, whenever
# it is run. It deliberately does NOT pin WV_NOW — pinning both sides would make
# this a test of arithmetic rather than of the clock the hook actually reads, and
# the JSON cases that DO pin it (the harness pins one instant for every case that
# goes through run_hook) cover the deterministic half.
set -u
# shellcheck source=../lib/assert.sh
source "$(dirname "$0")/../lib/assert.sh"

name="$(basename "$0" .sh)"
log="${WV_CASE_LOG:-$WV_RUN_TMP/logs/$name.log}"
mkdir -p "$(dirname "$log")"
rc=0
fail() { printf 'ASSERT FAIL: %s\n' "$*" >&2; rc=1; }

run_session_start() {
  # run_session_start <started-iso> -> sets SS_OUT / SS_EXIT.
  local started="$1" proj
  proj="$(mkproj)"
  mkdir -p "$proj/.wave"
  jq --arg s "$started" '.started = $s' "$WV_TESTS_DIR/fixtures/state/full-ac-done.json" \
    > "$proj/.wave/state.json"
  : > "$proj/.wave/lock"
  SS_OUT="$(cd "$proj" && printf '%s' '{"hook_event_name":"SessionStart","source":"startup"}' | \
    bash "$WV_REPO_ROOT/scripts/hooks/session-start.sh")"
  SS_EXIT=$?
}

# ---- 25 hours old: stale, warns ------------------------------------------
stale_started="$(date -u -d '25 hours ago' +%Y-%m-%dT%H:%M:%SZ)"
run_session_start "$stale_started"
printf 'RAN session-start.sh %s decision=stale25h\n' "$name" >> "$log"
[ "$SS_EXIT" = "0" ] || fail "stale case: exit $SS_EXIT"
# The clause was shortened in fix round 1 so the whole banner fits the reason
# corpus's 400-character bound with both advisory clauses on at once; what it must
# still do is say the wave is over 24h old and name the script that closes it.
case "$SS_OUT" in
  *'>24h'*'wave-close.sh'*) : ;;
  *) fail "stale case: expected a staleness sentence naming wave-close.sh, got: $SS_OUT" ;;
esac

# ---- 2 hours old: fresh, silent on staleness ------------------------------
fresh_started="$(date -u -d '2 hours ago' +%Y-%m-%dT%H:%M:%SZ)"
run_session_start "$fresh_started"
printf 'RAN session-start.sh %s decision=fresh2h\n' "$name" >> "$log"
[ "$SS_EXIT" = "0" ] || fail "fresh case: exit $SS_EXIT"
case "$SS_OUT" in
  *'wave-close.sh'*) fail "fresh case: must not carry the staleness sentence, got: $SS_OUT" ;;
  *) : ;;
esac
case "$SS_OUT" in
  *'W-SESSION'*) : ;;
  *) fail "fresh case: expected the ordinary W-SESSION banner, got: $SS_OUT" ;;
esac

exit $rc
