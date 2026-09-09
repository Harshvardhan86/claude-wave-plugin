#!/usr/bin/env bash
# tests/cases/round-168-pdt-fanout-three-allow.sh — the dispatch half of AC-168.
#
# `TEET-TC` has `fanout` 3, and the framework's PDT fan-out launches all three
# writers before any of them stops. Spec section 8.7 counts ROUNDS, not
# dispatches, so all three must be allowed at dispatch time and none of them may
# move the counter — `subagent-stop.sh` increments it once, when the last of the
# three stops.
#
# The stop half of AC-168 (`state.rounds["TEET-TC/writer"] == 1` afterwards, and
# the seventh dispatch denied) belongs to the task that writes `rounds`; this
# case pins the half `pre-agent.sh` owns, which is the half that would falsely
# deny a legitimate fan-out. Only the first call seeds the state, so a write by
# any of the three would still be on disk for the final assertion.
set -u

# shellcheck source=tests/lib/assert.sh
source "$(dirname "$0")/../lib/assert.sh"

name="${WV_CASE_NAME:-$(basename "$0" .sh)}"
log="${WV_CASE_LOG:-$WV_RUN_TMP/logs/$name.log}"
rc=0
fail() { printf 'ASSERT FAIL: %s\n' "$*" >&2; rc=1; }

printf 'RAN pre-agent.sh %s decision=multi\n' "$name" >> "$log"

mkcase() {
  # mkcase <file> <seed-state|-> — one of the three concurrent writer dispatches.
  local file="$1" seed="$2"
  jq -n --arg s "$seed" '
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
          description: "[W:1 P:TEET-TC R:writer] write the true-end-to-end cases",
          prompt: "Do the thing.",
          subagent_type: "general-purpose",
          model: "sonnet"
        }
      }
    }' > "$file"
}

rounds_json() {
  jq -c '.rounds // "MISSING"' "$WV_PROJECT/.wave/state.json" 2>/dev/null
}

WV_PROJECT=""
i=0
for seed in state/p2-oa.json - -; do
  i=$((i + 1))
  c="$WV_RUN_TMP/$name-$i.json"
  mkcase "$c" "$seed"
  run_hook pre-agent.sh "$c" || { printf 'run_hook failed: %s\n' "$WV_LAST_STDERR" >&2; exit 1; }
  assert_silent || fail "concurrent PDT writer $i of 3 was not a silent allow"
  case "$WV_LAST_STDOUT" in
    *W-ROUND*) fail "PDT writer $i of 3 reported W-ROUND: '$WV_LAST_STDOUT'" ;;
  esac
done

[ "$i" = "3" ] || fail "expected 3 dispatches, drove $i"
[ "$(rounds_json)" = "{}" ] || \
  fail "after three concurrent dispatches rounds is $(rounds_json), want {} — pre-agent.sh must never write rounds"

exit $rc
