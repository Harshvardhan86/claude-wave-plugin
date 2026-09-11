#!/usr/bin/env bash
# tests/cases/stopcard-324-solo-prints-once.sh - AC-324.
#
# mode:solo has no terminal phase at all (phases.tsv is never consulted in
# solo), so a non-empty ledger IS the signal to print the scorecard pointer.
# It still prints only once: a second Stop in the same wave is silent.
set -u
# shellcheck source=../lib/assert.sh
source "$(dirname "$0")/../lib/assert.sh"

name="$(basename "$0" .sh)"
log="${WV_CASE_LOG:-$WV_RUN_TMP/logs/$name.log}"
mkdir -p "$(dirname "$log")"
rc=0
fail() { printf 'ASSERT FAIL: %s\n' "$*" >&2; rc=1; }

WV_PROJECT="$(mkproj)"
seed_state state/solo.json
printf '{"agent":"a1","phase":"AC","role":"lead","output":50}\n' > "$WV_PROJECT/.wave/ledger.jsonl"

run_stop() {
  STOP_OUT="$(cd "$WV_PROJECT" && printf '%s' '{"hook_event_name":"Stop"}' | \
    bash "$WV_REPO_ROOT/scripts/hooks/stop.sh")"
  STOP_EXIT=$?
}

run_stop
printf 'RAN stop.sh %s decision=solofirst\n' "$name" >> "$log"
[ "$STOP_EXIT" = "0" ] || fail "first stop: exit $STOP_EXIT"
case "$STOP_OUT" in
  *'W-SCORECARD'*) : ;;
  *) fail "first stop: expected the scorecard pointer, got: $STOP_OUT" ;;
esac
[ -f "$WV_PROJECT/.wave/.scorecard-printed" ] || fail "the scorecard-printed marker was not written"

run_stop
printf 'RAN stop.sh %s decision=solosecond\n' "$name" >> "$log"
[ "$STOP_EXIT" = "0" ] || fail "second stop: exit $STOP_EXIT"
[ -z "$STOP_OUT" ] || fail "second stop: expected silence, got: $STOP_OUT"

exit $rc
