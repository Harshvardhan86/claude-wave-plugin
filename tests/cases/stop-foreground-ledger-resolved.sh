#!/usr/bin/env bash
# tests/cases/stop-foreground-ledger-resolved.sh
#
# The ledger's `resolved` model for a FOREGROUND dispatch, in the order the host
# really delivers it: SubagentStop first (no state.active record yet, so the hook
# recovers the launch from the sidecar beside the agent transcript), then
# PostToolUse(Agent) with tool_response.status "completed". The ledger is
# append-only and post-agent.sh never writes it, so the stop has to ledger the
# real model itself: the one the agent transcript records, tagged
# `resolved_from: "transcript"`.
#
#   1. stop-then-post, completed payload: ledger .resolved is the transcript
#      model, .resolved_from == "transcript", .downgraded == false; the late
#      post-agent run leaves the ledger byte-identical and state.active agrees.
#   2. post-then-stop control (the background order): the ledger takes
#      tool_response's id, with no resolved_from.
#   3. downgrade, both orders: requested opus, served haiku -> downgraded true on
#      the ledger line and on state.active, W-DOWNGRADE on the ledger line, and
#      the `stopped` bookkeeping keeps downgraded.
#   4. a transcript that is missing, incomplete, model-less or unmapped leaves
#      .resolved "unknown" with a W-RESOLVE-UNKNOWN that names the transcript.
#   5. post-agent.sh learns something other than the stop-time fill. The ledger
#      is never rewritten; state.active alone records it:
#        5a. a different readable id: resolved_model takes the tool_response id,
#            transcript_model keeps the fill, resolved_from goes (it described
#            the fill, not the new id);
#        5b. an unreadable id: the fill and resolved_from stay.
#   W-DOWNGRADE is emitted ONCE per dispatch: by whichever hook first compares
#   the tiers. `downgraded: true` is sticky: neither the `stopped` bookkeeping
#   nor a later equal-tier tool_response clears it (3c).
set -u
source "$(dirname "$0")/../lib/assert.sh"
name="${WV_CASE_NAME:-$(basename "$0" .sh)}"
log="${WV_CASE_LOG:-$WV_RUN_TMP/logs/$name.log}"
mkdir -p "$(dirname "$log")"
rc=0
fail() { printf 'ASSERT FAIL: %s\n' "$*" >&2; rc=1; }
printf 'RAN subagent-stop.sh %s decision=multi\n' "$name" >> "$log"

c="$WV_RUN_TMP/$name.json"
base="$WV_TESTS_DIR/cases/bgwait-405-running-block.json"
st="$WV_RUN_TMP/$name-state.json"
jq 'del(.bg_tasks)' "$WV_TESTS_DIR/fixtures/state/bgwait-ad-unjoined.json" > "$st" || exit 1
tr_rel=".wave/tr/agent-a1.jsonl"
# The model all-haiku.jsonl records on every reply turn.
TR_MODEL="claude-haiku-4-5-20251001"
# A different id for tool_response, so the control proves WHICH source won.
TOOL_MODEL="claude-haiku-5-5"
# An opus-tier id, for a tool_response that disagrees with a haiku transcript.
OPUS_MODEL="claude-opus-4-1-20250805"

meta_for() {
  jq -cn --arg m "$1" '{agentType:"general-purpose",description:"[W:1 P:AD R:executor] probe",
    toolUseId:"toolu_01X",spawnDepth:1,requestShape:"foreground",requestNonInteractive:true,model:$m}'
}

# stop_case <requested> <seed-state 0|1> <transcript-jq> — <transcript-jq> edits
# .seed.transcripts / .seed.files to choose the transcript under test.
stop_case() {
  jq --arg st "$st" --arg meta "$(meta_for "$1")" --arg tr "$tr_rel" --arg seed "$2" '
    .seed = {files: {(($tr | sub("\\.jsonl$"; "")) + ".meta.json"): $meta},
             transcripts: {($tr): "transcripts/all-haiku.jsonl"}}
    | if $seed == "1" then .seed.state = $st else . end
    | .stdin.agent_transcript_path = $tr
    | .stdin.background_tasks = []
    | '"$3" "$base" > "$c" || exit 1
}
# post_case <status> <requested> <resolvedModel> <seed-state 0|1>
post_case() {
  jq --arg st "$st" --arg s "$1" --arg req "$2" --arg res "$3" --arg seed "$4" '.script = "post-agent.sh"
    | .seed = (if $seed == "1" then {state: $st} else {} end)
    | .stdin = {hook_event_name:"PostToolUse", cwd:".", tool_name:"Agent", tool_use_id:"toolu_01X",
        tool_input:{description:"[W:1 P:AD R:executor] probe", prompt:"Reply with DONE",
                    subagent_type:"general-purpose", model:$req},
        tool_response:{status:$s, agentId:"a1", resolvedModel:$res}}' "$base" > "$c" || exit 1
}
ledger() { printf '%s' "$WV_PROJECT/.wave/ledger.jsonl"; }

# ---- 1. stop then post (the measured foreground order) -------------------
WV_PROJECT="$(mkproj)"
stop_case haiku 1 '.'
run_hook subagent-stop.sh "$c" || fail '1: stop run failed'
assert_allow || rc=1
assert_ledger_lines 1 || rc=1
assert_ledger_line ".resolved == \"$TR_MODEL\" and .resolved_from == \"transcript\"
                    and .downgraded == false and .requested == \"haiku\"
                    and .phase == \"AD\" and .role == \"executor\" and .tier_ok == true
                    and ((.warn // []) | map(select(startswith(\"[W-DOWNGRADE]\") or startswith(\"[W-RESOLVE-UNKNOWN]\"))) | length == 0)" || rc=1
assert_state ".active.a1.status == \"stopped\" and .active.a1.resolved_model == \"$TR_MODEL\"
              and .active.a1.downgraded == false" || rc=1
case "${WV_LAST_STDERR:-}" in
  *'ledgered as "unknown"'*) fail "1: the recovery warning still claims the resolved model is ledgered as unknown: $WV_LAST_STDERR" ;;
esac
cp "$(ledger)" "$WV_RUN_TMP/$name-ledger-1" || exit 1
post_case completed haiku "$TR_MODEL" 0
run_hook post-agent.sh "$c" || fail '1: post run failed'
assert_stdout_absent 'W-DOWNGRADE' || rc=1
assert_state ".active.a1.status == \"stopped\" and .active.a1.resolved_model == \"$TR_MODEL\"
              and .active.a1.phase == \"AD\" and .active.a1.downgraded == false
              and (.active.a1 | has(\"transcript_model\") | not)
              and (.active.a1 | has(\"resolved_from\") | not)" || rc=1
cmp -s "$(ledger)" "$WV_RUN_TMP/$name-ledger-1" || \
  fail "1: post-agent.sh changed the ledger: $(cat "$(ledger)")"

# ---- 2. post then stop (the background order) ----------------------------
WV_PROJECT="$(mkproj)"
post_case async_launched haiku "$TOOL_MODEL" 1
run_hook post-agent.sh "$c" || fail '2: post run failed'
stop_case haiku 0 '.'
run_hook subagent-stop.sh "$c" || fail '2: stop run failed'
assert_ledger_lines 1 || rc=1
assert_ledger_line ".resolved == \"$TOOL_MODEL\" and (has(\"resolved_from\") | not)
                    and .downgraded == false" || rc=1
assert_state ".active.a1.status == \"stopped\" and .active.a1.resolved_model == \"$TOOL_MODEL\"" || rc=1

# ---- 3a. downgrade, stop then post ---------------------------------------
WV_PROJECT="$(mkproj)"
stop_case opus 1 '.'
run_hook subagent-stop.sh "$c" || fail '3a: stop run failed'
assert_ledger_line ".requested == \"opus\" and .resolved == \"$TR_MODEL\"
                    and .resolved_from == \"transcript\" and .downgraded == true
                    and ((.warn // []) | map(select(startswith(\"[W-DOWNGRADE] requested opus but resolved model is $TR_MODEL\"))) | length == 1)" || rc=1
assert_state '.active.a1.downgraded == true and .active.a1.status == "stopped"
              and ((.phases.AD.warned // []) | map(select(startswith("[W-DOWNGRADE] "))) | length == 1)' || rc=1
dg="$(tail -n 1 "$(ledger)" | jq -r '(.warn // [])[] | select(startswith("[W-DOWNGRADE]"))')"
[ "${#dg}" -le 400 ] || fail "3a: W-DOWNGRADE is ${#dg} characters, over 400: $dg"
case "$dg" in *'remedy:'*) : ;; *) fail "3a: W-DOWNGRADE carries no remedy: $dg" ;; esac
cp "$(ledger)" "$WV_RUN_TMP/$name-ledger-3a" || exit 1
post_case completed opus "$TR_MODEL" 0
run_hook post-agent.sh "$c" || fail '3a: post run failed'
# Already reported by the stop (on the ledger line): the late launch record
# must not report the same downgrade a second time.
assert_stdout_absent 'W-DOWNGRADE' || rc=1
assert_state ".active.a1.status == \"stopped\" and .active.a1.downgraded == true
              and .active.a1.resolved_model == \"$TR_MODEL\"" || rc=1
cmp -s "$(ledger)" "$WV_RUN_TMP/$name-ledger-3a" || \
  fail "3a: post-agent.sh changed the ledger: $(cat "$(ledger)")"

# ---- 3b. downgrade, post then stop: `stopped` must not erase it ----------
WV_PROJECT="$(mkproj)"
post_case async_launched opus "$TOOL_MODEL" 1
run_hook post-agent.sh "$c" || fail '3b: post run failed'
assert_state '.active.a1.status == "downgraded" and .active.a1.downgraded == true' || rc=1
stop_case opus 0 '.'
run_hook subagent-stop.sh "$c" || fail '3b: stop run failed'
assert_state '.active.a1.status == "stopped" and .active.a1.downgraded == true' || rc=1
assert_ledger_line ".resolved == \"$TOOL_MODEL\" and .downgraded == true
                    and (has(\"resolved_from\") | not)
                    and ((.warn // []) | map(select(startswith(\"[W-DOWNGRADE]\"))) | length == 0)" || rc=1

# ---- 3c. sticky: a later equal-tier tool_response does not clear it --------
WV_PROJECT="$(mkproj)"
stop_case opus 1 '.'
run_hook subagent-stop.sh "$c" || fail '3c: stop run failed'
assert_state '.active.a1.downgraded == true' || rc=1
cp "$(ledger)" "$WV_RUN_TMP/$name-ledger-3c" || exit 1
post_case completed opus "$OPUS_MODEL" 0
run_hook post-agent.sh "$c" || fail '3c: post run failed'
assert_stdout_absent 'W-DOWNGRADE' || rc=1
assert_state ".active.a1.status == \"stopped\" and .active.a1.downgraded == true
              and .active.a1.resolved_model == \"$OPUS_MODEL\"
              and .active.a1.transcript_model == \"$TR_MODEL\"" || rc=1
cmp -s "$(ledger)" "$WV_RUN_TMP/$name-ledger-3c" || \
  fail "3c: post-agent.sh changed the ledger: $(cat "$(ledger)")"

# ---- 4. a transcript that cannot name the model ---------------------------
unknown_row() {
  # unknown_row <label> — the stop just run must ledger an honest unknown.
  assert_ledger_lines 1 || rc=1
  assert_ledger_line ".resolved == \"unknown\" and (has(\"resolved_from\") | not)
                      and (has(\"downgraded\") | not)" || { fail "4/$1: resolved is not an honest unknown"; }
  local ru
  ru="$(tail -n 1 "$(ledger)" | jq -r '(.warn // [])[] | select(startswith("[W-RESOLVE-UNKNOWN]"))')"
  [ -n "$ru" ] || fail "4/$1: no W-RESOLVE-UNKNOWN on the ledger line: $(cat "$(ledger)")"
  case "$ru" in *"$tr_rel"*) : ;; *) fail "4/$1: W-RESOLVE-UNKNOWN does not name the transcript $tr_rel: $ru" ;; esac
  [ "${#ru}" -le 400 ] || fail "4/$1: W-RESOLVE-UNKNOWN is ${#ru} characters, over 400: $ru"
  assert_state '.active.a1.resolved_model == "unknown" and .active.a1.status == "stopped"' || rc=1
}
WV_PROJECT="$(mkproj)"
stop_case haiku 1 '.seed.transcripts = {}'
run_hook subagent-stop.sh "$c" || fail '4/missing: stop run failed'
unknown_row missing

WV_PROJECT="$(mkproj)"
stop_case haiku 1 '.seed.transcripts[$tr] = "transcripts/model-less.jsonl"'
run_hook subagent-stop.sh "$c" || fail '4/model-less: stop run failed'
unknown_row model-less

WV_PROJECT="$(mkproj)"
stop_case haiku 1 '.seed.transcripts = {} | .seed.files[$tr] = "{\"type\":\"assistant\",\"message\":{\"model\":\"claude-mystery-9\",\"usage\":{\"input_tokens\":3,\"output_tokens\":4}}}\n"'
run_hook subagent-stop.sh "$c" || fail '4/unmapped: stop run failed'
unknown_row unmapped

WV_PROJECT="$(mkproj)"
stop_case haiku 1 '.seed.transcripts[$tr] = "transcripts/zero-assistant.jsonl" | .env = {WV_TRANSCRIPT_SETTLE_TRIES: "2"}'
run_hook subagent-stop.sh "$c" || fail '4/incomplete: stop run failed'
unknown_row incomplete
assert_ledger_line '.transcript_incomplete == true' || rc=1

# ---- 5a. post-agent learns a different id than the stop-time fill --------
WV_PROJECT="$(mkproj)"
stop_case haiku 1 '.'
run_hook subagent-stop.sh "$c" || fail '5a: stop run failed'
cp "$(ledger)" "$WV_RUN_TMP/$name-ledger-5a" || exit 1
post_case completed haiku "$TOOL_MODEL" 0
run_hook post-agent.sh "$c" || fail '5a: post run failed'
assert_state ".active.a1.status == \"stopped\" and .active.a1.resolved_model == \"$TOOL_MODEL\"
              and .active.a1.transcript_model == \"$TR_MODEL\"
              and (.active.a1 | has(\"resolved_from\") | not)
              and .active.a1.downgraded == false" || rc=1
cmp -s "$(ledger)" "$WV_RUN_TMP/$name-ledger-5a" || \
  fail "5a: post-agent.sh changed the ledger: $(cat "$(ledger)")"

# ---- 5b. post-agent cannot read the id: the fill stands -------------------
WV_PROJECT="$(mkproj)"
stop_case haiku 1 '.'
run_hook subagent-stop.sh "$c" || fail '5b: stop run failed'
cp "$(ledger)" "$WV_RUN_TMP/$name-ledger-5b" || exit 1
post_case completed haiku "claude-mystery-9" 0
run_hook post-agent.sh "$c" || fail '5b: post run failed'
case "${WV_LAST_STDOUT:-}" in *'[W-RESOLVE-UNKNOWN]'*) : ;; *) fail "5b: the unreadable launch id is not reported: ${WV_LAST_STDOUT:-}" ;; esac
assert_state ".active.a1.status == \"stopped\" and .active.a1.resolved_model == \"$TR_MODEL\"
              and .active.a1.resolved_from == \"transcript\"
              and .active.a1.downgraded == false
              and (.active.a1 | has(\"transcript_model\") | not)" || rc=1
cmp -s "$(ledger)" "$WV_RUN_TMP/$name-ledger-5b" || \
  fail "5b: post-agent.sh changed the ledger: $(cat "$(ledger)")"

exit $rc
