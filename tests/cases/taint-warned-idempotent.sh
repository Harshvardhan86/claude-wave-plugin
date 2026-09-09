#!/usr/bin/env bash
# tests/cases/taint-warned-idempotent.sh — fix round 1, item 3.
#
# A stop that carries a warning is not exempt from idempotence. Replaying a
# TAINTED stop used to append the same rendered W-TAINT text to
# `phases[<PHASE>].warned` on every pass (1 -> 2 -> 3 entries, and a different
# state.json sha each time), because the "same verdict, same agent -> skip the
# write" fast path refused to fire whenever a warning was queued.
#
# The warn list is a SET: an entry already recorded is not recorded again, and a
# replay of a settled stop leaves state.json byte-identical.
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

warned_count() { jq -r '(.phases.AC.warned // []) | length' "$WV_PROJECT/.wave/state.json"; }

WV_PROJECT="$(mkproj)"
st="$WV_RUN_TMP/$name-state.json"
stop_state "$st" ".active = {a1: $(stop_active AC reviewer opus)}" || exit 1
mkdir -p "$WV_PROJECT/.wave/tr"
cp "$WV_TESTS_DIR/fixtures/transcripts/all-opus.jsonl" "$WV_PROJECT/.wave/tr/a1.jsonl" || exit 1

# Leg 1: a1 stops on an all-opus transcript. Clean, so nothing is warned.
c="$WV_RUN_TMP/$name-1.json"
stop_case "$c" "$(printf '.seed.state = "%s" | .seed.files = {".wave/ac.md": "AC-1 records the spend\\n"} | .stdin.agent_transcript_path = ".wave/tr/a1.jsonl"' "$st")" || exit 1
run_hook subagent-stop.sh "$c" || { fail "leg 1: $WV_LAST_STDERR"; exit 1; }
assert_allow || fail "leg 1: want no block"
[ "$(stop_phase_status AC)" = "done" ] || fail "leg 1: status is '$(stop_phase_status AC)', want done"
[ "$(warned_count)" = "0" ] || fail "leg 1: warned has $(warned_count) entry(ies), want none"

# Leg 2: the SAME agent stops again, and this time its transcript is all haiku.
# The status does not change and neither does the agent — the two halves of the
# "nothing to write" fast path — but there IS now a warning to record, and a fast
# path that ignored that would drop it on the floor.
cp "$WV_TESTS_DIR/fixtures/transcripts/all-haiku.jsonl" "$WV_PROJECT/.wave/tr/a1.jsonl" || exit 1
c2="$WV_RUN_TMP/$name-2.json"
stop_case "$c2" '.stdin.agent_transcript_path = ".wave/tr/a1.jsonl"' || exit 1
run_hook subagent-stop.sh "$c2" || { fail "leg 2: $WV_LAST_STDERR"; exit 1; }
assert_allow || fail "leg 2: a taint never blocks"
[ "$(stop_phase_status AC)" = "done" ] || fail "leg 2: status is '$(stop_phase_status AC)', want done"
[ "$(jq -r '(.phases.AC.tainted // false) | tostring' "$WV_PROJECT/.wave/state.json")" = "true" ] || \
  fail "leg 2: tainted must be recorded"
[ "$(warned_count)" = "1" ] || fail "leg 2: warned has $(warned_count) entry(ies), want 1"

before="$(sha256sum < "$WV_PROJECT/.wave/state.json" | cut -d' ' -f1)"

# Legs 3 and 4: replays of that settled tainted stop. Nothing may move.
i=3
while [ "$i" -le 4 ]; do
  run_hook subagent-stop.sh "$c2" || { fail "leg $i: $WV_LAST_STDERR"; exit 1; }
  assert_allow || fail "leg $i: want no block"
  [ "$(warned_count)" = "1" ] || \
    fail "leg $i: warned has $(warned_count) entry(ies), want 1 — the warn list is a set"
  [ "$(sha256sum < "$WV_PROJECT/.wave/state.json" | cut -d' ' -f1)" = "$before" ] || \
    fail "leg $i: state.json changed on a replay of a settled tainted stop"
  [ "$(stop_ledger_count)" = "1" ] || fail "leg $i: ledger has $(stop_ledger_count) line(s), want 1"
  i=$((i + 1))
done

# Leg 5: a SECOND agent of the same phase, equally tainted. Its record IS written
# (the agent changed), and it renders the same warning text a1 already recorded —
# so this is where a merge that appends instead of unioning shows up as a
# duplicate.
cp "$WV_TESTS_DIR/fixtures/transcripts/all-haiku.jsonl" "$WV_PROJECT/.wave/tr/a2.jsonl" || exit 1
# Launched into the LIVE state, after a1 has finished: launching it up front would
# leave a1 skipping its own check because a sibling was still running.
jq ".active.a2 = $(stop_active AC reviewer opus)" "$WV_PROJECT/.wave/state.json" \
  > "$WV_RUN_TMP/$name-live.json" && mv "$WV_RUN_TMP/$name-live.json" "$WV_PROJECT/.wave/state.json" || exit 1
c3="$WV_RUN_TMP/$name-3.json"
stop_case "$c3" '.stdin.agent_id = "a2" | .stdin.agent_transcript_path = ".wave/tr/a2.jsonl"' || exit 1
run_hook subagent-stop.sh "$c3" || { fail "leg 5: $WV_LAST_STDERR"; exit 1; }
assert_allow || fail "leg 5: want no block"
[ "$(jq -r '.phases.AC.agent' "$WV_PROJECT/.wave/state.json")" = "a2" ] || \
  fail "leg 5: the phase record must name the agent that just stopped"
[ "$(warned_count)" = "1" ] || \
  fail "leg 5: warned has $(warned_count) entry(ies), want 1 — the same warning text is not recorded twice"
[ "$(stop_ledger_count)" = "2" ] || fail "leg 5: ledger has $(stop_ledger_count) line(s), want 2"

exit $rc
