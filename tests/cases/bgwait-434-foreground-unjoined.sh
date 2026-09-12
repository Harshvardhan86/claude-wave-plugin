#!/usr/bin/env bash
# Foreground Agent dispatch: SubagentStop arrives before post-agent.sh writes
# state.active. The launch sidecar beside the agent transcript still carries
# the dispatch tag. Models the measured e2e scenario-g sequence.
set -u
source "$(dirname "$0")/../lib/assert.sh"
name="${WV_CASE_NAME:-$(basename "$0" .sh)}"
log="${WV_CASE_LOG:-$WV_RUN_TMP/logs/$name.log}"
rc=0
fail() { printf 'ASSERT FAIL: %s\n' "$*" >&2; rc=1; }
c="$WV_RUN_TMP/$name.json"
base="$WV_TESTS_DIR/cases/bgwait-405-running-block.json"
printf 'RAN subagent-stop.sh %s decision=multi\n' "$name" >> "$log"

# Sidecar keys observed on client 2.1.268 (kept run QjEgXD):
# agentType, description, toolUseId, spawnDepth, requestShape,
# requestNonInteractive, model.
meta='{"agentType":"general-purpose","description":"[W:1 P:AD R:executor] probe","toolUseId":"toolu_0174pCsHeS7EDPoniCitVpsR","spawnDepth":1,"requestShape":"foreground","requestNonInteractive":true,"model":"haiku"}'
unjoined='del(.seed.state)
  | .seed.files[".wave/state.json"] = $st
  | .seed.files[".wave/tr/agent-a1.meta.json"] = $meta
  | .seed.transcripts = {".wave/tr/agent-a1.jsonl": "transcripts/all-haiku.jsonl"}
  | .stdin.agent_transcript_path = ".wave/tr/agent-a1.jsonl"'
mk() {
  jq --rawfile st "$WV_TESTS_DIR/fixtures/state/bgwait-ad-unjoined.json" \
     --arg meta "$meta" "$unjoined | $1" "$base" > "$c" || exit 1
}

WV_PROJECT="$(mkproj)"
mk '.'
run_hook subagent-stop.sh "$c" || fail 'hook run failed'
assert_block W-BGWAIT || rc=1
assert_state '.bg_blocked.a1 == true and .phases == {}' || rc=1
assert_ledger_lines 0 || rc=1

mk 'del(.seed) | .stdin.stop_hook_active = true
    | .stdin.background_tasks |= map(select(.type == "subagent"))'
run_hook subagent-stop.sh "$c" || fail 'hook run failed'
assert_allow || rc=1
assert_state '.phases.AD.status == "done" and .phases.AD.agent == "a1"
              and .active.a1.status == "stopped"
              and .active.a1.phase == "AD"
              and .active.a1.role == "executor"
              and .active.a1.requested_model == "haiku"
              and .rounds["AD/executor"] == 1
              and (.bg_orphaned // {}) == {}' || rc=1
assert_ledger_lines 1 || rc=1
assert_ledger_line '.agent == "a1" and .phase == "AD" and .role == "executor"
                    and .requested == "haiku"' || rc=1

# post-agent.sh after the stop must not reopen a stopped record.
# AD is terminal, so the wave may already be closed; seed a still-active
# copy of the stopped row and run PostToolUse(Agent) against it.
WV_PROJECT="$(mkproj)"
st="$WV_RUN_TMP/$name-stopped.json"
jq '.active.a1 = {phase:"AD",role:"executor",requested_model:"haiku",
    resolved_model:"unknown",tool_use_id:"toolu_01old",
    status:"stopped",stopped:"2026-09-09T12:00:00Z"}' \
  "$WV_TESTS_DIR/fixtures/state/bgwait-ad-unjoined.json" > "$st" || exit 1
jq --arg st "$st" '.script = "post-agent.sh"
    | .seed = {state: $st}
    | .stdin.hook_event_name = "PostToolUse"
    | .stdin.tool_name = "Agent"
    | .stdin.tool_use_id = "toolu_01new"
    | .stdin.tool_input = {description:"[W:1 P:AD R:executor] probe",
        prompt:"done",subagent_type:"general-purpose",model:"haiku"}
    | .stdin.tool_response = {status:"async_launched",agentId:"a1",
        resolvedModel:"claude-haiku-4-5-20251001"}' "$base" > "$c" || exit 1
run_hook post-agent.sh "$c" || fail 'post-agent run failed'
assert_allow || rc=1
assert_state '.active.a1.status == "stopped"
              and .active.a1.stopped == "2026-09-09T12:00:00Z"
              and .active.a1.phase == "AD"
              and .active.a1.resolved_model == "claude-haiku-4-5-20251001"' || rc=1

# Negative control: no sidecar ⇒ today's unjoined warning and unknown phase.
WV_PROJECT="$(mkproj)"
mk 'del(.seed.files[".wave/tr/agent-a1.meta.json"])'
run_hook subagent-stop.sh "$c" || fail 'hook run failed'
assert_block W-BGWAIT || rc=1
mk 'del(.seed) | .stdin.stop_hook_active = true
    | .stdin.background_tasks |= map(select(.type == "subagent"))'
run_hook subagent-stop.sh "$c" || fail 'hook run failed'
assert_allow || rc=1
assert_stderr_contains 'post-agent.sh' || rc=1
assert_state '.phases == {} and .active == {}' || rc=1
assert_ledger_line '.phase == "unknown" and .role == "unknown"' || rc=1

exit $rc
