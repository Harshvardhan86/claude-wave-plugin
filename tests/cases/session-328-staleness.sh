#!/usr/bin/env bash
# tests/cases/session-328-staleness.sh - AC-328.
#
# `started` is a fixed ISO-8601 timestamp in state.json, so the 24h
# staleness check has to be exercised against wall-clock "now" - a 25h-old
# `started` warns and names scripts/wave-close.sh; a 2h-old one does not.
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
case "$SS_OUT" in
  *'over 24 hours'*'wave-close.sh'*) : ;;
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
