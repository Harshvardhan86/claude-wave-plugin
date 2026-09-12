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
stfile="$WV_TESTS_DIR/fixtures/state/bgwait-ad-unjoined.json"
mk() {
  jq --rawfile st "$stfile" --arg meta "$meta" "$unjoined | $1" "$base" > "$c" || exit 1
}

# Same bound tests/tools/reason-corpus.sh enforces, read out of that file
# rather than restated, so the two cannot drift.
cap="$(command grep -m1 -oE 'WV_MAX_REASON=[0-9]+' "$WV_REPO_ROOT/tests/tools/reason-corpus.sh" | cut -d= -f2)"
case "$cap" in
  ''|*[!0-9]*) fail "could not read WV_MAX_REASON out of tests/tools/reason-corpus.sh (got '$cap')"; exit 1 ;;
esac

wstate_line() {
  # The W-STATE warning on SubagentStop is flushed to stderr ahead of the
  # block object (that event has no additionalContext channel).
  printf '%s\n' "${WV_LAST_STDERR:-}" | command grep -F '[W-STATE]' | head -n1
}

WV_PROJECT="$(mkproj)"
mk '.'
run_hook subagent-stop.sh "$c" || fail 'hook run failed'
assert_block W-BGWAIT || rc=1
# Recovery writes the stop record and the round at the blocked first stop,
# the same as a joined launch. Pin both so a later change cannot move the
# round to stop #2 or double it.
assert_state '.bg_blocked.a1 == true and .phases == {}
              and .active.a1.status == "stopped"
              and .rounds["AD/executor"] == 1' || rc=1
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
                    and .requested == "haiku" and .tier_ok == true' || rc=1

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
stfile="$WV_TESTS_DIR/fixtures/state/bgwait-ad-unjoined.json"
mk 'del(.seed.files[".wave/tr/agent-a1.meta.json"])'
run_hook subagent-stop.sh "$c" || fail 'hook run failed'
assert_block W-BGWAIT || rc=1
mk 'del(.seed) | .stdin.stop_hook_active = true
    | .stdin.background_tasks |= map(select(.type == "subagent"))'
run_hook subagent-stop.sh "$c" || fail 'hook run failed'
assert_allow || rc=1
assert_stderr_contains 'found no state.active record to join' || rc=1
assert_state '.phases == {} and .active == {}' || rc=1
assert_ledger_line '.phase == "unknown" and .role == "unknown"' || rc=1

# I1: stale sidecar from wave 1, current wave is 2. Fail closed like no sidecar.
WV_PROJECT="$(mkproj)"
stale="$WV_RUN_TMP/$name-wave2.json"
jq '.wave = "2"' "$WV_TESTS_DIR/fixtures/state/bgwait-ad-unjoined.json" > "$stale" || exit 1
stfile="$stale"
mk '.'
run_hook subagent-stop.sh "$c" || fail 'hook run failed'
assert_block W-BGWAIT || rc=1
mk 'del(.seed) | .stdin.stop_hook_active = true
    | .stdin.background_tasks |= map(select(.type == "subagent"))'
run_hook subagent-stop.sh "$c" || fail 'hook run failed'
assert_allow || rc=1
assert_stderr_contains 'found no state.active record to join' || rc=1
assert_state '.phases == {} and .active == {}' || rc=1
assert_ledger_line '.phase == "unknown" and .role == "unknown"' || rc=1

# I1 under enforce:warn: post-agent.sh would have written phase untagged /
# role unknown (AC-200), not the stale tag's AD/executor.
WV_PROJECT="$(mkproj)"
warnst="$WV_RUN_TMP/$name-wave2-warn.json"
jq '.wave = "2" | .enforce = "warn"' \
  "$WV_TESTS_DIR/fixtures/state/bgwait-ad-unjoined.json" > "$warnst" || exit 1
stfile="$warnst"
mk '.'
run_hook subagent-stop.sh "$c" || fail 'hook run failed'
assert_allow || rc=1
assert_state '((.phases.AD // null) == null)
              and .active.a1.phase == "untagged"
              and .active.a1.role == "unknown"' || rc=1
assert_ledger_line '.phase == "untagged" and .role == "unknown"' || rc=1

# I2: recovered W-STATE stays under the declared ceiling with a real
# out-of-root sidecar path (wv_rel leaves a path outside the project unchanged).
WV_PROJECT="$(mkproj)"
stfile="$WV_TESTS_DIR/fixtures/state/bgwait-ad-unjoined.json"
sidecar_dir="$WV_RUN_TMP/claude-accounts/proharsh/projects/-tmp-wave-plugin-e2e-scenario-I2/49194d68-d614-4504-8f34-520d3adeb949/subagents"
mkdir -p "$sidecar_dir"
printf '%s' "$meta" > "$sidecar_dir/agent-a1.meta.json"
cp "$WV_TESTS_DIR/fixtures/transcripts/all-haiku.jsonl" "$sidecar_dir/agent-a1.jsonl" || exit 1
trpath="$sidecar_dir/agent-a1.jsonl"
mk 'del(.seed.files[".wave/tr/agent-a1.meta.json"])'
jq --arg tr "$trpath" '.stdin.agent_transcript_path = $tr' "$c" > "$c.i2" && mv "$c.i2" "$c"
run_hook subagent-stop.sh "$c" || fail 'hook run failed'
assert_block W-BGWAIT || rc=1
assert_state '.active.a1.status == "stopped" and .active.a1.phase == "AD"' || rc=1
wstate="$(wstate_line)"
[ -n "$wstate" ] || { fail "I2: no W-STATE line on stderr"; wstate=""; }
wlen="$(jq -n --arg t "$wstate" '$t | length')"
case "$wlen" in
  ''|*[!0-9]*) fail "I2: could not measure W-STATE length (got '$wlen')" ;;
  *)
    [ "$wlen" -le "$cap" ] || \
      fail "I2: recovered W-STATE is $wlen characters, over the $cap bound: $wstate"
    ;;
esac
case "$wstate" in
  *'the launch sidecar beside the agent transcript'*) : ;;
  *) fail "I2: recovered W-STATE must name the sidecar without its path: $wstate" ;;
esac
case "$wstate" in
  *'claude-accounts'*|*"$sidecar_dir"*)
    fail "I2: recovered W-STATE interpolated the out-of-root path: $wstate"
    ;;
esac

# M-3: a 200-character model alias must still render under the ceiling.
# The stored requested_model stays the full alias; only the W-STATE interpolation
# is capped (first 40 unicode scalars plus an ellipsis).
WV_PROJECT="$(mkproj)"
stfile="$WV_TESTS_DIR/fixtures/state/bgwait-ad-unjoined.json"
long_model="$(printf 'x%.0s' {1..200})"
long_meta="$(printf '%s' "$meta" | jq -c --arg m "$long_model" '.model = $m')"
sidecar_dir="$WV_RUN_TMP/claude-accounts/proharsh/projects/-tmp-wave-plugin-e2e-scenario-I2b/49194d68-d614-4504-8f34-520d3adeb949/subagents"
mkdir -p "$sidecar_dir"
printf '%s' "$long_meta" > "$sidecar_dir/agent-a1.meta.json"
cp "$WV_TESTS_DIR/fixtures/transcripts/all-haiku.jsonl" "$sidecar_dir/agent-a1.jsonl" || exit 1
trpath="$sidecar_dir/agent-a1.jsonl"
mk 'del(.seed.files[".wave/tr/agent-a1.meta.json"])'
jq --arg tr "$trpath" '.stdin.agent_transcript_path = $tr' "$c" > "$c.i2b" && mv "$c.i2b" "$c"
run_hook subagent-stop.sh "$c" || fail 'hook run failed'
assert_block W-BGWAIT || rc=1
if ! jq -e --arg m "$long_model" '.active.a1.requested_model == $m' \
    "$WV_PROJECT/.wave/state.json" >/dev/null 2>&1; then
  fail "M-3: requested_model must stay the full 200-character alias in state"
fi
wstate="$(wstate_line)"
[ -n "$wstate" ] || { fail "M-3: no W-STATE line on stderr"; wstate=""; }
wlen="$(jq -n --arg t "$wstate" '$t | length')"
case "$wlen" in
  ''|*[!0-9]*) fail "M-3: could not measure W-STATE length (got '$wlen')" ;;
  *)
    [ "$wlen" -le "$cap" ] || \
      fail "M-3: recovered W-STATE is $wlen characters, over the $cap bound: $wstate"
    ;;
esac
brief40="$(printf '%s' "$long_model" | head -c 40)"
case "$wstate" in
  *"$brief40…"*) : ;;
  *) fail "M-3: recovered W-STATE must cap the model at 40 characters plus an ellipsis: $wstate" ;;
esac
case "$wstate" in
  *"${brief40}x"*)
    fail "M-3: recovered W-STATE interpolated more than 40 model characters: $wstate"
    ;;
esac

exit $rc
