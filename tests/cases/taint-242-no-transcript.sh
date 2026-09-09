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

drive() {
  WV_PROJECT=""
  local st="$WV_RUN_TMP/$name-$1-state.json" c="$WV_RUN_TMP/$name-$1.json"
  stop_state "$st" ".active = {a1: $(stop_active AC reviewer opus)}" || return 1
  stop_case "$c" "$(printf '.seed.state = "%s" | .seed.files = {".wave/ac.md": "AC-1 records the spend\\n"} | %s' "$st" "$2")" || return 1
  run_hook subagent-stop.sh "$c" || { fail "step $1: run_hook: $WV_LAST_STDERR"; return 1; }
  assert_allow || fail "$1: want no block"
  [ "$(stop_phase_status AC)" = "done" ] || fail "$1: status is '$(stop_phase_status AC)', want done"
  printf '%s' "$(lline)" | jq -e '.tier_ok == null and .tier_verified == false and .note == "no transcript"' >/dev/null 2>&1 || \
    fail "$1: ledger line is $(lline), want tier_ok null / tier_verified false / note \"no transcript\""
  printf '%s' "$(lline)" | jq -e '.turns == 0 and .input == 0 and .output == 0' >/dev/null 2>&1 || \
    fail "$1: no transcript means no token sum, got $(lline)"
  return 0
}

drive absent-field '.'
drive missing-file '.stdin.agent_transcript_path = "/nonexistent/wave-plugin/agent-zz9.jsonl"'

# The tainted flag must be nowhere near this: unverifiable is not taint.
jq -e '(.phases.AC.tainted // false) == false' "$WV_PROJECT/.wave/state.json" >/dev/null 2>&1 || \
  fail "an unverifiable tier must not set tainted"

exit $rc
