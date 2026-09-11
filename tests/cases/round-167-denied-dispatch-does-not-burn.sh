#!/usr/bin/env bash
# tests/cases/round-167-denied-dispatch-does-not-burn.sh — AC-167.
#
# `state.rounds` is written by `subagent-stop.sh` when the last concurrent agent
# of a phase+role stops. `pre-agent.sh` only ever READS it, which is what makes
# the ceiling count rounds rather than attempts: a dispatch the hook denied, or
# one the user rejected, never ran an agent and must not burn the allowance.
#
# A JSON case cannot express it — the assertion is about three dispatches
# against ONE project directory, with the state inspected between them. Only the
# first call seeds the state fixture; the two after it deliberately do not, so a
# write by an earlier call would still be on disk when the later assertion runs
# instead of being reseeded away.
set -u

# shellcheck source=tests/lib/assert.sh
source "$(dirname "$0")/../lib/assert.sh"

name="${WV_CASE_NAME:-$(basename "$0" .sh)}"
log="${WV_CASE_LOG:-$WV_RUN_TMP/logs/$name.log}"
rc=0
fail() { printf 'ASSERT FAIL: %s\n' "$*" >&2; rc=1; }

# The run marker is written up front: an early `exit 1` below is still a run
# that happened, and the suite's marker check must not turn it into a second,
# differently-worded failure.
printf 'RAN pre-agent.sh %s decision=multi\n' "$name" >> "$log"

mkcase() {
  # mkcase <file> <description> <model> <seed-state|-> — one dispatch fixture.
  local file="$1" desc="$2" model="$3" seed="$4"
  jq -n --arg d "$desc" --arg m "$model" --arg s "$seed" '
    {
      script: "pre-agent.sh",
      seed: (if $s == "-" then {} else {state: $s} end),
      stdin: {
        session_id: "1a2b0599-4617-4e73-a9c0-2bef462b2626",
        transcript_path: "/tmp/wave-plugin-tests/transcript.jsonl",
        cwd: ".",
        permission_mode: "bypassPermissions",
        hook_event_name: "PreToolUse",
        tool_name: "Agent",
        tool_use_id: "toolu_01RXAwe6jcU5LBKHd9geD6sE",
        tool_input: {
          description: $d,
          prompt: "Do the thing.",
          subagent_type: "general-purpose",
          model: $m
        }
      }
    }' > "$file"
}

rounds_json() {
  jq -c '.rounds // "MISSING"' "$WV_PROJECT/.wave/state.json" 2>/dev/null
}

WV_PROJECT=""

# --- 1. a denied dispatch: the model is below the TDE-GREEN/executor tier ----
c1="$WV_RUN_TMP/$name-1.json"
mkcase "$c1" '[W:1 P:TDE-GREEN R:executor] make the tests pass' haiku state/p2-red.json
run_hook pre-agent.sh "$c1" || { printf 'run_hook failed: %s\n' "$WV_LAST_STDERR" >&2; exit 1; }
assert_deny W-TIER || rc=1
[ "$(rounds_json)" = "{}" ] || fail "after the W-TIER deny, rounds is $(rounds_json), want {}"

# --- 2. a second denied dispatch: BC defines no reviewer --------------------
c2="$WV_RUN_TMP/$name-2.json"
mkcase "$c2" '[W:1 P:BC R:reviewer] review the scan' opus -
run_hook pre-agent.sh "$c2" || { printf 'run_hook failed: %s\n' "$WV_LAST_STDERR" >&2; exit 1; }
assert_deny W-ROLE || rc=1
[ "$(rounds_json)" = "{}" ] || fail "after the W-ROLE deny, rounds is $(rounds_json), want {}"

# --- 3. the valid third dispatch, with the counter still at zero ------------
# Asserted immediately BEFORE the third call, which is the clause AC-167 states.
[ "$(rounds_json)" = "{}" ] || fail "immediately before the third dispatch, rounds is $(rounds_json), want {}"

c3="$WV_RUN_TMP/$name-3.json"
mkcase "$c3" '[W:1 P:TDE-GREEN R:executor] make the tests pass' sonnet -
run_hook pre-agent.sh "$c3" || { printf 'run_hook failed: %s\n' "$WV_LAST_STDERR" >&2; exit 1; }
assert_silent || rc=1
case "$WV_LAST_STDOUT" in
  *W-ROUND*) fail "the third dispatch reported W-ROUND: '$WV_LAST_STDOUT'" ;;
esac
[ "$(rounds_json)" = "{}" ] || fail "after the allowed dispatch, rounds is $(rounds_json), want {} — pre-agent.sh must never write rounds"

exit $rc
