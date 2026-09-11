#!/usr/bin/env bash
# tests/cases/ledger-236-dedupe-three-replays.sh — AC-236: the ledger holds one
# line per `agent_id`. Replaying the identical stop three times (all with
# stop_hook_active:false, i.e. three genuine first-looking stops) leaves exactly
# one line and does not move the phase status a second time — a duplicate
# agent_id is the tell of a lost lock, so it must be impossible to produce by
# replay.
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
stop_state "$st" ".active = {a1: $(stop_active AC reviewer opus)}" || exit 1

c="$WV_RUN_TMP/$name-1.json"
stop_case "$c" "$(printf '.seed.state = "%s" | .seed.files = {".wave/ac.md": "AC-1 records the spend\\n"}' "$st")" || exit 1
run_hook subagent-stop.sh "$c" || { fail "run 1: $WV_LAST_STDERR"; exit 1; }
assert_allow || fail "run 1: want no block"
[ "$(stop_ledger_count)" = "1" ] || fail "run 1: ledger has $(stop_ledger_count) line(s), want 1"
first_at="$(jq -r '.phases.AC.at' "$WV_PROJECT/.wave/state.json")"

# Runs 2 and 3 replay the same agent. No seed: the live state is the point.
c2="$WV_RUN_TMP/$name-2.json"
stop_case "$c2" '.' || exit 1
i=2
while [ "$i" -le 3 ]; do
  run_hook subagent-stop.sh "$c2" || { fail "run $i: $WV_LAST_STDERR"; exit 1; }
  assert_allow || fail "run $i: want no block"
  [ "$(stop_ledger_count)" = "1" ] || \
    fail "run $i: ledger has $(stop_ledger_count) line(s), want 1 — the dedupe key is agent_id"
  [ "$(stop_phase_status AC)" = "done" ] || fail "run $i: AC status changed to '$(stop_phase_status AC)'"
  [ "$(jq -r '.phases.AC.at' "$WV_PROJECT/.wave/state.json")" = "$first_at" ] || \
    fail "run $i: phases.AC.at was rewritten; a replay must not touch the record"
  i=$((i + 1))
done

exit $rc
