#!/usr/bin/env bash
# tests/tools/gen-stop-cases.sh [target-root]
#
# Regenerates the mechanical part of the `subagent-stop.sh` corpus:
#
#   <target-root>/tests/cases/{stop,marker,taint,ledger,lean}-*.json
#   <target-root>/tests/fixtures/state/stop-*.json      (the twelve wave states)
#
# `target-root` defaults to the repository root, so a bare run rewrites the
# committed corpus in place. Deterministic and byte-reproducible: every id,
# path, timestamp and message body is a literal in this file, `jq` does the
# encoding, and nothing reads the clock or the environment. Same contract and
# the same reproducibility check as tests/tools/gen-pre-agent-cases.sh:
#
#   bash tests/tools/gen-stop-cases.sh /tmp/regen-stop
#   cd /tmp/regen-stop && for f in tests/cases/{stop,marker,taint,ledger,lean}-*.json \
#     tests/fixtures/state/stop-*.json; do cmp "$f" "<repo>/$f" || echo "DRIFTED: $f"; done
#
# What this file does NOT generate: the multi-run scenarios (a data-state
# matrix, two agents of one phase, twenty concurrent stops, a held lock). Those
# live as hand-written `tests/cases/*.sh` cases because each drives `run_hook`
# several times against one project and asserts between the runs, which the
# declarative JSON schema cannot express.
#
# Deliberately `set -u`, never `set -e`: a single failed `mk` must be visible in
# the output rather than silently truncating the corpus.

set -u

WV_TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WV_REPO_ROOT="$(cd "$WV_TOOLS_DIR/../.." && pwd)"
WV_TARGET_ROOT="${1:-$WV_REPO_ROOT}"
WV_CASES_DIR="$WV_TARGET_ROOT/tests/cases"
WV_STATE_DIR="$WV_TARGET_ROOT/tests/fixtures/state"

for tool in jq; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'gen-stop-cases.sh: required tool not found on PATH: %s\n' "$tool" >&2
    exit 1
  fi
done
mkdir -p "$WV_CASES_DIR" "$WV_STATE_DIR" || exit 1

# ---------------------------------------------------------------------------
# 1. The wave states. Each one is `valid-full.json` plus an `active` map in the
#    exact shape post-agent.sh writes (phase, role, requested_model,
#    resolved_model, tool_use_id, status) — subagent-stop.sh joins on that
#    record and on nothing else.
# ---------------------------------------------------------------------------

BASE_STATE="$WV_STATE_DIR/valid-full.json"

active_rec() {
  # active_rec <phase> <role> <requested> -> the jq object literal
  jq -nc --arg p "$1" --arg r "$2" --arg m "$3" \
    '{phase: $p, role: $r, requested_model: $m,
      resolved_model: ("claude-" + $m + "-5"),
      tool_use_id: "toolu_01RXAwe6jcU5LBKHd9geD6sE", status: "launched"}'
}

done_rec() {
  # done_rec <agent> -> a completed phase record
  jq -nc --arg a "$1" '{status: "done", at: "2026-09-09T12:10:00Z", agent: $a}'
}

mkstate() {
  # mkstate <name> <jq filter over valid-full.json>
  local name="$1" filter="$2"
  jq "$filter" "$BASE_STATE" > "$WV_STATE_DIR/stop-$name.json" \
    || printf 'gen-stop-cases.sh: state %s FAILED\n' "$name" >&2
}

mkstate ac-reviewer       ".active = {a1: $(active_rec AC reviewer opus)}"
mkstate ac-reviewer-done  ".active = {a2: $(active_rec AC reviewer opus)}
  | .phases = {AC: $(done_rec a1), ACB: $(done_rec a9), \"TDE-RED\": $(done_rec a8)}"
mkstate ac-tainted        ".phases = {AC: ($(done_rec a1) + {tainted: true,
      tainted_model: \"claude-haiku-4-5-20251001\", tainted_used: \"haiku\",
      tainted_required: \"opus\"})}"
mkstate red-reviewer      ".active = {a1: $(active_rec TDE-RED reviewer sonnet)}"
mkstate green-reviewer    ".active = {a1: $(active_rec TDE-GREEN reviewer opus)}"
mkstate green-reviewer-ui ".active = {a1: $(active_rec TDE-GREEN reviewer opus)} | .ui = true"
mkstate green-executor    ".active = {a1: $(active_rec TDE-GREEN executor sonnet)}"
mkstate dr-reviewer       ".active = {a1: $(active_rec DR reviewer opus)} | .ui = true"
mkstate bc-executor       ".active = {a1: $(active_rec BC executor sonnet)}"
mkstate other-agent       ".active = {zz9nomatch: $(active_rec AC reviewer opus)}"
mkstate demo-bc-scanner   ".active = {a1: $(active_rec BC scanner sonnet)} | .mode = \"demo\""
mkstate solo-untagged     ".active = {a1: $(active_rec SOLO unknown sonnet)} | .mode = \"solo\""
mkstate solo-tagged       ".active = {a1: $(active_rec AC lead haiku)} | .mode = \"solo\""

# ---------------------------------------------------------------------------
# 2. The one stdin shape. Copied field for field from the SubagentStop payload
#    in ~/WAVE_PLUGIN_ANALYSIS/probe-hooks.log, including `background_tasks`
#    reporting the stopping agent as `running` — the platform really does send
#    that at the agent's own stop, and no rule may read it as completion.
# ---------------------------------------------------------------------------

count=0

mk() {
  # mk name=… ac=… note=… [state=…] [agent=…] [stop_active=true] [last=…]
  #    [transcript=…] [transcripts=<jq obj>] [seed=<jq obj>] expect=<jq obj>
  local name="" ac="" note="" state="" agent="a1" stop_active="false" last="done"
  local transcript="" transcripts="{}" seed="{}" expect="{}"
  local kv
  for kv in "$@"; do
    case "$kv" in
      name=*)        name="${kv#name=}" ;;
      ac=*)          ac="${kv#ac=}" ;;
      note=*)        note="${kv#note=}" ;;
      state=*)       state="${kv#state=}" ;;
      agent=*)       agent="${kv#agent=}" ;;
      stop_active=*) stop_active="${kv#stop_active=}" ;;
      last=*)        last="${kv#last=}" ;;
      transcript=*)  transcript="${kv#transcript=}" ;;
      transcripts=*) transcripts="${kv#transcripts=}" ;;
      seed=*)        seed="${kv#seed=}" ;;
      expect=*)      expect="${kv#expect=}" ;;
      *) printf 'gen-stop-cases.sh: unknown mk key: %s\n' "$kv" >&2; return 1 ;;
    esac
  done
  local out="$WV_CASES_DIR/$name.json"
  jq -n \
    --arg ac "$ac" --arg note "$note" --arg state "$state" --arg agent "$agent" \
    --argjson stop_active "$stop_active" --arg last "$last" \
    --arg transcript "$transcript" --argjson transcripts "$transcripts" \
    --argjson seed "$seed" --argjson expect "$expect" '
    {
      ac: $ac,
      note: $note,
      script: "subagent-stop.sh",
      seed: (({} | if $state == "" then . else . + {state: $state} end)
             | if ($seed | length) == 0 then . else . + {files: $seed} end
             | if ($transcripts | length) == 0 then . else . + {transcripts: $transcripts} end),
      stdin: ({
        session_id: "1a2b0599-4617-4e73-a9c0-2bef462b2626",
        transcript_path: "/tmp/wave-plugin-tests/transcript.jsonl",
        cwd: ".",
        prompt_id: "c1f033ea-e4ee-4474-88ec-3913700ae39d",
        permission_mode: "bypassPermissions",
        agent_id: $agent,
        agent_type: "general-purpose",
        hook_event_name: "SubagentStop",
        stop_hook_active: $stop_active,
        last_assistant_message: $last,
        background_tasks: [{id: $agent, type: "subagent", status: "running",
                            description: "probe echo", agent_type: "general-purpose"}],
        session_crons: []
      } | if $transcript == "" then . else . + {agent_transcript_path: $transcript} end),
      expect: $expect
    }' > "$out" || { printf 'gen-stop-cases.sh: %s FAILED\n' "$name" >&2; return 1; }
  count=$((count + 1))
}

rep() {
  # rep <char> <n> -> that character n times (message bodies for the 2,000 cap)
  local c="$1" n="$2" out=""
  while [ "${#out}" -lt "$n" ]; do out="$out$c$c$c$c$c$c$c$c$c$c"; done
  printf '%s' "${out:0:$n}"
}

AC_MD='AC-1 the ledger records the spend of every agent
AC-2 and the tier that actually ran
'
RED_MD='RED-VERIFIED failing=7
'
GREEN_MD='GREEN-VERIFIED passing=42 failing=0
'
DR_MD='DR-VERIFIED
OPEN: is the fan-out three or four writers?
OPEN: does the dashboard poll or subscribe?
'
LEDGER_3='{"agent":"z1","phase":"AC","role":"lead","requested":"opus","resolved":"claude-opus-5","tier_ok":true,"tier_verified":true,"input":1,"output":2,"cache_read":0,"cache_create":0,"turns":1,"stopped":"2026-09-09T12:01:00Z"}
{"agent":"z2","phase":"AC","role":"executor","requested":"sonnet","resolved":"claude-sonnet-5","tier_ok":true,"tier_verified":true,"input":3,"output":4,"cache_read":0,"cache_create":0,"turns":1,"stopped":"2026-09-09T12:02:00Z"}
{"agent":"z3","phase":"ACB","role":"lead","requested":"opus","resolved":"claude-opus-5","tier_ok":true,"tier_verified":true,"input":5,"output":6,"cache_read":0,"cache_create":0,"turns":1,"stopped":"2026-09-09T12:03:00Z"}
'

files() {
  # files <path> <content> [<path> <content>…] -> the seed.files object
  local out="{}"
  while [ "$#" -ge 2 ]; do
    out="$(printf '%s' "$out" | jq -c --arg p "$1" --arg c "$2" '. + {($p): $c}')"
    shift 2
  done
  printf '%s' "$out"
}

TR_A1='.wave/tr/a1.jsonl'
tr_map() { jq -nc --arg d "$TR_A1" --arg s "$1" '{($d): $s}'; }

# ---------------------------------------------------------------------------
# 3. No wave (AC-4).
# ---------------------------------------------------------------------------

mk name=stop-004-no-wave-silent ac=AC-4 \
  note='no .wave/state.json at all: silent no-op, and no ledger file is created — the minimum-disturbance guarantee for a session that never ran /wave-start.' \
  expect="$(jq -nc '{exit:0, decision:"silent", files_absent:[".wave/ledger.jsonl", ".wave/state.json"]}')"

# The event guard. Wired to SubagentStop only, so a payload from any other event
# is not something this script has measured (Global Constraint 3). The fixture is
# a real PreToolUse(Agent) payload against a wave whose AC phase would otherwise
# be judged, so a missing guard would produce a ledger line and a phase record.
jq -n '{
  ac: "AC-4",
  note: "a PreToolUse(Agent) payload delivered to subagent-stop.sh: silent no-op, no ledger, no state change — the event guard, and the negative control for every rule this script can emit.",
  script: "subagent-stop.sh",
  seed: {state: "state/stop-ac-reviewer.json"},
  stdin: {
    session_id: "1a2b0599-4617-4e73-a9c0-2bef462b2626",
    transcript_path: "/tmp/wave-plugin-tests/transcript.jsonl",
    cwd: ".",
    permission_mode: "bypassPermissions",
    hook_event_name: "PreToolUse",
    tool_name: "Agent",
    tool_use_id: "toolu_01RXAwe6jcU5LBKHd9geD6sE",
    agent_id: "a1",
    tool_input: {description: "[W:1 P:AC R:reviewer] review the criteria",
                 prompt: "Do the thing.", subagent_type: "general-purpose", model: "opus"}
  },
  expect: {exit: 0, decision: "silent", ledger_lines: 0,
           files_absent: [".wave/ledger.jsonl"],
           state_assert: ".phases == {} and .active.a1.status == \"launched\""}
}' > "$WV_CASES_DIR/stop-event-guard-silent.json" || \
  printf 'gen-stop-cases.sh: stop-event-guard FAILED\n' >&2
count=$((count + 1))

# ---------------------------------------------------------------------------
# 4. Artifacts and markers (AC-202..AC-235).
# ---------------------------------------------------------------------------

mk name=stop-202-ac-reviewer-done ac=AC-202 \
  note='the AC reviewer (the phase closing role) stops with .wave/ac.md matching ^AC-[0-9]+ and an all-opus transcript: silent, phases.AC.status done with at and agent, active.a1 marked stopped, exactly one ledger line.' \
  state=state/stop-ac-reviewer.json transcript="$TR_A1" transcripts="$(tr_map transcripts/all-opus.jsonl)" \
  seed="$(files .wave/ac.md "$AC_MD")" \
  expect="$(jq -nc '{exit:0, decision:"silent", negative_control_for:"W-ARTIFACT",
    stdout_absent:["W-ARTIFACT","W-MARKER"], ledger_lines:1,
    state_assert: ".phases.AC.status == \"done\" and (.phases.AC.at | type) == \"string\" and .phases.AC.agent == \"a1\" and .active.a1.status == \"stopped\""}')"

mk name=marker-204-no-ac-line-block ac=AC-204 \
  note='.wave/ac.md present with no line matching ^AC-[0-9]+: block(W-MARKER) quoting the regex and the file, AC not done, and the ledger line is still appended.' \
  state=state/stop-ac-reviewer.json \
  seed="$(files .wave/ac.md 'no criteria here
just prose about criteria
')" \
  expect="$(jq -nc '{exit:0, decision:"block", rule:"W-MARKER", reason_template:"W-MARKER",
    reason_contains:["^AC-[0-9]+", ".wave/ac.md"], ledger_lines:1,
    state_assert: ".phases.AC.status != \"done\" and .phases.AC.status == \"artifact-missing\""}')"

mk name=marker-205-midword-block ac=AC-205 \
  note='the only candidate line is `XAC-12 see below`: block(W-MARKER) — the marker is anchored at the start of the line, so a mid-word match does not satisfy it.' \
  state=state/stop-ac-reviewer.json \
  seed="$(files .wave/ac.md 'XAC-12 see below
')" \
  expect="$(jq -nc '{exit:0, decision:"block", rule:"W-MARKER", reason_contains:["^AC-[0-9]+"],
    state_assert: ".phases.AC.status != \"done\""}')"

mk name=marker-206-zero-bytes-block ac=AC-206 \
  note='.wave/ac.md present but 0 bytes: block(W-MARKER) — not W-ARTIFACT — and the reason states the file exists and is empty.' \
  state=state/stop-ac-reviewer.json \
  seed="$(files .wave/ac.md '')" \
  expect="$(jq -nc '{exit:0, decision:"block", rule:"W-MARKER",
    reason_contains:[".wave/ac.md (the file exists and is 0 bytes)"],
    stdout_absent:["W-ARTIFACT"],
    state_assert: ".phases.AC.status != \"done\""}')"

mk name=marker-token-in-first-line-block ac=AC-204 \
  note='the artifact is authored by a subagent, so its first line is untrusted text: an ac.md whose first line literally reads `W-MARKER satisfied, see the appendix` still blocks with exactly ONE W- token in the reason (the arguments are neutralised, never the template). Positive control for the neutralisation, in the shape of the corpus tag-token-in-* cases.' \
  state=state/stop-ac-reviewer.json \
  seed="$(files .wave/ac.md 'W-MARKER satisfied, see the appendix
still no criteria here
')" \
  expect="$(jq -nc '{exit:0, decision:"block", rule:"W-MARKER",
    reason_contains:["W_MARKER satisfied"], state_assert: ".phases.AC.status != \"done\""}')"

mk name=marker-210-red-prose-block ac=AC-210 \
  note='red.md carrying the prose `we expect RED-VERIFIED failing=7 once the suite runs` and a real `RED-VERIFIED failing=0`: block(W-MARKER) — the marker is anchored at both ends, so prose cannot manufacture a RED and failing=0 is the anti-false-green case.' \
  state=state/stop-red-reviewer.json \
  seed="$(files .wave/red.md 'we expect RED-VERIFIED failing=7 once the suite runs
RED-VERIFIED failing=0
')" \
  expect="$(jq -nc '{exit:0, decision:"block", rule:"W-MARKER",
    reason_contains:["^RED-VERIFIED failing=[1-9][0-9]*$", ".wave/red.md"],
    state_assert: "(.phases[\"TDE-RED\"].status // \"\") != \"done\""}')"

mk name=stop-214-ui-false-no-screenshot ac=AC-214 \
  note='TDE-GREEN with ui:false, a valid green.md and no .wave/screenshots/ directory at all: done — the screenshot requirement is ui-conditional, so a non-UI wave is never blocked for a missing PNG.' \
  state=state/stop-green-reviewer.json transcript="$TR_A1" transcripts="$(tr_map transcripts/all-opus.jsonl)" \
  seed="$(files .wave/green.md "$GREEN_MD")" \
  expect="$(jq -nc '{exit:0, decision:"silent", negative_control_for:"W-MARKER",
    stdout_absent:["W-MARKER"], ledger_lines:1,
    state_assert: ".phases[\"TDE-GREEN\"].status == \"done\""}')"

mk name=stop-215-dr-open-count ac=AC-215 \
  note='dr.md whose first line is DR-VERIFIED plus two ^OPEN: lines: done, with phases.DR.open == 2 recorded as informational only (the RED gate re-reads dr.md at dispatch, so the stored count decides nothing).' \
  state=state/stop-dr-reviewer.json \
  seed="$(files .wave/dr.md "$DR_MD")" \
  expect="$(jq -nc '{exit:0, decision:"silent", ledger_lines:1,
    state_assert: ".phases.DR.status == \"done\" and .phases.DR.open == 2"}')"

mk name=marker-216-not-dr-verified-block ac=AC-216 \
  note='dr.md whose only marker-like line is NOT-DR-VERIFIED: block(W-MARKER) — ^DR-VERIFIED is start-anchored.' \
  state=state/stop-dr-reviewer.json \
  seed="$(files .wave/dr.md 'NOT-DR-VERIFIED
')" \
  expect="$(jq -nc '{exit:0, decision:"block", rule:"W-MARKER", reason_contains:["^DR-VERIFIED"],
    state_assert: ".phases.DR.status != \"done\""}')"

mk name=stop-230-executor-is-closing ac=AC-230 \
  note='BC defines neither reviewer nor lead, so its executor IS the closing role: a BC executor stopping with .wave/findings/BC.md absent blocks(W-ARTIFACT) naming the file.' \
  state=state/stop-bc-executor.json \
  expect="$(jq -nc '{exit:0, decision:"block", rule:"W-ARTIFACT", reason_template:"W-ARTIFACT",
    reason_contains:[".wave/findings/BC.md", "BC"], ledger_lines:1,
    state_assert: ".phases.BC.status == \"artifact-missing\""}')"

mk name=stop-231-stop-hook-active-no-block ac=AC-231 \
  note='the AC-203 state (ac.md absent) with stop_hook_active:true: exit 0 and NO block under any circumstance, the failure still recorded as artifact-missing, and the deny left to the next dependent dispatch — a hook that re-blocks here loops the harness to its block cap.' \
  state=state/stop-ac-reviewer.json stop_active=true \
  expect="$(jq -nc '{exit:0, decision:"allow", stdout_absent:["block", "W-ARTIFACT"], ledger_lines:1,
    state_assert: ".phases.AC.status == \"artifact-missing\""}')"

mk name=stop-235-redo-passes-prev ac=AC-235 \
  note='a re-dispatched AC closing agent (a2) whose artifact and marker now pass, over a phases.AC already done by a1: status stays done with prev:"done" recorded, the new agent id written, and no successor marked stale.' \
  state=state/stop-ac-reviewer-done.json agent=a2 \
  seed="$(files .wave/ac.md "$AC_MD")" \
  expect="$(jq -nc '{exit:0, decision:"silent", ledger_lines:1,
    state_assert: ".phases.AC.status == \"done\" and .phases.AC.prev == \"done\" and .phases.AC.agent == \"a2\" and (.phases.ACB.stale // false) == false and (.phases[\"TDE-RED\"].stale // false) == false"}')"

mk name=stop-modes-demo-bc ac=AC-227 \
  note='fix round 1, item 4: a DEMO wave and a stop for BC, whose modes cell is `full` only. The row does not run in this wave, so it is not judged here at all — no phase status, no round — and the mismatch is reported as W-STATE rather than passed over in silence. Without the modes check the hook judged a phase the wave never had, writing phases.BC and rounds["BC/scanner"] into a demo wave.' \
  state=state/stop-demo-bc-scanner.json \
  seed="$(files .wave/findings/BC.md 'FINDINGS: 0
')" \
  expect="$(jq -nc '{exit:0, decision:"allow", stdout_absent:["block"], ledger_lines:1,
    stderr_contains:["W-STATE", "BC", "demo"],
    ledger_assert: ".phase == \"BC\" and .role == \"scanner\" and .tier_ok == null",
    state_assert: ".phases == {} and .rounds == {}"}')"

# ---------------------------------------------------------------------------
# 5. The transcript tier check (AC-238..AC-246). W-TAINT is a warning that
#    records state; it never blocks.
# ---------------------------------------------------------------------------

mk name=taint-238-all-opus-ok ac=AC-238 \
  note='every assistant line is claude-opus-5 with output tokens and the AC reviewer cell requires opus: done, ledger tier_ok:true and tier_verified:true, no W-TAINT anywhere. Also the negative control for W-TAINT.' \
  state=state/stop-ac-reviewer.json transcript="$TR_A1" transcripts="$(tr_map transcripts/all-opus.jsonl)" \
  seed="$(files .wave/ac.md "$AC_MD")" \
  expect="$(jq -nc '{exit:0, decision:"silent", negative_control_for:"W-TAINT",
    stdout_absent:["W-TAINT"], ledger_lines:1,
    ledger_assert: ".tier_ok == true and .tier_verified == true and .turns == 3",
    state_assert: ".phases.AC.status == \"done\" and (.phases.AC.tainted // false) == false"}')"

mk name=taint-239-one-haiku-modal-opus ac=AC-239 \
  note='five opus lines and one haiku line: the check is the MODAL tier of assistant turns with output tokens, so the phase is done, tier_ok stays true and no W-TAINT fires — one lower-tier line is ordinary tool behaviour, not a downgrade.' \
  state=state/stop-ac-reviewer.json transcript="$TR_A1" transcripts="$(tr_map transcripts/one-haiku.jsonl)" \
  seed="$(files .wave/ac.md "$AC_MD")" \
  expect="$(jq -nc '{exit:0, decision:"silent", stdout_absent:["W-TAINT"], ledger_lines:1,
    ledger_assert: ".tier_ok == true and .tier_verified == true and .turns == 6",
    state_assert: ".phases.AC.status == \"done\" and (.phases.AC.tainted // false) == false"}')"

mk name=taint-240-all-haiku-tainted ac=AC-240 \
  note='every assistant line with output tokens is claude-haiku-4-5-20251001 where opus was required: exit 0 and NO block, the phase still marked done but tainted:true, ledger tier_ok:false, and one W-TAINT naming the offending model and the required tier — a platform-side downgrade is recorded, not punished.' \
  state=state/stop-ac-reviewer.json transcript="$TR_A1" transcripts="$(tr_map transcripts/all-haiku.jsonl)" \
  seed="$(files .wave/ac.md "$AC_MD")" \
  expect="$(jq -nc '{exit:0, decision:"allow", stdout_absent:["block"], ledger_lines:1,
    ledger_assert: ".tier_ok == false and .tier_verified == true and (.warn | length) == 1 and (.warn[0] | contains(\"W-TAINT\"))",
    state_assert: ".phases.AC.status == \"done\" and .phases.AC.tainted == true and .phases.AC.tainted_model == \"claude-haiku-4-5-20251001\" and .phases.AC.tainted_required == \"opus\""}')"

mk name=taint-243-zero-assistant ac=AC-243 \
  note='a transcript with zero assistant lines: exit 0, no block, done with tier_verified:false, and turns/input/output all 0 with tier_ok null — an empty transcript is unverifiable, never taint.' \
  state=state/stop-ac-reviewer.json transcript="$TR_A1" transcripts="$(tr_map transcripts/zero-assistant.jsonl)" \
  seed="$(files .wave/ac.md "$AC_MD")" \
  expect="$(jq -nc '{exit:0, decision:"silent", ledger_lines:1,
    ledger_assert: ".turns == 0 and .input == 0 and .output == 0 and .tier_ok == null and .tier_verified == false",
    state_assert: ".phases.AC.status == \"done\" and (.phases.AC.tainted // false) == false"}')"

mk name=taint-244-model-less-excluded ac=AC-244 \
  note='two assistant lines, one with no message.model and one with output_tokens 0: both are excluded from the modal tier, the phase is done, the ledger carries tier_ok:null / tier_verified:false, and the excluded count is recorded in note — a missing model field is not a downgrade.' \
  state=state/stop-ac-reviewer.json transcript="$TR_A1" transcripts="$(tr_map transcripts/model-less.jsonl)" \
  seed="$(files .wave/ac.md "$AC_MD")" \
  expect="$(jq -nc '{exit:0, decision:"silent", ledger_lines:1,
    ledger_assert: ".turns == 2 and .tier_ok == null and .tier_verified == false and (.note | contains(\"2 of 2\"))",
    state_assert: ".phases.AC.status == \"done\" and (.phases.AC.tainted // false) == false"}')"

mk name=taint-246-upward-ok ac=AC-246 \
  note='an all-opus transcript where the row requires sonnet (TDE-RED reviewer): done with tier_ok:true — upward deviation is never taint.' \
  state=state/stop-red-reviewer.json transcript="$TR_A1" transcripts="$(tr_map transcripts/all-opus.jsonl)" \
  seed="$(files .wave/red.md "$RED_MD")" \
  expect="$(jq -nc '{exit:0, decision:"silent", stdout_absent:["W-TAINT"], ledger_lines:1,
    ledger_assert: ".tier_ok == true and .tier_verified == true",
    state_assert: ".phases[\"TDE-RED\"].status == \"done\""}')"

# ---------------------------------------------------------------------------
# 6. The ledger line (AC-232, AC-233, AC-247..AC-251).
# ---------------------------------------------------------------------------

mk name=ledger-232-unknown-agent ac=AC-232 \
  note='state.active holds a different agent, so the stopping agent joins nothing: exit 0, no block, no phase marked done, and one ledger line with phase/role/requested "unknown", tier_ok null and every section-9 key present.' \
  state=state/stop-other-agent.json \
  expect="$(jq -nc '{exit:0, decision:"allow", stdout_absent:["block"], ledger_lines:1,
    ledger_assert: ".agent == \"a1\" and .phase == \"unknown\" and .role == \"unknown\" and .requested == \"unknown\" and .tier_ok == null and (([\"agent\",\"cache_create\",\"cache_read\",\"input\",\"output\",\"phase\",\"requested\",\"resolved\",\"role\",\"stopped\",\"tier_ok\",\"tier_verified\",\"turns\"] - keys) | length) == 0",
    state_assert: ".phases == {}"}')"

mk name=ledger-233-empty-active ac=AC-233 \
  note='state.active is empty because post-agent.sh has not run yet (a launch/stop race, or a pre-wave dispatch): the AC-232 shape exactly, whether the dispatch was tagged or not.' \
  state=state/valid-full.json \
  expect="$(jq -nc '{exit:0, decision:"allow", stdout_absent:["block"], ledger_lines:1,
    ledger_assert: ".agent == \"a1\" and .phase == \"unknown\" and .role == \"unknown\" and .requested == \"unknown\" and .tier_ok == null",
    state_assert: ".phases == {} and .active == {}"}')"

mk name=ledger-247-key-set ac=AC-247 \
  note='seven assistant lines summing to input 1234, output 5678, cache_read 900, cache_create 12: exactly one appended line whose key set EQUALS the section-9 set (no extra keys), with those exact numbers, turns 7, a boolean tier_ok, an ISO-8601 UTC stopped, and the file ending in exactly one newline (ledger_lines counts newlines).' \
  state=state/stop-ac-reviewer.json transcript="$TR_A1" transcripts="$(tr_map transcripts/usage-sum.jsonl)" \
  seed="$(files .wave/ac.md "$AC_MD")" \
  expect="$(jq -nc '{exit:0, decision:"silent", ledger_lines:1,
    ledger_assert: "(keys == [\"agent\",\"cache_create\",\"cache_read\",\"input\",\"output\",\"phase\",\"requested\",\"resolved\",\"role\",\"stopped\",\"tier_ok\",\"tier_verified\",\"turns\"]) and .input == 1234 and .output == 5678 and .cache_read == 900 and .cache_create == 12 and .turns == 7 and (.tier_ok | type) == \"boolean\" and (.stopped | test(\"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$\")) and .agent == \"a1\" and .phase == \"AC\" and .role == \"reviewer\" and .requested == \"opus\""}')"

mk name=ledger-248-append-not-rewrite ac=AC-248 \
  note='a pre-existing ledger of three lines: afterwards it holds four and the first three are byte-identical — append, never rewrite.' \
  state=state/stop-ac-reviewer.json transcript="$TR_A1" transcripts="$(tr_map transcripts/all-opus.jsonl)" \
  seed="$(files .wave/ac.md "$AC_MD" .wave/ledger.jsonl "$LEDGER_3")" \
  expect="$(jq -nc --arg l "$LEDGER_3" '{exit:0, decision:"silent", ledger_lines:4,
    ledger_prefix_unchanged: 3,
    ledger_assert: ".agent == \"a1\""}')"

mk name=ledger-249-assistant-only ac=AC-249 \
  note='user and system lines interleaved with assistant lines, the non-assistant ones carrying usage of their own: turns counts assistant lines only (2) and the foreign usage is ignored (input 40, not 15594).' \
  state=state/stop-ac-reviewer.json transcript="$TR_A1" transcripts="$(tr_map transcripts/mixed-roles.jsonl)" \
  seed="$(files .wave/ac.md "$AC_MD")" \
  expect="$(jq -nc '{exit:0, decision:"silent", ledger_lines:1,
    ledger_assert: ".turns == 2 and .input == 40 and .output == 60"}')"

mk name=ledger-250-absent-cache-zero ac=AC-250 \
  note='assistant lines that omit cache_read_input_tokens and cache_creation_input_tokens entirely: the ledger carries cache_read:0 and cache_create:0 — absent means zero, never null and never empty.' \
  state=state/stop-ac-reviewer.json transcript="$TR_A1" transcripts="$(tr_map transcripts/no-cache-fields.jsonl)" \
  seed="$(files .wave/ac.md "$AC_MD")" \
  expect="$(jq -nc '{exit:0, decision:"silent", ledger_lines:1,
    ledger_assert: ".cache_read == 0 and .cache_create == 0 and (.cache_read | type) == \"number\" and .input == 43 and .output == 63"}')"

mk name=ledger-251-truncated-final-line ac=AC-251 \
  note='the final line is a JSON fragment cut off mid-write: exit 0, the two parsable lines are summed, the fragment is skipped and counted in skipped_lines, nothing from jq reaches stderr, and no block.' \
  state=state/stop-ac-reviewer.json transcript="$TR_A1" transcripts="$(tr_map transcripts/truncated.jsonl)" \
  seed="$(files .wave/ac.md "$AC_MD")" \
  expect="$(jq -nc '{exit:0, decision:"silent", ledger_lines:1,
    ledger_assert: ".turns == 2 and .input == 44 and .output == 66 and .skipped_lines == 1"}')"

mk name=lock-254b-drain-only ac=AC-254 \
  note='a spooled line from an earlier lock timeout, and a stop that appends nothing of its own (the agent is already spooled, so the dedupe suppresses a second line, and it joins no launch record so no phase or round is written either): the pending line still reaches the ledger, and the spool file is gone. This is the leg that makes the DRAIN load-bearing on its own — every other path drains as a side effect of a state write or an append, so without this case a hook that never drained would look correct.' \
  state=state/valid-full.json agent=zz9spooled \
  seed="$(files .wave/ledger.pending/zz9spooled.json '{"agent":"zz9spooled","phase":"TDE-GREEN","role":"executor","requested":"sonnet","resolved":"claude-sonnet-5","tier_ok":true,"tier_verified":true,"input":11,"output":22,"cache_read":0,"cache_create":0,"turns":2,"stopped":"2026-09-09T12:04:00Z"}
')" \
  expect="$(jq -nc '{exit:0, decision:"allow", stdout_absent:["block"], ledger_lines:1,
    files_absent:[".wave/ledger.pending/zz9spooled.json"],
    ledger_assert: ".agent == \"zz9spooled\" and .input == 11 and .output == 22",
    state_assert: ".phases == {} and .active == {}"}')"

# ---------------------------------------------------------------------------
# 7. Lean return (AC-257..AC-260) and solo mode (AC-330, AC-337).
# ---------------------------------------------------------------------------

mk name=lean-257-2001-block ac=AC-257 \
  note='last_assistant_message of exactly 2,001 characters with stop_hook_active:false: block(W-LONG-RETURN) naming the 2,000 cap and the report path .wave/reports/<PHASE>-<ROLE>-<agent_id>.md.' \
  state=state/stop-ac-reviewer.json transcript="$TR_A1" transcripts="$(tr_map transcripts/all-opus.jsonl)" \
  seed="$(files .wave/ac.md "$AC_MD")" last="$(rep L 2001)" \
  expect="$(jq -nc '{exit:0, decision:"block", rule:"W-LONG-RETURN", reason_template:"W-LONG-RETURN",
    reason_contains:["2000", "2001", ".wave/reports/AC-reviewer-a1.md"]}')"

mk name=lean-258-1999-allow ac=AC-258 \
  note='the same with 1,999 characters: no block from this rule. Boundary negative control for W-LONG-RETURN — the cap is "longer than 2,000", so 2,000 exactly and below must pass.' \
  state=state/stop-ac-reviewer.json transcript="$TR_A1" transcripts="$(tr_map transcripts/all-opus.jsonl)" \
  seed="$(files .wave/ac.md "$AC_MD")" last="$(rep L 1999)" \
  expect="$(jq -nc '{exit:0, decision:"silent", negative_control_for:"W-LONG-RETURN",
    stdout_absent:["W-LONG-RETURN"], ledger_lines:1,
    ledger_assert: "(.long_return // false) == false"}')"

mk name=lean-259-stop-hook-active-long-return ac=AC-259 \
  note='the same 2,001-character message with stop_hook_active:true: never block again, and the ledger line carries long_return:true.' \
  state=state/stop-ac-reviewer.json stop_active=true transcript="$TR_A1" \
  transcripts="$(tr_map transcripts/all-opus.jsonl)" \
  seed="$(files .wave/ac.md "$AC_MD")" last="$(rep L 2001)" \
  expect="$(jq -nc '{exit:0, decision:"allow", stdout_absent:["block", "W-LONG-RETURN"], ledger_lines:1,
    ledger_assert: ".long_return == true"}')"

mk name=lean-260-solo-no-block ac=AC-260 \
  note='mode:"solo" with a 2,001-character message and stop_hook_active:false: no block — section 8 is not enforced in solo mode, which exists so the cheap invariants do not have to be turned off to get out of the way.' \
  state=state/stop-solo-untagged.json transcript="$TR_A1" \
  transcripts="$(tr_map transcripts/all-opus.jsonl)" last="$(rep L 2001)" \
  expect="$(jq -nc '{exit:0, decision:"allow", stdout_absent:["block", "W-LONG-RETURN"], ledger_lines:1,
    ledger_assert: ".phase == \"SOLO\""}')"

mk name=stop-330-solo-untagged-ledger ac=AC-330 \
  note='solo mode and an untagged dispatch that post-agent.sh recorded under phase SOLO: its stop produces one ledger line with phase "SOLO", no phase gating and no block.' \
  state=state/stop-solo-untagged.json transcript="$TR_A1" \
  transcripts="$(tr_map transcripts/all-opus.jsonl)" \
  expect="$(jq -nc '{exit:0, decision:"silent", ledger_lines:1,
    ledger_assert: ".phase == \"SOLO\" and .role == \"unknown\" and .requested == \"sonnet\" and .tier_ok == null",
    state_assert: ".phases == {}"}')"

mk name=stop-337-solo-tagged-ledger ac=AC-337 \
  note='solo mode and a TAGGED dispatch recorded as AC/lead with model haiku (below the table tier): the ledger records the tag phase and role and tier_ok stays null — phases.tsv is not consulted in solo, so no artifact check and no tier comparison happen at all.' \
  state=state/stop-solo-tagged.json transcript="$TR_A1" \
  transcripts="$(tr_map transcripts/all-haiku.jsonl)" \
  expect="$(jq -nc '{exit:0, decision:"silent", stdout_absent:["W-TAINT","W-ARTIFACT"], ledger_lines:1,
    ledger_assert: ".phase == \"AC\" and .role == \"lead\" and .requested == \"haiku\" and .tier_ok == null",
    state_assert: ".phases == {}"}')"

# ---------------------------------------------------------------------------
# 8. The dispatch-time half of the taint rule (AC-241) — pre-agent.sh, because
#    a taint recorded at one phase's stop has to reach the NEXT dispatch.
# ---------------------------------------------------------------------------

jq -n '{
  ac: "AC-241",
  note: "phases.AC.tainted is true and ACB (which depends on AC) is dispatched: allow plus warn(W-TAINT) whose reason names AC, the model that actually ran and the required tier — never a deny, because the remedy of a gate here is paid rework on a correct wave.",
  script: "pre-agent.sh",
  seed: {state: "state/stop-ac-tainted.json"},
  stdin: {
    session_id: "1a2b0599-4617-4e73-a9c0-2bef462b2626",
    transcript_path: "/tmp/wave-plugin-tests/transcript.jsonl",
    cwd: ".",
    permission_mode: "bypassPermissions",
    hook_event_name: "PreToolUse",
    tool_name: "Agent",
    tool_use_id: "toolu_01RXAwe6jcU5LBKHd9geD6sE",
    tool_input: {
      description: "[W:1 P:ACB R:lead] harden the acceptance criteria",
      prompt: "Do the thing.",
      subagent_type: "general-purpose",
      model: "opus"
    }
  },
  expect: {
    exit: 0, decision: "warn", rule: "W-TAINT", reason_template: "W-TAINT",
    reason_contains: ["phase AC", "claude-haiku-4-5-20251001", "opus"],
    stdout_absent: ["permissionDecision"]
  }
}' > "$WV_CASES_DIR/taint-241-dependent-dispatch-warn.json" || \
  printf 'gen-stop-cases.sh: taint-241 FAILED\n' >&2
count=$((count + 1))

printf '%s case files in %s\n' "$count" "$WV_CASES_DIR"
