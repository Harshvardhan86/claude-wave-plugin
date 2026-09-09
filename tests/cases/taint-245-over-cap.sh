#!/usr/bin/env bash
# tests/cases/taint-245-over-cap.sh — AC-245: above the stated transcript byte cap
# the token sum is skipped with note:"transcript too large", the phase is still
# judged on its artifact and marker, and nothing blocks.
#
# The cap is READ OUT OF THE SCRIPT rather than restated here, so the case cannot
# drift from the shipped value, and the read is asserted to have produced a
# number — an absent cap is a failed scan, not a licence to skip the case. The
# at-cap step is the boundary negative control: a file of exactly the cap must
# still be read.
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

cap="$(command grep -m1 -oE 'WV_TRANSCRIPT_CAP=[0-9]+' "$WV_REPO_ROOT/scripts/hooks/subagent-stop.sh" 2>/dev/null | cut -d= -f2)"
case "$cap" in
  ''|*[!0-9]*) fail "could not read WV_TRANSCRIPT_CAP out of scripts/hooks/subagent-stop.sh (got '$cap')"; exit 1 ;;
esac
printf 'measured cap: %s bytes\n' "$cap"

drive() {
  # drive <step> <size in bytes> — a sparse file of exactly <size>, whose first
  # line is a valid assistant turn.
  WV_PROJECT="$(mkproj)"
  local st="$WV_RUN_TMP/$name-$1-state.json" c="$WV_RUN_TMP/$name-$1.json"
  local tr="$WV_PROJECT/.wave/tr/a1.jsonl"
  mkdir -p "$WV_PROJECT/.wave/tr" || return 1
  printf '%s\n' '{"type":"assistant","message":{"model":"claude-opus-5","usage":{"input_tokens":7,"output_tokens":9}}}' > "$tr"
  truncate -s "$2" "$tr" || { fail "step $1: truncate failed"; return 1; }
  [ "$(stat -c %s "$tr")" = "$2" ] || { fail "step $1: planted size is $(stat -c %s "$tr"), want $2"; return 1; }
  stop_state "$st" ".active = {a1: $(stop_active AC reviewer opus)}" || return 1
  stop_case "$c" "$(printf '.seed.state = "%s" | .seed.files = {".wave/ac.md": "AC-1 records the spend\\n"} | .stdin.agent_transcript_path = ".wave/tr/a1.jsonl"' "$st")" || return 1
  run_hook subagent-stop.sh "$c" || { fail "step $1: run_hook: $WV_LAST_STDERR"; return 1; }
  return 0
}

if drive over "$((cap + 1))"; then
  assert_allow || fail "over cap: want no block"
  [ "$(stop_phase_status AC)" = "done" ] || \
    fail "over cap: the phase is still judged on artifact and marker, got '$(stop_phase_status AC)'"
  printf '%s' "$(lline)" | jq -e '.note == "transcript too large" and .turns == 0 and .input == 0 and .output == 0 and .tier_ok == null' >/dev/null 2>&1 || \
    fail "over cap: ledger line is $(lline), want note \"transcript too large\" and no token sum"
fi

if drive at "$cap"; then
  assert_allow || fail "at cap: want no block"
  printf '%s' "$(lline)" | jq -e '.note != "transcript too large" and .turns == 1 and .input == 7 and .output == 9' >/dev/null 2>&1 || \
    fail "at cap: a file of exactly the cap must still be read, got $(lline)"
fi

exit $rc
