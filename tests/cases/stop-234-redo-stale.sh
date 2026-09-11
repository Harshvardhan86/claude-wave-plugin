#!/usr/bin/env bash
# tests/cases/stop-234-redo-stale.sh — AC-234: a re-run that FAILS must not be
# masked by the earlier success.
#
# AC is already `done` and so are its successors ACB and TDE-RED. A second AC
# reviewer stops with an `ac.md` that no longer matches the marker: the phase
# goes to `redo` (never left at `done`), every successor that was `done` is
# marked `stale:true`, and the next ACB dispatch is denied W-ORDER naming AC.
# That last leg is driven through pre-agent.sh against the SAME project, because
# a status nobody reads is not enforcement.
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

stale() { jq -r --arg c "$1" '(.phases[$c].stale // false) | tostring' "$WV_PROJECT/.wave/state.json"; }

WV_PROJECT="$(mkproj)"
st="$WV_RUN_TMP/$name-state.json"
stop_state "$st" ".active = {a2: $(stop_active AC reviewer opus)}
  | .phases = {AC: {status: \"done\", at: \"2026-09-09T12:10:00Z\", agent: \"a1\"},
               ACB: {status: \"done\", at: \"2026-09-09T12:20:00Z\", agent: \"a9\"},
               \"TDE-RED\": {status: \"done\", at: \"2026-09-09T12:30:00Z\", agent: \"a8\"}}" || exit 1

c="$WV_RUN_TMP/$name-stop.json"
stop_case "$c" "$(printf '.seed.state = "%s" | .stdin.agent_id = "a2" | .seed.files = {".wave/ac.md": "the criteria were moved elsewhere\\n"}' "$st")" || exit 1
run_hook subagent-stop.sh "$c" || { fail "run_hook: $WV_LAST_STDERR"; exit 1; }

assert_block W-MARKER || fail "want block(W-MARKER) on the failed re-run"
[ "$(stop_phase_status AC)" = "redo" ] || \
  fail "phases.AC.status is '$(stop_phase_status AC)', want redo (never left at done)"
[ "$(stale ACB)" = "true" ] || fail "ACB was done and must now carry stale:true"
[ "$(stale TDE-RED)" = "true" ] || fail "TDE-RED was done and must now carry stale:true"
[ "$(stop_ledger_count)" = "1" ] || fail "the ledger line is still appended, got $(stop_ledger_count)"

# The consequence: ACB is no longer dispatchable, and the deny names AC.
pc="$WV_RUN_TMP/$name-acb-dispatch.json"
jq -n '{
  script: "pre-agent.sh",
  stdin: {
    session_id: "1a2b0599-4617-4e73-a9c0-2bef462b2626",
    transcript_path: "/tmp/wave-plugin-tests/transcript.jsonl",
    cwd: ".", permission_mode: "bypassPermissions",
    hook_event_name: "PreToolUse", tool_name: "Agent",
    tool_use_id: "toolu_01RXAwe6jcU5LBKHd9geD6sE",
    tool_input: {description: "[W:1 P:ACB R:lead] harden the criteria",
                 prompt: "Do the thing.", subagent_type: "general-purpose", model: "opus"}
  }
}' > "$pc"
run_hook pre-agent.sh "$pc" || { fail "pre-agent run_hook: $WV_LAST_STDERR"; exit 1; }
assert_deny W-ORDER || fail "the next ACB dispatch must deny W-ORDER"
assert_reason_contains 'AC' || fail "the W-ORDER reason must name AC"

exit $rc
