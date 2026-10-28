#!/usr/bin/env bash
# complete-stale-gate-agreement.sh — completeness treats a row
# that is `done` with `stale: true` exactly as the order gate does.
#
# The gate (pre-agent.sh wv_phase_done) answers "done" from `.status` alone
# and never reads `stale`, so a done-but-stale predecessor does not hold a
# dispatch. Proved both ways on the same state: with BTEET-X done+stale a CCP
# dispatch is NOT refused W-ORDER; with BTEET-X absent it IS (the control
# that shows this instrument can fail). complete-wave-complete's
# "done-and-stale" leg proves wv_wave_complete reads it the same way.
set -u
source "$(dirname "$0")/../lib/assert.sh"
name="${WV_CASE_NAME:-$(basename "$0" .sh)}"
log="${WV_CASE_LOG:-$WV_RUN_TMP/logs/$name.log}"
rc=0
fail() { printf 'ASSERT FAIL: %s\n' "$*" >&2; rc=1; }
source "$WV_TESTS_DIR/lib/stop.sh"

ALWAYS="AC ACB TDE-RED TDE-GREEN BC SEA DS BSEA OA TEET-TC TEET BTEET BTEET-X VB COMMIT CL"

phases_json() {
  # phases_json <extra jq filter over the map>
  printf '%s\n' $ALWAYS | jq -R . | jq -s "map({(.): {status:\"done\", at:\"2026-09-09T12:10:00Z\", agent:\"a0\"}}) | add | $1"
}

dispatch() {
  # dispatch <phases jq filter> -> runs a CCP executor dispatch against it.
  WV_PROJECT=""
  local st="$WV_RUN_TMP/$name-state.json" c="$WV_RUN_TMP/$name.json"
  stop_state "$st" ".ui = false | .behaviour_change = false | .cr_enabled = false | .vocabulary = false | .phases = $(phases_json "$1")" || return 1
  jq -n --arg st "$st" --argjson files "$(stop_findings_zero)" '{
    script: "pre-agent.sh",
    seed: {state: $st, files: $files},
    stdin: {
      session_id: "1a2b0599-4617-4e73-a9c0-2bef462b2626",
      transcript_path: "/tmp/wave-plugin-tests/transcript.jsonl",
      cwd: ".",
      prompt_id: "c1f033ea-e4ee-4474-88ec-3913700ae39d",
      permission_mode: "bypassPermissions",
      hook_event_name: "PreToolUse",
      tool_name: "Agent",
      tool_use_id: "toolu_01RXAwe6jcU5LBKHd9geD6sE",
      tool_input: {
        description: "[W:1 P:CCP R:executor] write the checkpoint",
        prompt: "Do the thing.",
        subagent_type: "general-purpose",
        model: "sonnet"
      }
    }
  }' > "$c" || return 1
  run_hook pre-agent.sh "$c" || { fail "run_hook: $WV_LAST_STDERR"; return 1; }
}

# Done + stale predecessor: the gate does not refuse on order.
dispatch '.["BTEET-X"].stale = true'
case "$WV_LAST_STDOUT" in
  *W-ORDER*) fail "BTEET-X done+stale: the gate refused W-ORDER, so it reads stale as not done: '$WV_LAST_STDOUT'" ;;
esac
case "$WV_LAST_STDOUT" in
  *'"permissionDecision":"deny"'*) fail "BTEET-X done+stale: CCP dispatch denied: '$WV_LAST_STDOUT'" ;;
esac

# Control: the predecessor absent, same everything else -> W-ORDER.
dispatch 'del(.["BTEET-X"])'
assert_deny W-ORDER || fail "control: BTEET-X absent must be refused W-ORDER (else the leg above proves nothing)"

exit $rc
