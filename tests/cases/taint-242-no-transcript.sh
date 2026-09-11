#!/usr/bin/env bash
# tests/cases/taint-242-no-transcript.sh — AC-242: no transcript is not taint, and
# the path is NEVER constructed.
#
# Two shapes: `agent_transcript_path` absent from stdin altogether, and a path
# that points at a file which does not exist (the agent's transcript lives under
# the account directory, outside the project, so a stale or moved path is an
# ordinary occurrence). Both: exit 0, no block, the phase judged on its artifact
# alone, tier_verified:false and a ledger line with tier_ok:null and
# note:"no transcript".
#
# AND NEITHER PAYS THE SETTLE CAP (fix round 1, item 8). The bounded settle added
# in Task 13 waits for a transcript to hold a complete assistant turn and stop
# growing; applied to a path that names no file it burned the whole 2.4s cap on
# every stale path and then marked the ledger line transcript_incomplete — saying
# the file was unreadable when the finding is that there is no file. A missing file
# is now answered at the first look. The duration IS the claim here, so it is
# measured and asserted, generously (the cap is 2.4s), and printed either way.
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

lline() { tail -n 1 "$WV_PROJECT/.wave/ledger.jsonl" 2>/dev/null; }

# The settle cap, read out of the script rather than restated, so this case cannot
# drift from the shipped value. An unreadable cap is a failed read, not a licence to
# pick a number.
settle_tries="$(command grep -m1 -oE 'WV_TRANSCRIPT_SETTLE_TRIES="\$\{WV_TRANSCRIPT_SETTLE_TRIES:-[0-9]+' "$WV_REPO_ROOT/scripts/hooks/subagent-stop.sh" | command grep -oE '[0-9]+$')"
settle_ms="$(command grep -m1 -oE 'WV_TRANSCRIPT_SETTLE_MS=[0-9]+' "$WV_REPO_ROOT/scripts/hooks/subagent-stop.sh" | cut -d= -f2)"
case "$settle_tries$settle_ms" in
  ''|*[!0-9]*) fail "could not read the settle cap out of scripts/hooks/subagent-stop.sh (tries='$settle_tries' ms='$settle_ms')"; exit 1 ;;
esac
cap_ms=$(( settle_tries * settle_ms ))

WV_DRIVE_MS=""

drive() {
  WV_PROJECT=""
  local st="$WV_RUN_TMP/$name-$1-state.json" c="$WV_RUN_TMP/$name-$1.json"
  stop_state "$st" ".active = {a1: $(stop_active AC reviewer opus)}" || return 1
  stop_case "$c" "$(printf '.seed.state = "%s" | .seed.files = {".wave/ac.md": "AC-1 records the spend\\n"} | %s' "$st" "$2")" || return 1
  local t0 t1
  t0="$(date +%s%N)"
  run_hook subagent-stop.sh "$c" || { fail "step $1: run_hook: $WV_LAST_STDERR"; return 1; }
  t1="$(date +%s%N)"
  WV_DRIVE_MS=$(( (t1 - t0) / 1000000 ))
  assert_allow || fail "$1: want no block"
  [ "$(stop_phase_status AC)" = "done" ] || fail "$1: status is '$(stop_phase_status AC)', want done"
  printf '%s' "$(lline)" | jq -e '.tier_ok == null and .tier_verified == false and .note == "no transcript"' >/dev/null 2>&1 || \
    fail "$1: ledger line is $(lline), want tier_ok null / tier_verified false / note \"no transcript\""
  printf '%s' "$(lline)" | jq -e '.turns == 0 and .input == 0 and .output == 0' >/dev/null 2>&1 || \
    fail "$1: no transcript means no token sum, got $(lline)"
  printf '%s' "$(lline)" | jq -e 'has("transcript_incomplete") | not' >/dev/null 2>&1 || \
    fail "$1: an ABSENT transcript is not an unreadable one — note:\"no transcript\" already says it, and transcript_incomplete would claim the file could not be read; got $(lline)"
  case "${WV_LAST_STDERR:-}" in
    *'held no complete assistant turn'*)
      fail "$1: the warning claims the file \"held no complete assistant turn\" when there is no file: '${WV_LAST_STDERR}'" ;;
  esac
  return 0
}

drive absent-field '.'
[ -z "${WV_DRIVE_MS:-}" ] || printf 'absent-field: %s ms\n' "$WV_DRIVE_MS"

drive missing-file '.stdin.agent_transcript_path = "/nonexistent/wave-plugin/agent-zz9.jsonl"'
printf 'missing-file: %s ms (the settle cap is %s ms)\n' "${WV_DRIVE_MS:-?}" "$cap_ms"
case "${WV_DRIVE_MS:-}" in
  ''|*[!0-9]*) fail "could not measure the missing-file stop, so the no-burn claim was not checked" ;;
  *) [ "$WV_DRIVE_MS" -lt "$cap_ms" ] || \
       fail "the missing-file stop took ${WV_DRIVE_MS}ms, which is at or past the ${cap_ms}ms settle cap — a path that names no file must not be waited on" ;;
esac

# The tainted flag must be nowhere near this: unverifiable is not taint.
jq -e '(.phases.AC.tainted // false) == false' "$WV_PROJECT/.wave/state.json" >/dev/null 2>&1 || \
  fail "an unverifiable tier must not set tainted"

exit $rc
