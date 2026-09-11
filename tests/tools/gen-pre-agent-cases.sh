#!/usr/bin/env bash
# tests/tools/gen-pre-agent-cases.sh [target-root]
#
# Regenerates every fixture the pre-agent.sh dispatch-identity suite runs on:
#
#   <target-root>/tests/cases/{tag,nested,fork,mode,role,model,tier,solo-dispatch}-*.json
#   <target-root>/tests/fixtures/state/*.json                (the eight wave states)
#
# `target-root` defaults to the repository root, so a bare run rewrites the
# committed corpus in place. It is deterministic and byte-reproducible: every
# id, path and timestamp in a fixture is a literal in this file, `jq` does the
# encoding, and nothing reads the clock or the environment. That is what makes
# the corpus reviewable — 204 case files are mechanical variations over one
# stdin shape, and the variation belongs in one place instead of 204.
#
# To prove reproducibility (and that a hand edit has not drifted from this
# generator):
#
#   bash tests/tools/gen-pre-agent-cases.sh /tmp/regen
#   cd /tmp/regen && for f in tests/cases/*.json tests/fixtures/state/*.json; do \
#     cmp "$f" "<repo>/$f" || echo "DRIFTED: $f"; done
#
# (`diff -r` the other way round reports every case file the OTHER tasks own as
# "only in tests/cases", which is correct and unhelpful; the loop above
# compares exactly the files this generator claims.)
#
# The (phase, role) -> tier table near the bottom is transcribed from
# `hooks/phases.tsv`. It is a SECOND copy of that ground truth, deliberately:
# a generator that read phases.tsv would agree with it by construction and
# could never disagree with a wrong cell. The guard against the two copies
# drifting is `tests/golden/phases-tiers.tsv` plus AC-146's mutation control
# (each of the 78 cells lowered by one tier must red at least one case), which
# is why every non-`-` cell here gets both an at-minimum allow and a
# one-tier-below deny.
#
# Deliberately `set -u`, never `set -e`: a single failed `mk` must be visible
# in the output rather than silently truncating the corpus.

set -u

WV_TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WV_REPO_ROOT="$(cd "$WV_TOOLS_DIR/../.." && pwd)"
WV_TARGET_ROOT="${1:-$WV_REPO_ROOT}"
WV_CASES_DIR="$WV_TARGET_ROOT/tests/cases"
WV_STATE_DIR="$WV_TARGET_ROOT/tests/fixtures/state"

for tool in jq; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'gen-pre-agent-cases.sh: required tool not found on PATH: %s\n' "$tool" >&2
    exit 1
  fi
done
mkdir -p "$WV_CASES_DIR" "$WV_STATE_DIR" || exit 1

# ---------------------------------------------------------------------------
# The eight wave states. An "all done" map is what keeps a tier or role case
# from tripping part 2's order gate: `wv_phase_done` short-circuits on
# status == "done" without evaluating the row's condition.
# ---------------------------------------------------------------------------

PHASES="AC ACB DR TDE-RED TDE-GREEN CR BC BF-BC SEA BF-SEA DS BF-DS BSEA BF-BSEA OA TEET-TC TEET BF-TEET BTEET BTEET-X BF-BTEET VB COMMIT CL CCP AD"

done_map() {
  # done_map <code>... -> a jq object of {code: {status,at,agent}}
  local out="{}" c
  for c in "$@"; do
    out="$(printf '%s' "$out" | jq --arg c "$c" '. + {($c): {status: "done", at: "2026-09-09T12:10:00Z", agent: "a6a129f2ae0850db1"}}')"
  done
  printf '%s' "$out"
}

write_state() {
  # write_state <file> <mode> <ui> <bc> <cr> <phases-json> [wave-json]
  local file="$1" mode="$2" ui="$3" bc="$4" cr="$5" phases="$6" wave="${7:-\"1\"}"
  jq -n \
    --argjson wave "$wave" \
    --arg mode "$mode" \
    --argjson ui "$ui" --argjson bc "$bc" --argjson cr "$cr" \
    --argjson phases "$phases" \
    '{
      schema: 1,
      wave: $wave,
      mode: $mode,
      status: "active",
      ui: $ui,
      behaviour_change: $bc,
      cr_enabled: $cr,
      enforce: "block",
      feature: "hook enforcement layer",
      started: "2026-09-09T12:00:00Z",
      ended: null,
      base_sha: "2294917",
      phases: $phases,
      active: {},
      pending: {},
      rounds: {}
    }' > "$WV_STATE_DIR/$file"
  printf 'wrote %s\n' "$WV_STATE_DIR/$file"
}

all_done="$(done_map $PHASES)"

write_state full-all-done.json     full false false false "$all_done"
write_state full-all-done-ui.json  full true  false false "$all_done"
write_state full-all-done-cr.json  full false false true  "$all_done"
write_state demo-fresh.json        demo false false false '{}'
write_state demo-ac-done.json      demo false false false "$(done_map AC)"
write_state demo-through-green.json demo true false false "$(done_map AC DR TDE-RED TDE-GREEN)"
write_state solo.json              solo false false false '{}'
write_state wave-number.json       full false false false '{}' '1'

# Distinct file names written, so a deliberate re-emission (one fixture is
# emitted twice, the second time with its negative_control_for field set) is
# counted once and the closing line matches the number of files on disk.
count=0
declare -A wv_seen=()

mk() {
  # mk key=value ... ; keys: name ac note state desc prompt promptjson model
  # subagent agent tool cmd noinput seed expect
  #
  # `promptjson` sends tool_input.prompt as raw JSON rather than as a string,
  # for the two cases that measure what happens when the client sends a
  # non-string there (AC-185). It wins over `prompt` when both are given.
  local name="" ac="" note="" state="state/full-all-done.json"
  local desc="@absent" prompt="Do the thing." promptjson="" model="@absent"
  local subagent="general-purpose" agent="" tool="Agent" cmd=""
  local noinput="" seed="" expect="{}" event="PreToolUse"
  local kv k v
  for kv in "$@"; do
    [ -z "$kv" ] && continue
    k="${kv%%=*}"; v="${kv#*=}"
    case "$k" in
      name) name="$v" ;; ac) ac="$v" ;; note) note="$v" ;;
      state) state="$v" ;; desc) desc="$v" ;; prompt) prompt="$v" ;;
      promptjson) promptjson="$v" ;;
      model) model="$v" ;; subagent) subagent="$v" ;; agent) agent="$v" ;;
      tool) tool="$v" ;; cmd) cmd="$v" ;; noinput) noinput="$v" ;;
      seed) seed="$v" ;; expect) expect="$v" ;; event) event="$v" ;;
      *) printf 'mk: unknown key %s\n' "$k" >&2; return 1 ;;
    esac
  done
  [ -n "$name" ] || { printf 'mk: name is required\n' >&2; return 1; }

  local ti='{}'
  if [ -n "$noinput" ]; then
    ti='@none'
  else
    [ "$desc" = "@absent" ]  || ti="$(printf '%s' "$ti" | jq --arg v "$desc" '. + {description: $v}')"
    if [ -n "$promptjson" ]; then
      ti="$(printf '%s' "$ti" | jq --argjson v "$promptjson" '. + {prompt: $v}')"
    else
      [ "$prompt" = "@absent" ] || ti="$(printf '%s' "$ti" | jq --arg v "$prompt" '. + {prompt: $v}')"
    fi
    [ "$subagent" = "@absent" ] || ti="$(printf '%s' "$ti" | jq --arg v "$subagent" '. + {subagent_type: $v}')"
    [ -n "$cmd" ] && ti="$(printf '%s' "$ti" | jq --arg v "$cmd" '. + {command: $v}')"
    case "$model" in
      @absent) : ;;
      @empty)  ti="$(printf '%s' "$ti" | jq '. + {model: ""}')" ;;
      *)       ti="$(printf '%s' "$ti" | jq --arg v "$model" '. + {model: $v}')" ;;
    esac
  fi

  local stdin_json
  stdin_json="$(jq -n --arg tool "$tool" --arg event "$event" '{
      session_id: "1a2b0599-4617-4e73-a9c0-2bef462b2626",
      transcript_path: "/tmp/wave-plugin-tests/transcript.jsonl",
      cwd: ".",
      prompt_id: "c1f033ea-e4ee-4474-88ec-3913700ae39d",
      permission_mode: "bypassPermissions",
      hook_event_name: $event,
      tool_name: $tool,
      tool_use_id: "toolu_01RXAwe6jcU5LBKHd9geD6sE"
    }')"
  if [ -n "$agent" ]; then
    stdin_json="$(printf '%s' "$stdin_json" | jq --arg a "$agent" '. + {agent_id: $a, agent_type: "general-purpose"}')"
  fi
  if [ "$ti" != "@none" ]; then
    stdin_json="$(printf '%s' "$stdin_json" | jq --argjson ti "$ti" '. + {tool_input: $ti}')"
  fi

  local case_json
  case_json="$(jq -n \
    --arg ac "$ac" --arg note "$note" --arg state "$state" \
    --argjson stdin "$stdin_json" --argjson expect "$expect" \
    '{ac: $ac, note: $note, script: "pre-agent.sh", seed: {state: $state}, stdin: $stdin, expect: $expect}')"
  if [ "$state" = "@none" ]; then
    case_json="$(printf '%s' "$case_json" | jq 'del(.seed.state)')"
  fi
  if [ -n "$seed" ]; then
    case_json="$(printf '%s' "$case_json" | jq --argjson f "$seed" '.seed.files = $f')"
  fi
  printf '%s\n' "$case_json" | jq . > "$WV_CASES_DIR/$name.json"
  if [ -z "${wv_seen[$name]:-}" ]; then
    wv_seen["$name"]=1
    count=$((count + 1))
  fi
}

# The nine rule ids this task owns; a valid dispatch must fire none of them.
NOFIRE='["W-TAG","W-NESTED","W-FORK","W-MODE","W-ROLE","W-MODEL-MISSING","W-TIER","W-MODEL-UNKNOWN","W-DESC"]'

GRAMMAR='[W:<wave> P:<PHASE> R:<lead|executor|reviewer|scanner|writer>]'

# ---------------------------------------------------------------------------
# A. The tag (AC-2, 21, 22, 34-56)
# ---------------------------------------------------------------------------

mk name=tag-002-no-wave-silent ac=AC-2 \
  note='no .wave/state.json at all: an untagged, model-less dispatch is a silent no-op (neither W-TAG nor W-MODEL-MISSING).' \
  state=@none desc='implement the executor slice' model=@absent \
  expect='{"exit":0,"decision":"silent"}'

mk name=tag-021-wave-json-number-allow ac=AC-21 \
  note='state.wave is the JSON number 1; the tag says W:1 -> the decimal values are equal, so no W-TAG.' \
  state=state/wave-number.json desc='[W:1 P:AC R:lead] write the ACs' model=opus \
  expect='{"exit":0,"decision":"silent","negative_control_for":"W-TAG"}'

mk name=tag-022-wave-leading-zero-deny ac=AC-22 \
  note='state.wave is the string "1" and the tag says W:01 -> denied, and the reason names both 01 and 1 (no numeric coercion).' \
  desc='[W:01 P:AC R:lead] x' model=opus \
  expect='{"exit":0,"decision":"deny","rule":"W-TAG","reason_template":"W-TAG","reason_contains":["W:1","W:01"]}'

mk name=tag-034a-other-tool-silent ac=AC-34 \
  note='tool_name Bash on an active wave: silent no-op. Paired with tag-034b, which is the same fixture with tool_name Agent.' \
  tool=Bash desc='implement AC-3..AC-7' cmd='git status' model=@absent subagent=@absent \
  expect='{"exit":0,"decision":"silent","negative_control_for":"W-TAG"}'

mk name=tag-034b-agent-tool-deny ac=AC-34 \
  note='the tag-034a fixture with tool_name Agent (all else identical): the untagged dispatch is denied. The pair is the assertion.' \
  tool=Agent desc='implement AC-3..AC-7' cmd='git status' model=@absent subagent=@absent \
  expect='{"exit":0,"decision":"deny","rule":"W-TAG","reason_template":"W-TAG"}'

mk name=tag-035-no-tool-input-silent ac=AC-35 \
  note='valid stdin, tool_name Agent, no tool_input key: nothing to judge, so a silent no-op.' \
  noinput=1 \
  expect='{"exit":0,"decision":"silent","negative_control_for":"W-TAG"}'

mk name=tag-036-no-description-deny ac=AC-36 \
  note='tool_input present with neither description nor prompt: W-TAG, and the reason says no description was sent and quotes the grammar.' \
  desc=@absent prompt=@absent model=opus \
  expect='{"exit":0,"decision":"deny","rule":"W-TAG","reason_template":"W-TAG","reason_contains":["no description was sent","'"$GRAMMAR"'"]}'

mk name=tag-037-untagged-deny ac=AC-37 \
  note='an untagged description on an active full-mode wave: W-TAG, reason carries the literal grammar template.' \
  desc='implement AC-3..AC-7' model=opus \
  expect='{"exit":0,"decision":"deny","rule":"W-TAG","reason_template":"W-TAG","reason_contains":["'"$GRAMMAR"'"]}'

mk name=tag-038-tagged-allow ac=AC-38 \
  note='the AC-37 description with the tag prefixed and a valid model: silent allow. Negative control for W-TAG.' \
  desc='[W:1 P:TDE-GREEN R:executor] implement AC-3..AC-7' model=sonnet \
  expect='{"exit":0,"decision":"silent","negative_control_for":"W-TAG","stdout_absent":'"$NOFIRE"'}'

mk name=tag-039-lowercase-phase-deny ac=AC-39 \
  note='P:tde-green (lower case): the phase code is case-sensitive, so the grammar does not match.' \
  desc='[W:1 P:tde-green R:executor] x' model=sonnet \
  expect='{"exit":0,"decision":"deny","rule":"W-TAG","reason_template":"W-TAG"}'

mk name=tag-040-role-omitted-deny ac=AC-40 \
  note='R: field omitted entirely: the grammar requires it.' \
  desc='[W:1 P:TDE-GREEN] x' model=sonnet \
  expect='{"exit":0,"decision":"deny","rule":"W-TAG","reason_template":"W-TAG"}'

mk name=tag-041-unknown-role-deny ac=AC-41 \
  note='R:coder: the reason lists the five allowed roles (grammar) and cites hooks/roles.tsv for the framework role names.' \
  desc='[W:1 P:TDE-GREEN R:coder] x' model=sonnet \
  expect='{"exit":0,"decision":"deny","rule":"W-TAG","reason_template":"W-TAG","reason_contains":["R:coder","hooks/roles.tsv","lead|executor|reviewer|scanner|writer"]}'

mk name=tag-042-brackets-missing-deny ac=AC-42 \
  note='the tag text without its brackets is not a tag.' \
  desc='W:1 P:TDE-GREEN R:executor x' model=sonnet \
  expect='{"exit":0,"decision":"deny","rule":"W-TAG","reason_template":"W-TAG"}'

mk name=tag-043-prefix-before-tag-deny ac=AC-43 \
  note='a 7-byte prefix before the tag: the grammar is anchored at byte 0 and the reason quotes those 7 bytes.' \
  desc='prefix [W:1 P:TDE-GREEN R:executor] x' model=sonnet \
  expect='{"exit":0,"decision":"deny","rule":"W-TAG","reason_template":"W-TAG","reason_contains":["byte 0","\"prefix \""]}'

mk name=tag-044-leading-space-deny ac=AC-44 \
  note='one leading space before the tag: whitespace is not trimmed, and the reason quotes the offending prefix.' \
  desc=' [W:1 P:AC R:lead] x' model=opus \
  expect='{"exit":0,"decision":"deny","rule":"W-TAG","reason_template":"W-TAG","reason_contains":["byte 0","\" \""]}'

mk name=tag-045-emoji-prefix-deny ac=AC-45 \
  note='a multi-byte emoji before the tag: still not byte 0.' \
  desc='🚀 [W:1 P:AC R:lead] x' model=opus \
  expect='{"exit":0,"decision":"deny","rule":"W-TAG","reason_template":"W-TAG","reason_contains":["byte 0","🚀"]}'

mk name=tag-046-capitalised-role-deny ac=AC-46 \
  note='R:Lead: the role enum is case-sensitive, and the reason lists the five lower-case roles.' \
  desc='[W:1 P:AC R:Lead] x' model=opus \
  expect='{"exit":0,"decision":"deny","rule":"W-TAG","reason_template":"W-TAG","reason_contains":["R:Lead","lead|executor|reviewer|scanner|writer"]}'

mk name=tag-047a-double-space-deny ac=AC-47 \
  note='two spaces between tag fields: exactly one U+0020 is allowed.' \
  desc='[W:1  P:AC  R:lead] x' model=opus \
  expect='{"exit":0,"decision":"deny","rule":"W-TAG","reason_template":"W-TAG"}'

mk name=tag-047b-tab-inside-tag-deny ac=AC-47 \
  note='a tab where the single space belongs: not a space, so the grammar does not match.' \
  desc="$(printf '[W:1\tP:AC R:lead] x')" model=opus \
  expect='{"exit":0,"decision":"deny","rule":"W-TAG","reason_template":"W-TAG"}'

mk name=tag-048-no-summary-allow ac=AC-48 \
  note='the tag with no summary text after it: a summary is not part of the grammar, so this is a silent allow.' \
  desc='[W:1 P:AC R:lead]' model=opus \
  expect='{"exit":0,"decision":"silent","negative_control_for":"W-TAG","stdout_absent":'"$NOFIRE"'}'

mk name=tag-049-wrong-wave-deny ac=AC-49 \
  note='the tag names wave 2 while the active wave is 1: denied, and the reason names the active wave id.' \
  desc='[W:2 P:AC R:lead] x' model=opus \
  expect='{"exit":0,"decision":"deny","rule":"W-TAG","reason_template":"W-TAG","reason_contains":["W:1","W:2"]}'

mk name=tag-050-unknown-phase-deny ac=AC-50 \
  note='P:NOPE is not a row of hooks/phases.tsv: denied, and the reason names NOPE and the file.' \
  desc='[W:1 P:NOPE R:lead] x' model=opus \
  expect='{"exit":0,"decision":"deny","rule":"W-TAG","reason_template":"W-TAG","reason_contains":["P:NOPE","hooks/phases.tsv"]}'

mk name=tag-051-json-injection-deny ac=AC-51 \
  note='a description carrying a double quote, a backslash and a literal newline: denied, stdout is exactly one JSON object, and the offending text reaches the reason JSON-escaped.' \
  desc='[W:1 P:AC R:"lead\] x
second line' model=opus \
  expect='{"exit":0,"decision":"deny","rule":"W-TAG","reason_template":"W-TAG","reason_contains":["R:\"lead\\"]}'

mk name=tag-052-shell-injection-deny ac=AC-52 \
  note='a description carrying $(touch pwn) and `id`: denied, pwn is never created, and no substitution output (uid=) reaches the reason - hook input is data, never shell.' \
  desc='[W:1 P:$(touch pwn) R:`id`] x' model=opus \
  expect='{"exit":0,"decision":"deny","rule":"W-TAG","reason_template":"W-TAG","files_absent":["pwn"],"stdout_absent":["uid="]}'

mk name=tag-053-prompt-first-line-allow ac=AC-53 \
  note='the description is untagged and the prompt FIRST line carries the tag: accepted, silent allow.' \
  desc='implement the executor slice' \
  prompt='[W:1 P:TDE-GREEN R:executor]
Implement the slice described in .wave/ac.md.' \
  model=sonnet \
  expect='{"exit":0,"decision":"silent","negative_control_for":"W-TAG","stdout_absent":'"$NOFIRE"'}'

mk name=tag-054-prompt-line-three-deny ac=AC-54 \
  note='the tag is on line 3 of the prompt and nowhere else: only the first line is read, so denied.' \
  desc='implement the executor slice' \
  prompt='Please do the work.
Details below.
[W:1 P:TDE-GREEN R:executor]' \
  model=sonnet \
  expect='{"exit":0,"decision":"deny","rule":"W-TAG","reason_template":"W-TAG","reason_contains":["first line"]}'

DESC121="[W:1 P:AC R:lead] $(printf 'x%.0s' $(seq 1 103))"
DESC120="[W:1 P:AC R:lead] $(printf 'x%.0s' $(seq 1 102))"
mk name=tag-055-desc-121-warn ac=AC-55 \
  note='a valid tagged dispatch whose description is 121 characters: allowed, with a W-DESC warning naming 121 and the 120 cap.' \
  desc="$DESC121" model=opus \
  expect='{"exit":0,"decision":"warn","rule":"W-DESC","reason_template":"W-DESC","reason_contains":["121","120-char"]}'

mk name=tag-056-desc-120-allow ac=AC-56 \
  note='the same dispatch with a 120-character description: silent allow, no W-DESC. Boundary negative control.' \
  desc="$DESC120" model=opus \
  expect='{"exit":0,"decision":"silent","negative_control_for":"W-DESC","stdout_absent":'"$NOFIRE"'}'

# ---------------------------------------------------------------------------
# B. Nested dispatch and fork (AC-57-62)
# ---------------------------------------------------------------------------

mk name=nested-057-agent-id-deny ac=AC-57 \
  note='stdin carries the measured in-subagent shape (agent_id + agent_type): W-NESTED, naming the agent and telling it to return its result.' \
  agent=a6a129f2ae0850db1 desc='[W:1 P:AC R:lead] write the ACs' model=opus \
  expect='{"exit":0,"decision":"deny","rule":"W-NESTED","reason_template":"W-NESTED","reason_contains":["a6a129f2ae0850db1","single dispatcher"]}'

mk name=nested-058-main-session-allow ac=AC-58 \
  note='the nested-057 fixture with agent_id and agent_type removed: silent allow. Isolates the discriminator.' \
  desc='[W:1 P:AC R:lead] write the ACs' model=opus \
  expect='{"exit":0,"decision":"silent","negative_control_for":"W-NESTED","stdout_absent":'"$NOFIRE"'}'

mk name=nested-059-valid-tag-still-deny ac=AC-59 \
  note='a nested dispatch whose tag and model are both valid: still W-NESTED, and the reason carries only that one W- token.' \
  agent=a6a129f2ae0850db1 desc='[W:1 P:TDE-GREEN R:executor] implement the slice' model=sonnet \
  expect='{"exit":0,"decision":"deny","rule":"W-NESTED","reason_template":"W-NESTED"}'

mk name=fork-060-deny ac=AC-60 \
  note='subagent_type fork on an otherwise valid main-session dispatch: W-FORK, whose reason states the context inheritance, the un-routable model and the remedy.' \
  desc='[W:1 P:AC R:lead] write the ACs' model=opus subagent=fork \
  expect='{"exit":0,"decision":"deny","rule":"W-FORK","reason_template":"W-FORK","reason_contains":["inherits orchestrator context","cannot be model-routed","dispatch a typed subagent"]}'

mk name=fork-061-typed-subagent-allow ac=AC-61 \
  note='the fork-060 dispatch with subagent_type general-purpose: silent allow.' \
  desc='[W:1 P:AC R:lead] write the ACs' model=opus subagent=general-purpose \
  expect='{"exit":0,"decision":"silent","negative_control_for":"W-FORK","stdout_absent":'"$NOFIRE"'}'

mk name=fork-062-subagent-absent-allow ac=AC-62 \
  note='the same dispatch with subagent_type absent: the harness default is not a fork, and an absent optional field is never a violation.' \
  desc='[W:1 P:AC R:lead] write the ACs' model=opus subagent=@absent \
  expect='{"exit":0,"decision":"silent","negative_control_for":"W-FORK","stdout_absent":'"$NOFIRE"'}'

# ---------------------------------------------------------------------------
# C. Mode gating (AC-63-66)
# ---------------------------------------------------------------------------

mk name=mode-063-demo-full-only-deny ac=AC-63 \
  note='a demo wave dispatching BC (modes=full): W-MODE naming BC as full-mode only, the active mode, and the five demo phases.' \
  state=state/demo-ac-done.json desc='[W:1 P:BC R:executor] scan for bugs' model=sonnet \
  expect='{"exit":0,"decision":"deny","rule":"W-MODE","reason_template":"W-MODE","reason_contains":["BC is full-mode only","in demo mode","AC, DR, TDE-RED, TDE-GREEN, TEET"]}'

mk name=mode-064-demo-ac-allow ac=AC-64 \
  note='a demo wave dispatching AC (modes=full,demo) with an empty phases map: silent allow, no W-MODE.' \
  state=state/demo-fresh.json desc='[W:1 P:AC R:lead] write the ACs' model=opus \
  expect='{"exit":0,"decision":"silent","negative_control_for":"W-MODE","stdout_absent":'"$NOFIRE"'}'

mk name=mode-065-full-ac-allow ac=AC-65 \
  note='a full wave dispatching AC with an empty phases map: silent allow, no W-MODE.' \
  state=state/valid-full.json desc='[W:1 P:AC R:lead] write the ACs' model=opus \
  expect='{"exit":0,"decision":"silent","negative_control_for":"W-MODE","stdout_absent":'"$NOFIRE"'}'

mk name=mode-066-demo-teet-allow ac=AC-66 \
  note='a demo wave with ui true, AC+DR+TDE-RED+TDE-GREEN done and the green-visual approval present, dispatching TEET: silent allow (no W-MODE, and no W-ORDER once Task 6 lands).' \
  state=state/demo-through-green.json desc='[W:1 P:TEET R:executor] run the end-to-end suite' model=sonnet \
  seed='{".wave/approvals/green-visual.md":"Reviewed .wave/screenshots/green-*.png; approved.\n"}' \
  expect='{"exit":0,"decision":"silent","stdout_absent":'"$NOFIRE"'}'

# ---------------------------------------------------------------------------
# D. Role resolution and the W-ROLE deny (AC-113-117, 137, 138)
# ---------------------------------------------------------------------------

mk name=role-115-bc-reviewer-deny ac='AC-115, AC-138' \
  note='BC defines no reviewer (the cell is -): W-ROLE stating the role does not exist in BC and listing executor with scanner/writer as its aliases.' \
  desc='[W:1 P:BC R:reviewer] review the scan' model=opus \
  expect='{"exit":0,"decision":"deny","rule":"W-ROLE","reason_template":"W-ROLE","reason_contains":["role reviewer does not exist in BC","executor (aliases: scanner, writer)","hooks/roles.tsv"]}'

mk name=role-116-bc-lead-deny ac='AC-116, AC-138' \
  note='BC defines no lead: W-ROLE listing the roles that do exist.' \
  desc='[W:1 P:BC R:lead] lead the scan' model=opus \
  expect='{"exit":0,"decision":"deny","rule":"W-ROLE","reason_template":"W-ROLE","reason_contains":["role lead does not exist in BC","executor (aliases: scanner, writer)"]}'

mk name=role-117a-vb-lead-deny ac=AC-117 \
  note='VB is -/haiku/-: a lead dispatch is W-ROLE.' \
  desc='[W:1 P:VB R:lead] bump the version' model=opus \
  expect='{"exit":0,"decision":"deny","rule":"W-ROLE","reason_template":"W-ROLE","reason_contains":["role lead does not exist in VB"]}'

mk name=role-117b-ad-reviewer-deny ac=AC-117 \
  note='AD is -/haiku/-: a reviewer dispatch is W-ROLE.' \
  desc='[W:1 P:AD R:reviewer] review the dashboard' model=opus \
  expect='{"exit":0,"decision":"deny","rule":"W-ROLE","reason_template":"W-ROLE","reason_contains":["role reviewer does not exist in AD"]}'

mk name=role-137a-cr-lead-deny ac=AC-137 \
  note='CR is -/-/sonnet: a lead dispatch is W-ROLE whatever the model.' \
  state=state/full-all-done-cr.json desc='[W:1 P:CR R:lead] lead the code review' model=opus \
  expect='{"exit":0,"decision":"deny","rule":"W-ROLE","reason_template":"W-ROLE","reason_contains":["role lead does not exist in CR","reviewer"]}'

mk name=role-137b-cr-executor-deny ac=AC-137 \
  note='CR defines no executor either: W-ROLE.' \
  state=state/full-all-done-cr.json desc='[W:1 P:CR R:executor] run the code review' model=sonnet \
  expect='{"exit":0,"decision":"deny","rule":"W-ROLE","reason_template":"W-ROLE","reason_contains":["role executor does not exist in CR"]}'

mk name=role-138a-sea-lead-deny ac=AC-138 \
  note='SEA is -/sonnet/-: a lead dispatch is W-ROLE.' \
  desc='[W:1 P:SEA R:lead] lead the silent-error scan' model=opus \
  expect='{"exit":0,"decision":"deny","rule":"W-ROLE","reason_template":"W-ROLE","reason_contains":["role lead does not exist in SEA"]}'

mk name=role-138b-sea-reviewer-deny ac=AC-138 \
  note='SEA defines no reviewer: W-ROLE.' \
  desc='[W:1 P:SEA R:reviewer] review the silent-error scan' model=opus \
  expect='{"exit":0,"decision":"deny","rule":"W-ROLE","reason_template":"W-ROLE","reason_contains":["role reviewer does not exist in SEA"]}'

mk name=role-138c-ds-lead-deny ac=AC-138 \
  note='DS is -/sonnet/-: a lead dispatch is W-ROLE.' \
  desc='[W:1 P:DS R:lead] lead the dependency scan' model=opus \
  expect='{"exit":0,"decision":"deny","rule":"W-ROLE","reason_template":"W-ROLE","reason_contains":["role lead does not exist in DS"]}'

mk name=role-138d-ds-reviewer-deny ac=AC-138 \
  note='DS defines no reviewer: W-ROLE.' \
  desc='[W:1 P:DS R:reviewer] review the dependency scan' model=opus \
  expect='{"exit":0,"decision":"deny","rule":"W-ROLE","reason_template":"W-ROLE","reason_contains":["role reviewer does not exist in DS"]}'

# ---------------------------------------------------------------------------
# E. Model presence (AC-118-121) and the unknown-model warning (AC-122-131)
# ---------------------------------------------------------------------------

mk name=model-118-absent-deny ac=AC-118 \
  note='no model key at all (the measured shape when the caller omits it): W-MODEL-MISSING naming the phase, the role, the four tier names and the minimum.' \
  desc='[W:1 P:AC R:lead] write the ACs' model=@absent \
  expect='{"exit":0,"decision":"deny","rule":"W-MODEL-MISSING","reason_template":"W-MODEL-MISSING","reason_contains":["<haiku|sonnet|opus|fable>","minimum for AC/lead: opus"]}'

mk name=model-119-inherit-deny ac=AC-119 \
  note='model "inherit": W-MODEL-MISSING naming inherit explicitly.' \
  desc='[W:1 P:AC R:lead] write the ACs' model=inherit \
  expect='{"exit":0,"decision":"deny","rule":"W-MODEL-MISSING","reason_template":"W-MODEL-MISSING","reason_contains":["inherit"]}'

mk name=model-120-empty-deny ac=AC-120 \
  note='model "": W-MODEL-MISSING.' \
  desc='[W:1 P:AC R:lead] write the ACs' model=@empty \
  expect='{"exit":0,"decision":"deny","rule":"W-MODEL-MISSING","reason_template":"W-MODEL-MISSING"}'

mk name=model-121-ad-executor-haiku-allow ac=AC-121 \
  note='AD requires executor >= haiku and the dispatch names haiku: silent allow, and stdout carries no W-MODEL-MISSING. Negative control for AC-118..120.' \
  state=state/valid-full.json desc='[W:1 P:AD R:executor] update the dashboard' model=haiku \
  expect='{"exit":0,"decision":"silent","negative_control_for":"W-MODEL-MISSING","stdout_absent":'"$NOFIRE"'}'

mk name=model-122-unmapped-warn ac=AC-122 \
  note='model gpt-5 matches no tier token: allow + W-MODEL-UNKNOWN naming the four known tokens - a gap in our table is never a NO-GO.' \
  desc='[W:1 P:AC R:lead] write the ACs' model=gpt-5 \
  expect='{"exit":0,"decision":"warn","rule":"W-MODEL-UNKNOWN","reason_template":"W-MODEL-UNKNOWN","reason_contains":["gpt-5","haiku, sonnet, opus, fable"]}'

mk name=model-123-two-tokens-warn ac=AC-123 \
  note='claude-sonnet-opus-preview matches two distinct tier tokens: allow + W-MODEL-UNKNOWN naming the ambiguity and both matches, never silently picking one.' \
  desc='[W:1 P:AC R:lead] write the ACs' model=claude-sonnet-opus-preview \
  expect='{"exit":0,"decision":"warn","rule":"W-MODEL-UNKNOWN","reason_template":"W-MODEL-UNKNOWN","reason_contains":["ambiguous","sonnet","opus"]}'

mk name=model-124-substring-only-warn ac=AC-124 \
  note='opusless-1 contains opus but not as a token delimited by non-alphanumerics: no tier is granted, so allow + W-MODEL-UNKNOWN.' \
  desc='[W:1 P:AC R:lead] write the ACs' model=opusless-1 \
  expect='{"exit":0,"decision":"warn","rule":"W-MODEL-UNKNOWN","reason_template":"W-MODEL-UNKNOWN","reason_contains":["opusless-1"]}'

mk name=model-125a-opusplan-warn ac=AC-125 \
  note='opusplan is declared unknown in hooks/models.tsv: allow + W-MODEL-UNKNOWN naming that row.' \
  desc='[W:1 P:AC R:lead] write the ACs' model=opusplan \
  expect='{"exit":0,"decision":"warn","rule":"W-MODEL-UNKNOWN","reason_template":"W-MODEL-UNKNOWN","reason_contains":["opusplan","hooks/models.tsv declares"]}'

mk name=model-125b-default-warn ac=AC-125 \
  note='default is declared unknown in hooks/models.tsv: allow + W-MODEL-UNKNOWN naming that row.' \
  desc='[W:1 P:AC R:lead] write the ACs' model=default \
  expect='{"exit":0,"decision":"warn","rule":"W-MODEL-UNKNOWN","reason_template":"W-MODEL-UNKNOWN","reason_contains":["default","hooks/models.tsv declares"]}'

mk name=model-126-fable-full-id-allow ac=AC-126 \
  note='claude-fable-1-20260501 maps to tier 4, above AC/lead: silent allow with no W-MODEL-UNKNOWN. Negative control for AC-122..125.' \
  desc='[W:1 P:AC R:lead] write the ACs' model=claude-fable-1-20260501 \
  expect='{"exit":0,"decision":"silent","negative_control_for":"W-MODEL-UNKNOWN","stdout_absent":'"$NOFIRE"'}'

mk name=model-127a-capitalised-allow ac=AC-127 \
  note='model "Sonnet" for TDE-GREEN/executor: the token map lowercases first, so this is not a false W-MODEL-UNKNOWN.' \
  desc='[W:1 P:TDE-GREEN R:executor] implement the slice' model=Sonnet \
  expect='{"exit":0,"decision":"silent","stdout_absent":'"$NOFIRE"'}'

mk name=model-127b-uppercase-allow ac=AC-127 \
  note='model "SONNET" for TDE-GREEN/executor: same, upper case.' \
  desc='[W:1 P:TDE-GREEN R:executor] implement the slice' model=SONNET \
  expect='{"exit":0,"decision":"silent","stdout_absent":'"$NOFIRE"'}'

mk name=model-128-surrounding-space-allow ac=AC-128 \
  note='model " opus " for AC/lead: surrounding whitespace is trimmed before the map.' \
  desc='[W:1 P:AC R:lead] write the ACs' model=' opus ' \
  expect='{"exit":0,"decision":"silent","stdout_absent":'"$NOFIRE"'}'

mk name=model-129-bracket-suffix-allow ac=AC-129 \
  note='model claude-opus-5[1m] for AC/lead: a bracketed context suffix does not defeat the map.' \
  desc='[W:1 P:AC R:lead] write the ACs' model='claude-opus-5[1m]' \
  expect='{"exit":0,"decision":"silent","stdout_absent":'"$NOFIRE"'}'

mk name=model-130a-full-sonnet-id-allow ac=AC-130 \
  note='claude-sonnet-4-5-20250929 for TDE-GREEN/executor (tier 2 = the minimum): silent allow.' \
  desc='[W:1 P:TDE-GREEN R:executor] implement the slice' model=claude-sonnet-4-5-20250929 \
  expect='{"exit":0,"decision":"silent","stdout_absent":'"$NOFIRE"'}'

mk name=model-130b-full-haiku-id-deny ac=AC-130 \
  note='claude-haiku-4-5-20251001 (the exact id the probe recorded as resolvedModel) for TDE-GREEN/executor: W-TIER.' \
  desc='[W:1 P:TDE-GREEN R:executor] implement the slice' model=claude-haiku-4-5-20251001 \
  expect='{"exit":0,"decision":"deny","rule":"W-TIER","reason_template":"W-TIER","reason_contains":["model claude-haiku-4-5-20251001 (tier 1) is below TDE-GREEN/executor minimum (sonnet)"]}'

mk name=model-131a-above-minimum-allow ac=AC-131 \
  note='opus for TDE-GREEN/executor (minimum sonnet): a higher tier always passes - the never-degrade rule.' \
  desc='[W:1 P:TDE-GREEN R:executor] implement the slice' model=opus \
  expect='{"exit":0,"decision":"silent","stdout_absent":'"$NOFIRE"'}'

mk name=model-131b-fable-above-opus-allow ac=AC-131 \
  note='fable for AC/lead (minimum opus): tier 4 is above tier 3, so it passes.' \
  desc='[W:1 P:AC R:lead] write the ACs' model=fable \
  expect='{"exit":0,"decision":"silent","stdout_absent":'"$NOFIRE"'}'

# ---------------------------------------------------------------------------
# F. The scanner/writer alias map (AC-113, 114)
# ---------------------------------------------------------------------------

mk name=tier-113a-bc-scanner-sonnet-allow ac=AC-113 \
  note='R:scanner resolves to the row executor cell: BC/executor is sonnet, so sonnet is allowed.' \
  desc='[W:1 P:BC R:scanner] scan for bugs' model=sonnet \
  expect='{"exit":0,"decision":"silent","negative_control_for":"W-ROLE","stdout_absent":'"$NOFIRE"'}'

mk name=tier-113b-bc-scanner-haiku-deny ac=AC-113 \
  note='the same scanner dispatch with haiku: W-TIER naming BC/scanner (the tag role) and the sonnet requirement from the executor cell.' \
  desc='[W:1 P:BC R:scanner] scan for bugs' model=haiku \
  expect='{"exit":0,"decision":"deny","rule":"W-TIER","reason_template":"W-TIER","reason_contains":["model haiku (tier 1) is below BC/scanner minimum (sonnet)"]}'

mk name=tier-114a-ad-writer-haiku-allow ac=AC-114 \
  note='R:writer resolves to the executor cell: AD/executor is haiku, so haiku is allowed.' \
  state=state/valid-full.json desc='[W:1 P:AD R:writer] write the dashboard' model=haiku \
  expect='{"exit":0,"decision":"silent","stdout_absent":'"$NOFIRE"'}'

mk name=tier-114b-ac-writer-haiku-deny ac=AC-114 \
  note='AC-114 asks for AC/writer with sonnet to deny, but hooks/phases.tsv gives AC/executor = sonnet and spec section 5 maps writer to the executor cell, so sonnet is exactly the minimum and must allow (see tier-114c). This case pins the clause intent - writer resolves to a real tier and is never silently exempt - with haiku, one tier below.' \
  desc='[W:1 P:AC R:writer] draft the ACs' model=haiku \
  expect='{"exit":0,"decision":"deny","rule":"W-TIER","reason_template":"W-TIER","reason_contains":["model haiku (tier 1) is below AC/writer minimum (sonnet)"]}'

mk name=tier-114c-ac-writer-sonnet-allow ac=AC-114 \
  note='the measured behaviour of the clause AC-114 states as a deny: AC/writer maps to the executor cell (sonnet), so sonnet is exactly the minimum and is allowed. Recorded so the conflict with AC-114 is visible in the corpus rather than only in the report.' \
  desc='[W:1 P:AC R:writer] draft the ACs' model=sonnet \
  expect='{"exit":0,"decision":"silent","stdout_absent":'"$NOFIRE"'}'

# ---------------------------------------------------------------------------
# G. The per-cell tier matrix (AC-132-145, plus the BF-SEA / BF-DS / BF-TEET
#    cells the brief's AC list does not name, so that all 60 non-`-` cells of
#    hooks/phases.tsv carry a tier case - AC-146's mutation control needs it).
# ---------------------------------------------------------------------------

lower_tier() {
  case "$1" in
    sonnet) printf 'haiku' ;;
    opus)   printf 'sonnet' ;;
    fable)  printf 'opus' ;;
    *)      printf '' ;;
  esac
}
tier_num() {
  case "$1" in haiku) printf 1 ;; sonnet) printf 2 ;; opus) printf 3 ;; fable) printf 4 ;; esac
}
phase_state() {
  case "$1" in
    DR) printf 'state/full-all-done-ui.json' ;;
    CR) printf 'state/full-all-done-cr.json' ;;
    *)  printf 'state/full-all-done.json' ;;
  esac
}
phase_seed() {
  # BF-<X> rows are conditional on findings:<X>; seed the findings file and the
  # per-phase bug-fix approval so the only rule left to fire is the tier rule.
  local src=""
  case "$1" in
    BF-BC) src=BC ;; BF-SEA) src=SEA ;; BF-DS) src=DS ;;
    BF-BSEA) src=BSEA ;; BF-TEET) src=TEET ;; BF-BTEET) src=BTEET ;;
    *) return 1 ;;
  esac
  jq -nc --arg f ".wave/findings/$src.md" --arg a ".wave/approvals/bf-$src.md" \
    '{($f): "FINDINGS: 2\n", ($a): "Strategy: fix both findings in one pass.\n"}'
}

lc() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

emit_cell() {
  # emit_cell <PHASE> <role> <required-tier> <ac-ids>
  local phase="$1" role="$2" need="$3" acids="$4"
  [ "$need" = "-" ] && return 0
  local st seed_json="" low
  st="$(phase_state "$phase")"
  seed_json="$(phase_seed "$phase" || true)"
  local -a seedarg=()
  [ -n "$seed_json" ] && seedarg=("seed=$seed_json")
  local p_lc; p_lc="$(lc "$phase")"

  mk name="tier-$p_lc-$role-$need-allow" ac="$acids" \
    note="$phase/$role requires $need; the dispatch names exactly $need, so this is a silent allow." \
    state="$st" desc="[W:1 P:$phase R:$role] work on $phase" model="$need" "${seedarg[@]:-}" \
    expect='{"exit":0,"decision":"silent","stdout_absent":'"$NOFIRE"'}'

  low="$(lower_tier "$need")"
  if [ -n "$low" ]; then
    mk name="tier-$p_lc-$role-$low-deny" ac="$acids" \
      note="$phase/$role requires $need; the dispatch names $low (one tier lower), so W-TIER fires naming the model, its tier, $phase/$role and the requirement." \
      state="$st" desc="[W:1 P:$phase R:$role] work on $phase" model="$low" "${seedarg[@]:-}" \
      expect='{"exit":0,"decision":"deny","rule":"W-TIER","reason_template":"W-TIER","reason_contains":["model '"$low"' (tier '"$(tier_num "$low")"') is below '"$phase"'/'"$role"' minimum ('"$need"')"]}'
  fi
}

# code lead executor reviewer ac-ids   (verbatim from hooks/phases.tsv)
while read -r code lead exe rev acids; do
  [ -z "$code" ] && continue
  emit_cell "$code" lead "$lead" "$acids"
  emit_cell "$code" executor "$exe" "$acids"
  emit_cell "$code" reviewer "$rev" "$acids"
done <<'ROWS'
AC opus sonnet opus AC-132
ACB opus opus opus AC-133
DR opus sonnet opus AC-134
TDE-RED sonnet sonnet sonnet AC-135
TDE-GREEN sonnet sonnet opus AC-136
CR - - sonnet AC-137
BC - sonnet - AC-138
BF-BC opus sonnet opus AC-139
SEA - sonnet - AC-138
BF-SEA opus sonnet opus AC-139 (extended: the brief's AC list names BF-BC and BF-BSEA; this row has the same triple and is added for AC-146 cell coverage)
DS - sonnet - AC-138
BF-DS opus sonnet opus AC-139 (extended for AC-146 cell coverage)
BSEA opus opus opus AC-140
BF-BSEA opus sonnet opus AC-139
OA opus opus opus AC-141
TEET-TC opus sonnet opus AC-142
TEET sonnet sonnet sonnet AC-143
BF-TEET opus sonnet opus AC-139 (extended for AC-146 cell coverage)
BTEET opus opus opus AC-140
BTEET-X sonnet sonnet sonnet AC-143
BF-BTEET opus sonnet opus AC-139 (extended for AC-146 cell coverage)
VB - haiku - AC-144
COMMIT - sonnet - AC-145
CL - sonnet - AC-145
CCP - sonnet - AC-145
AD - haiku - AC-144
ROWS

# The two designated negative controls that the coverage self-check needs for
# W-TIER and W-ROLE live on cells the matrix already emitted; re-emit them with
# the negative_control_for field set (same fixture, one extra assertion).
mk name=tier-ac-lead-opus-allow ac='AC-132' \
  note='AC/lead requires opus; the dispatch names exactly opus: silent allow. Negative control for W-TIER (the boundary case that kills an off-by-one comparison).' \
  desc='[W:1 P:AC R:lead] write the ACs' model=opus \
  expect='{"exit":0,"decision":"silent","negative_control_for":"W-TIER","stdout_absent":'"$NOFIRE"'}'

# ---------------------------------------------------------------------------
# H. Solo mode (AC-330, 334, 337, 338)
# ---------------------------------------------------------------------------

mk name=solo-dispatch-330-untagged-allow ac=AC-330 \
  note='solo mode, an untagged dispatch naming a model: allowed with no output. (The phase:"SOLO" ledger line is written at SubagentStop, not here.)' \
  state=state/solo.json desc='refactor the parser' model=sonnet \
  expect='{"exit":0,"decision":"silent","stdout_absent":'"$NOFIRE"'}'

mk name=solo-dispatch-334-no-model-deny ac=AC-334 \
  note='solo mode, no model key: W-MODEL-MISSING - the one dispatch rule solo keeps.' \
  state=state/solo.json desc='refactor the parser' model=@absent \
  expect='{"exit":0,"decision":"deny","rule":"W-MODEL-MISSING","reason_template":"W-MODEL-MISSING","reason_contains":["<haiku|sonnet|opus|fable>","solo"]}'

mk name=solo-dispatch-337-tagged-below-tier-allow ac=AC-337 \
  note='solo mode, a valid tag whose model is below the table tier for AC/lead: allowed, because hooks/phases.tsv is not consulted in solo.' \
  state=state/solo.json desc='[W:1 P:AC R:lead] write the ACs' model=haiku \
  expect='{"exit":0,"decision":"silent","stdout_absent":'"$NOFIRE"'}'

mk name=solo-dispatch-338a-nested-allow ac=AC-338 \
  note='solo mode, a nested dispatch (stdin carries agent_id): allowed - section 8.4 is full/demo only.' \
  state=state/solo.json agent=a6a129f2ae0850db1 desc='refactor the parser' model=sonnet \
  expect='{"exit":0,"decision":"silent","stdout_absent":'"$NOFIRE"'}'

mk name=solo-dispatch-338b-fork-allow ac=AC-338 \
  note='solo mode, subagent_type fork with a named model: allowed - the fork rule is full/demo only.' \
  state=state/solo.json desc='refactor the parser' model=sonnet subagent=fork \
  expect='{"exit":0,"decision":"silent","stdout_absent":'"$NOFIRE"'}'

# ---------------------------------------------------------------------------
# I. The no-wave / not-this-event short circuits (Global Constraint 3).
# ---------------------------------------------------------------------------

mk name=tag-002b-closed-wave-silent ac='AC-2 (companion: Global Constraint 3, asserted per script)' \
  note='a wave whose status is "closed": the same untagged, model-less dispatch is a silent no-op. No AC in this task'"'"'s list names the closed-wave path for pre-agent.sh, but Global Constraint 3 requires "no wave -> exit 0, no output" to be asserted per script, and an inactive wave is a no-wave.' \
  state=state/closed.json desc='implement the executor slice' model=@absent \
  expect='{"exit":0,"decision":"silent"}'

mk name=tag-event-post-tool-use-silent ac='AC-34 (companion: the event guard, controller ruling, fix round 1)' \
  note='hook_event_name PostToolUse with tool_name Agent on an active wave: silent no-op. This script is wired to PreToolUse only, and a PostToolUse payload carries a tool_response it must not judge - the deny channel does not even exist on that event.' \
  event=PostToolUse desc='implement AC-3..AC-7' model=@absent \
  expect='{"exit":0,"decision":"silent","negative_control_for":"W-TAG"}'

# ---------------------------------------------------------------------------
# J. AC-389: exactly one W- token per reason, even when the dispatch text
#    contains one. Every reason argument that comes from the dispatch or from
#    the state is a place a second token can enter; there is one case per
#    such place, and each asserts BOTH that the token count is still 1 (the
#    harness'"'"'s assert_single_rule_token, which runs on every case declaring
#    expect.rule) AND that the offending text is still named, neutralised.
# ---------------------------------------------------------------------------

mk name=tag-token-in-role-deny ac='AC-389, AC-41' \
  note='a W- token inside the role field: the bad-role diagnosis quotes the role, so the reason must neutralise it (W_FORK) and still carry exactly one W- token.' \
  desc='[W:1 P:AC R:lead W-FORK] bad' model=opus \
  expect='{"exit":0,"decision":"deny","rule":"W-TAG","reason_template":"W-TAG","reason_contains":["R:lead W_FORK"],"stdout_absent":["W-FORK"]}'

mk name=tag-token-in-excerpt-deny ac='AC-389, AC-39' \
  note='a W- token inside a malformed tag: the excerpt branch quotes the whole first line, so the token must be neutralised there too.' \
  desc='[W:1 P:AC W-TIER R:lead] x' model=opus \
  expect='{"exit":0,"decision":"deny","rule":"W-TAG","reason_template":"W-TAG","reason_contains":["[W:1 P:AC W_TIER R:lead] x"],"stdout_absent":["W-TIER"]}'

mk name=tag-token-in-prefix-deny ac='AC-389, AC-43' \
  note='a W- token in the bytes before a well-formed tag: the byte-0 diagnosis quotes that prefix.' \
  desc='W-MODE prefix [W:1 P:AC R:lead] x' model=opus \
  expect='{"exit":0,"decision":"deny","rule":"W-TAG","reason_template":"W-TAG","reason_contains":["\"W_MODE prefix \""],"stdout_absent":["W-MODE"]}'

mk name=tag-token-in-wave-deny ac='AC-389, AC-49' \
  note='a W- token as the tag'"'"'s wave id: the tag parses, the wave does not match, and the mismatch diagnosis quotes what the dispatch said.' \
  desc='[W:W-FORK P:AC R:lead] x' model=opus \
  expect='{"exit":0,"decision":"deny","rule":"W-TAG","reason_template":"W-TAG","reason_contains":["the dispatch said W:W_FORK"],"stdout_absent":["W-FORK"]}'

mk name=tag-token-in-phase-deny ac='AC-389, AC-50' \
  note='a W- token as the phase code: [A-Z0-9-]+ accepts it, so the unknown-phase diagnosis quotes it.' \
  desc='[W:1 P:W-TIER R:lead] x' model=opus \
  expect='{"exit":0,"decision":"deny","rule":"W-TAG","reason_template":"W-TAG","reason_contains":["P:W_TIER is not a row"],"stdout_absent":["W-TIER"]}'

mk name=nested-token-in-agent-id-deny ac='AC-389, AC-57' \
  note='a W- token as the agent id: the W-NESTED reason names the agent, and agent_id is whatever the client sends.' \
  agent=W-FORK desc='[W:1 P:AC R:lead] write the ACs' model=opus \
  expect='{"exit":0,"decision":"deny","rule":"W-NESTED","reason_template":"W-NESTED","reason_contains":["nested dispatch from agent W_FORK"],"stdout_absent":["W-FORK"]}'

mk name=tier-token-in-model-deny ac='AC-389, AC-132' \
  note='a W- token inside a model string that still maps to a tier (haiku): the W-TIER reason quotes the model as sent.' \
  desc='[W:1 P:AC R:lead] write the ACs' model=W-FORK-haiku \
  expect='{"exit":0,"decision":"deny","rule":"W-TIER","reason_template":"W-TIER","reason_contains":["model W_FORK-haiku (tier 1) is below AC/lead minimum (opus)"],"stdout_absent":["W-FORK"]}'

mk name=model-token-in-model-warn ac='AC-389, AC-122' \
  note='a W- token inside a model string that maps to nothing: the W-MODEL-UNKNOWN warning quotes it.' \
  desc='[W:1 P:AC R:lead] write the ACs' model=W-TIER \
  expect='{"exit":0,"decision":"warn","rule":"W-MODEL-UNKNOWN","reason_template":"W-MODEL-UNKNOWN","reason_contains":["model W_TIER (it matches no tier token)"],"stdout_absent":["W-TIER"]}'

# ===========================================================================
# PART 2 — order, conditions, scope, dispatch-time gates, rounds, budgets
# (Task 6). Everything below this line belongs to the part-2 corpus; the
# part-1 corpus above is untouched, and both are regenerated by one run so a
# hand edit to either half shows up as a byte diff.
# ===========================================================================

# The twelve rule ids part 2 owns. An allow case asserts that none of them
# reached stdout, so a rule that fires one phase too early is caught by the
# neighbouring allow rather than only by its own deny.
P2NOFIRE='["W-SCOPE","W-COND","W-ORDER","W-ARTIFACT","W-MARKER","W-DR-OPEN","W-VISUAL","W-BF-APPROVAL","W-ROUND","W-PASTE","W-BUDGET","W-PROMPT"]'

# The full-mode chain in `hooks/phases.tsv` file order. `p2_through` turns a
# phase code into "every row up to and including it", which is how a state
# fixture says "the wave has run this far". A skipped row (DR with ui false,
# CR with cr_enabled false) is still marked done: `wv_phase_done`
# short-circuits on status == "done" before it looks at the condition, so a
# fixture that over-marks cannot hide a condition bug.
P2_CHAIN="AC ACB DR TDE-RED TDE-GREEN CR BC BF-BC SEA BF-SEA DS BF-DS BSEA BF-BSEA OA TEET-TC TEET BF-TEET BTEET BTEET-X BF-BTEET VB COMMIT CL CCP"

p2_through() {
  # p2_through <code> -> the chain up to and including <code>
  local want="$1" c out=""
  for c in $P2_CHAIN; do
    out="${out:+$out }$c"
    [ "$c" = "$want" ] && break
  done
  printf '%s' "$out"
}

p2_state() {
  # p2_state <file> <mode> <ui> <bc> <cr> <rounds-json> <wave-json> [done...]
  # ui/bc/cr are JSON (`false`, `true` or `"unknown"`), not shell booleans:
  # spec section 4 makes "unknown" a first-class third value.
  local file="$1" mode="$2" ui="$3" bc="$4" cr="$5" rounds="$6" wave="$7"
  shift 7
  local phases
  phases="$(done_map "$@")"
  jq -n \
    --argjson wave "$wave" --arg mode "$mode" \
    --argjson ui "$ui" --argjson bc "$bc" --argjson cr "$cr" \
    --argjson phases "$phases" --argjson rounds "$rounds" \
    '{
      schema: 1,
      wave: $wave,
      mode: $mode,
      status: "active",
      ui: $ui,
      behaviour_change: $bc,
      cr_enabled: $cr,
      enforce: "block",
      feature: "hook enforcement layer",
      started: "2026-09-09T12:00:00Z",
      ended: null,
      base_sha: "2294917",
      phases: $phases,
      active: {},
      pending: {},
      rounds: $rounds
    }' > "$WV_STATE_DIR/$file"
  printf 'wrote %s\n' "$WV_STATE_DIR/$file"
}

# --- the part-2 wave states ------------------------------------------------

# AC-17: valid state with no `phases` key at all. Written through del() rather
# than as a separate literal so it cannot drift from the others.
p2_state p2-no-phases.json full false false false '{}' '"1"'
jq 'del(.phases)' "$WV_STATE_DIR/p2-no-phases.json" > "$WV_STATE_DIR/.p2tmp" \
  && mv "$WV_STATE_DIR/.p2tmp" "$WV_STATE_DIR/p2-no-phases.json"

p2_state p2-ac.json          full false false false '{}' '"1"' $(p2_through AC)
p2_state p2-acb.json         full false false false '{}' '"1"' $(p2_through ACB)
p2_state p2-ac-ui.json       full true  false false '{}' '"1"' $(p2_through AC)
p2_state p2-acb-ui.json      full true  false false '{}' '"1"' $(p2_through ACB)
p2_state p2-dr-ui.json       full true  false false '{}' '"1"' $(p2_through DR)
p2_state p2-acb-bc.json      full false true  false '{}' '"1"' $(p2_through ACB)
p2_state p2-dr-bc.json       full false true  false '{}' '"1"' $(p2_through DR)
p2_state p2-red.json         full false false false '{}' '"1"' $(p2_through TDE-RED)
p2_state p2-red-cr.json      full false false true  '{}' '"1"' $(p2_through TDE-RED)
p2_state p2-green.json       full false false false '{}' '"1"' $(p2_through TDE-GREEN)
p2_state p2-green-cr.json    full false false true  '{}' '"1"' $(p2_through TDE-GREEN)
p2_state p2-green-ui.json    full true  false false '{}' '"1"' $(p2_through TDE-GREEN)
p2_state p2-cr.json          full false false true  '{}' '"1"' $(p2_through CR)
p2_state p2-bc.json          full false false false '{}' '"1"' $(p2_through BC)
p2_state p2-bfbc.json        full false false false '{}' '"1"' $(p2_through BF-BC)
p2_state p2-sea.json         full false false false '{}' '"1"' $(p2_through SEA)
p2_state p2-bfsea.json       full false false false '{}' '"1"' $(p2_through BF-SEA)
p2_state p2-ds.json          full false false false '{}' '"1"' $(p2_through DS)
p2_state p2-bfds.json        full false false false '{}' '"1"' $(p2_through BF-DS)
p2_state p2-bsea.json        full false false false '{}' '"1"' $(p2_through BSEA)
p2_state p2-bfbsea.json      full false false false '{}' '"1"' $(p2_through BF-BSEA)
p2_state p2-oa.json          full false false false '{}' '"1"' $(p2_through OA)
p2_state p2-teettc.json      full false false false '{}' '"1"' $(p2_through TEET-TC)
p2_state p2-teettc-ui.json   full true  false false '{}' '"1"' $(p2_through TEET-TC)
p2_state p2-teet.json        full false false false '{}' '"1"' $(p2_through TEET)
p2_state p2-bteet.json       full false false false '{}' '"1"' $(p2_through BTEET)
p2_state p2-bteetx.json      full false false false '{}' '"1"' $(p2_through BTEET-X)

# scope: one flag "unknown" at a time, every other flag explicit, so each
# W-SCOPE case names exactly one question.
p2_state p2-acb-ui-unknown.json full '"unknown"' false false '{}' '"1"' $(p2_through ACB)
p2_state p2-acb-bc-unknown.json full false '"unknown"' false '{}' '"1"' $(p2_through ACB)
p2_state p2-acb-cr-unknown.json full false false '"unknown"' '{}' '"1"' $(p2_through ACB)

# Both flags of DR's condition unanswered at once, and cr_enabled unanswered with
# the wave already through TDE-GREEN: the two states that separate "unanswered"
# from "false" on a condition rather than on the TDE-RED scope gate.
p2_state p2-acb-ui-bc-unknown.json full '"unknown"' '"unknown"' false '{}' '"1"' $(p2_through ACB)
p2_state p2-green-cr-unknown.json  full false false '"unknown"' '{}' '"1"' $(p2_through TDE-GREEN)

# rounds: the counter subagent-stop.sh writes and pre-agent.sh only ever reads.
p2_state p2-red-rounds1.json full false false false '{"TDE-GREEN/executor":1}' '"1"' $(p2_through TDE-RED)
p2_state p2-red-rounds2.json full false false false '{"TDE-GREEN/executor":2}' '"1"' $(p2_through TDE-RED)
p2_state p2-red-rounds2-both.json full false false false '{"TDE-GREEN/executor":2,"TDE-GREEN/reviewer":2}' '"1"' $(p2_through TDE-RED)
p2_state p2-red-wave2.json   full false false false '{}' '"2"' $(p2_through TDE-RED)
p2_state p2-ad-rounds5.json  full false false false '{"AD/writer":5}' '"1"'

# demo-mode states. The demo subset is AC, DR, TDE-RED, TDE-GREEN, TEET, so a
# demo chain never names ACB, CR or any of the scans.
p2_state p2-demo-ui-fresh.json demo true  false false '{}' '"1"'
p2_state p2-demo-ui-ac.json    demo true  false false '{}' '"1"' AC
p2_state p2-demo-red.json      demo false false false '{}' '"1"' AC TDE-RED
p2_state p2-demo-green.json    demo false false false '{}' '"1"' AC TDE-RED TDE-GREEN

# --- seed helpers ----------------------------------------------------------

seedspec() {
  # seedspec <item>... -> the JSON object mk's `seed=` key wants.
  #   f:<CODE>:<N>  .wave/findings/<CODE>.md whose first line is "FINDINGS: <N>"
  #   fbad:<CODE>   the same file present but carrying no ^FINDINGS: [0-9]+$ line
  #   a:<name>      .wave/approvals/<name>.md
  local out='{}' it code n path
  for it in "$@"; do
    [ -z "$it" ] && continue
    case "$it" in
      f:*)
        code="${it#f:}"; n="${code##*:}"; code="${code%%:*}"
        out="$(printf '%s' "$out" | jq --arg p ".wave/findings/$code.md" \
          --arg c "FINDINGS: $n"$'\n' '. + {($p): $c}')" ;;
      fbad:*)
        code="${it#fbad:}"
        out="$(printf '%s' "$out" | jq --arg p ".wave/findings/$code.md" \
          --arg c "no count on this line"$'\n'"FINDINGS: several"$'\n' '. + {($p): $c}')" ;;
      a:*)
        path=".wave/approvals/${it#a:}.md"
        out="$(printf '%s' "$out" | jq --arg p "$path" \
          --arg c "Approved by the user on 2026-09-09."$'\n' '. + {($p): $c}')" ;;
      *) printf 'seedspec: unknown item %s\n' "$it" >&2; return 1 ;;
    esac
  done
  printf '%s' "$out"
}

exp_order() {
  # exp_order <unmet-list> [extra-literal-needle...] -> the expect object for a
  # W-ORDER deny. The first needle is the rendered list itself, so a case that
  # names the wrong predecessor set is red even though the rule id matches.
  local unmet="$1"; shift
  local out
  out="$(jq -nc --arg u "predecessor(s) not done: $unmet" \
    '{exit:0, decision:"deny", rule:"W-ORDER", reason_template:"W-ORDER", reason_contains:[$u]}')"
  local n
  for n in "$@"; do
    out="$(printf '%s' "$out" | jq -c --arg n "$n" '.reason_contains += [$n]')"
  done
  printf '%s' "$out"
}

exp_deny() {
  # exp_deny <rule> [literal-needle...]
  local rule="$1"; shift
  local out n
  out="$(jq -nc --arg r "$rule" '{exit:0, decision:"deny", rule:$r, reason_template:$r, reason_contains:[]}')"
  for n in "$@"; do
    out="$(printf '%s' "$out" | jq -c --arg n "$n" '.reason_contains += [$n]')"
  done
  printf '%s' "$out"
}

exp_warn() {
  # exp_warn <rule> [literal-needle...] — an allow that carries a warning.
  local rule="$1"; shift
  local out n
  out="$(jq -nc --arg r "$rule" '{exit:0, decision:"warn", rule:$r, reason_template:$r, reason_contains:[]}')"
  for n in "$@"; do
    out="$(printf '%s' "$out" | jq -c --arg n "$n" '.reason_contains += [$n]')"
  done
  printf '%s' "$out"
}

exp_allow() {
  # exp_allow [negative-control-rule] — a silent allow that additionally proves
  # none of part 2's twelve rules reached stdout.
  if [ -n "${1:-}" ]; then
    jq -nc --arg n "$1" --argjson nf "$P2NOFIRE" \
      '{exit:0, decision:"silent", negative_control_for:$n, stdout_absent:$nf}'
  else
    jq -nc --argjson nf "$P2NOFIRE" '{exit:0, decision:"silent", stdout_absent:$nf}'
  fi
}

# ---------------------------------------------------------------------------
# P2.A  Order — the `after` DAG (AC-17, AC-67..99)
# ---------------------------------------------------------------------------

mk name=order-017-no-phases-key-deny ac=AC-17 \
  note='state.json carries no `phases` key at all: it reads as {}, so TDE-RED is denied naming AC and ACB from the after column - never "everything done" and never a crash.' \
  state=state/p2-no-phases.json desc='[W:1 P:TDE-RED R:executor] write the failing tests' model=sonnet \
  expect="$(exp_order 'AC, ACB' 'TDE-RED require(s)')"

mk name=order-067a-ac-empty-phases-allow ac=AC-67 \
  note='AC has an empty after column: with phases {} there is no order gate at all.' \
  state=state/valid-full.json desc='[W:1 P:AC R:lead] write the ACs' model=opus \
  expect="$(exp_allow)"

mk name=order-067b-ac-all-done-allow ac=AC-67 \
  note='the same AC dispatch replayed against an all-done phases map: no state of phases can produce a W-ORDER for the first row.' \
  state=state/full-all-done.json desc='[W:1 P:AC R:lead] write the ACs' model=opus \
  expect="$(exp_allow)"

mk name=order-068a-acb-ac-not-done-deny ac=AC-68 \
  note='ACB after AC, AC not done: W-ORDER naming AC.' \
  state=state/valid-full.json desc='[W:1 P:ACB R:lead] make the ACs brutal' model=opus \
  expect="$(exp_order 'AC' 'ACB require(s) AC to complete first')"

mk name=order-068b-acb-ac-done-allow ac=AC-68 \
  note='the same dispatch with AC done: allow.' \
  state=state/p2-ac.json desc='[W:1 P:ACB R:lead] make the ACs brutal' model=opus \
  expect="$(exp_allow)"

mk name=order-069a-dr-acb-not-done-deny ac=AC-69 \
  note='ui true so DR runs; DR after AC,ACB with ACB not done: W-ORDER naming ACB.' \
  state=state/p2-ac-ui.json desc='[W:1 P:DR R:lead] review the design' model=opus \
  expect="$(exp_order 'ACB')"

mk name=order-069b-dr-both-done-allow ac=AC-69 \
  note='the same dispatch with AC and ACB both done: allow.' \
  state=state/p2-acb-ui.json desc='[W:1 P:DR R:lead] review the design' model=opus \
  expect="$(exp_allow)"

mk name=order-070-tde-red-empty-phases-deny ac=AC-70 \
  note='phases {} with all three scope flags explicit: TDE-RED is denied naming AC and ACB (DR is skipped because both its flags are false).' \
  state=state/valid-full.json desc='[W:1 P:TDE-RED R:executor] write the failing tests' model=sonnet \
  expect="$(exp_order 'AC, ACB')"

mk name=order-071-tde-red-flags-false-allow ac=AC-71 \
  note='the AC-70 dispatch with AC and ACB done and every flag false: allow. Negative control for W-ORDER, and the proof that a false DR condition removes DR from the predecessor set.' \
  state=state/p2-acb.json desc='[W:1 P:TDE-RED R:executor] write the failing tests' model=sonnet \
  expect="$(exp_allow W-ORDER)"

mk name=order-072-tde-red-ui-dr-not-done-deny ac=AC-72 \
  note='ui true, AC+ACB done, DR not done: W-ORDER naming DR and stating that state.ui is what makes DR required.' \
  state=state/p2-acb-ui.json desc='[W:1 P:TDE-RED R:executor] write the failing tests' model=sonnet \
  expect="$(exp_order 'DR' 'DR (required because state.ui is true)')"

mk name=order-073a-tde-green-red-not-done-deny ac=AC-73 \
  note='TDE-GREEN after TDE-RED, TDE-RED not done: W-ORDER naming TDE-RED.' \
  state=state/p2-acb.json desc='[W:1 P:TDE-GREEN R:executor] make the tests pass' model=sonnet \
  expect="$(exp_order 'TDE-RED')"

mk name=order-073b-tde-green-red-done-allow ac=AC-73 \
  note='the same dispatch with TDE-RED done: allow.' \
  state=state/p2-red.json desc='[W:1 P:TDE-GREEN R:executor] make the tests pass' model=sonnet \
  expect="$(exp_allow)"

mk name=order-074a-cr-green-not-done-deny ac=AC-74 \
  note='cr_enabled true so CR runs; CR after TDE-GREEN, TDE-GREEN not done: W-ORDER naming TDE-GREEN.' \
  state=state/p2-red-cr.json desc='[W:1 P:CR R:reviewer] review the change' model=sonnet \
  expect="$(exp_order 'TDE-GREEN')"

mk name=order-074b-cr-green-done-allow ac=AC-74 \
  note='the same dispatch with TDE-GREEN done: allow. Negative control for W-COND - the identical dispatch denies W-COND once cr_enabled is false (cond-075*).' \
  state=state/p2-green-cr.json desc='[W:1 P:CR R:reviewer] review the change' model=sonnet \
  expect="$(exp_allow W-COND)"

mk name=order-076-bc-cr-not-done-deny ac=AC-76 \
  note='cr_enabled true, TDE-GREEN done, CR not done: BC is denied naming CR.' \
  state=state/p2-green-cr.json desc='[W:1 P:BC R:executor] scan for bugs' model=sonnet \
  expect="$(exp_order 'CR' 'CR (required because state.cr_enabled is true)')"

mk name=order-077-bc-cr-disabled-allow ac=AC-77 \
  note='the same dispatch with cr_enabled false: allow - a conditional predecessor whose condition is false counts as done.' \
  state=state/p2-green.json desc='[W:1 P:BC R:executor] scan for bugs' model=sonnet \
  expect="$(exp_allow)"

mk name=order-078-bc-green-not-done-deny ac=AC-78 \
  note='cr_enabled false so CR is skipped, but TDE-GREEN is not done: BC is denied naming TDE-GREEN, reached through the skipped CR row.' \
  state=state/p2-red.json desc='[W:1 P:BC R:executor] scan for bugs' model=sonnet \
  expect="$(exp_order 'TDE-GREEN')"

mk name=order-079a-bf-bc-bc-not-done-deny ac=AC-79 \
  note='BF-BC after BC with the bug-fix approval already present: W-ORDER naming BC. Its own findings:BC condition cannot be read yet, and that is not a violation - the order rule names the scan that has not run.' \
  state=state/p2-green.json desc='[W:1 P:BF-BC R:executor] fix the findings' model=sonnet \
  seed="$(seedspec a:bf-BC)" \
  expect="$(exp_order 'BC')"

mk name=order-079b-bf-bc-findings-three-allow ac=AC-79 \
  note='BC done, .wave/findings/BC.md first line FINDINGS: 3, approval present: allow.' \
  state=state/p2-bc.json desc='[W:1 P:BF-BC R:executor] fix the findings' model=sonnet \
  seed="$(seedspec f:BC:3 a:bf-BC)" \
  expect="$(exp_allow)"

mk name=order-081-sea-bf-bc-skipped-allow ac=AC-81 \
  note='the cond-080 state (BC done, FINDINGS: 0, so BF-BC is skipped): SEA is allowed - a skipped conditional predecessor must not block its successor.' \
  state=state/p2-bc.json desc='[W:1 P:SEA R:executor] scan for silent errors' model=sonnet \
  seed="$(seedspec f:BC:0)" \
  expect="$(exp_allow)"

mk name=order-082a-sea-bf-bc-not-done-deny ac=AC-82 \
  note='the load-bearing converse of AC-81: BC done with FINDINGS: 3 and BF-BC not done, so the conditional predecessor whose condition is TRUE blocks SEA.' \
  state=state/p2-bc.json desc='[W:1 P:SEA R:executor] scan for silent errors' model=sonnet \
  seed="$(seedspec f:BC:3)" \
  expect="$(exp_order 'BF-BC' 'BF-BC (required because BC reported findings)')"

mk name=order-082b-sea-bf-bc-done-allow ac=AC-82 \
  note='the same state with BF-BC done: allow.' \
  state=state/p2-bfbc.json desc='[W:1 P:SEA R:executor] scan for silent errors' model=sonnet \
  seed="$(seedspec f:BC:3)" \
  expect="$(exp_allow)"

mk name=order-084a-bf-sea-sea-not-done-deny ac=AC-84 \
  note='BF-SEA after SEA with .wave/approvals/bf-SEA.md present and SEA not done: W-ORDER naming SEA.' \
  state=state/p2-bfbc.json desc='[W:1 P:BF-SEA R:executor] fix the silent-error findings' model=sonnet \
  seed="$(seedspec a:bf-SEA)" \
  expect="$(exp_order 'SEA')"

mk name=order-084b-bf-sea-findings-two-allow ac=AC-84 \
  note='SEA done with FINDINGS: 2 and the approval present: allow.' \
  state=state/p2-sea.json desc='[W:1 P:BF-SEA R:executor] fix the silent-error findings' model=sonnet \
  seed="$(seedspec f:SEA:2 a:bf-SEA)" \
  expect="$(exp_allow)"

mk name=order-085a-ds-sea-not-done-deny ac=AC-85 \
  note='DS after BF-SEA (the controller ruling), SEA not done: the blocker reported is SEA, the scan that has not run, not the BF row whose condition cannot be read yet.' \
  state=state/p2-bfbc.json desc='[W:1 P:DS R:executor] validate the dependencies' model=sonnet \
  expect="$(exp_order 'SEA')"

mk name=order-085b-ds-sea-findings-zero-allow ac=AC-85 \
  note='SEA done with FINDINGS: 0, so BF-SEA is skipped: DS is allowed.' \
  state=state/p2-sea.json desc='[W:1 P:DS R:executor] validate the dependencies' model=sonnet \
  seed="$(seedspec f:SEA:0)" \
  expect="$(exp_allow)"

mk name=order-086a-bf-ds-ds-not-done-deny ac=AC-86 \
  note='BF-DS after DS with the approval present and DS not done: W-ORDER naming DS.' \
  state=state/p2-bfsea.json desc='[W:1 P:BF-DS R:executor] fix the dependency findings' model=sonnet \
  seed="$(seedspec a:bf-DS)" \
  expect="$(exp_order 'DS')"

mk name=order-086b-bf-ds-findings-one-allow ac=AC-86 \
  note='DS done with FINDINGS: 1 and the approval present: allow.' \
  state=state/p2-ds.json desc='[W:1 P:BF-DS R:executor] fix the dependency findings' model=sonnet \
  seed="$(seedspec f:DS:1 a:bf-DS)" \
  expect="$(exp_allow)"

mk name=order-087a-bsea-ds-not-done-deny ac=AC-87 \
  note='BSEA after BF-DS, DS not done: the blocker reported is DS.' \
  state=state/p2-bfsea.json desc='[W:1 P:BSEA R:executor] make the silent-error scan brutal' model=opus \
  expect="$(exp_order 'DS')"

mk name=order-087b-bsea-ds-findings-zero-allow ac=AC-87 \
  note='DS done with FINDINGS: 0, so BF-DS is skipped: BSEA is allowed.' \
  state=state/p2-ds.json desc='[W:1 P:BSEA R:executor] make the silent-error scan brutal' model=opus \
  seed="$(seedspec f:DS:0)" \
  expect="$(exp_allow)"

mk name=order-088a-bf-bsea-bsea-not-done-deny ac=AC-88 \
  note='BF-BSEA after BSEA with the approval present and BSEA not done: W-ORDER naming BSEA.' \
  state=state/p2-bfds.json desc='[W:1 P:BF-BSEA R:executor] fix the brutal findings' model=sonnet \
  seed="$(seedspec a:bf-BSEA)" \
  expect="$(exp_order 'BSEA')"

mk name=order-088b-bf-bsea-findings-one-allow ac=AC-88 \
  note='BSEA done with FINDINGS: 1 and the approval present: allow.' \
  state=state/p2-bsea.json desc='[W:1 P:BF-BSEA R:executor] fix the brutal findings' model=sonnet \
  seed="$(seedspec f:BSEA:1 a:bf-BSEA)" \
  expect="$(exp_allow)"

mk name=order-089a-oa-bsea-not-done-deny ac=AC-89 \
  note='OA after BF-BSEA, BSEA not done: the blocker reported is BSEA.' \
  state=state/p2-bfds.json desc='[W:1 P:OA R:lead] check the output alignment' model=opus \
  expect="$(exp_order 'BSEA')"

mk name=order-089b-oa-every-predecessor-settled-allow ac=AC-89 \
  note='every predecessor through BF-BSEA done or skipped (BSEA done, FINDINGS: 0): OA is allowed.' \
  state=state/p2-bsea.json desc='[W:1 P:OA R:lead] check the output alignment' model=opus \
  seed="$(seedspec f:BSEA:0)" \
  expect="$(exp_allow)"

mk name=order-090a-teet-tc-oa-not-done-deny ac=AC-90 \
  note='TEET-TC after OA, OA not done: W-ORDER naming OA.' \
  state=state/p2-bfbsea.json desc='[W:1 P:TEET-TC R:executor] write the e2e cases' model=sonnet \
  expect="$(exp_order 'OA')"

mk name=order-090b-teet-tc-oa-done-allow ac=AC-90 \
  note='the same dispatch with OA done: allow.' \
  state=state/p2-oa.json desc='[W:1 P:TEET-TC R:executor] write the e2e cases' model=sonnet \
  expect="$(exp_allow)"

mk name=order-091a-teet-tc-not-done-deny ac=AC-91 \
  note='full mode, ui false, OA done, TEET-TC not done: TEET is denied naming TEET-TC.' \
  state=state/p2-oa.json desc='[W:1 P:TEET R:executor] run the end-to-end suite' model=sonnet \
  expect="$(exp_order 'TEET-TC')"

mk name=order-091b-teet-tc-done-allow ac=AC-91 \
  note='the same dispatch with TEET-TC done: allow.' \
  state=state/p2-teettc.json desc='[W:1 P:TEET R:executor] run the end-to-end suite' model=sonnet \
  expect="$(exp_allow)"

mk name=order-092a-bf-teet-findings-two-allow ac=AC-92 \
  note='TEET done, .wave/findings/TEET.md first line FINDINGS: 2, .wave/approvals/bf-TEET.md present: BF-TEET is allowed - it is reachable because the TEET row carries a findings column.' \
  state=state/p2-teet.json desc='[W:1 P:BF-TEET R:executor] fix the e2e findings' model=sonnet \
  seed="$(seedspec f:TEET:2 a:bf-TEET)" \
  expect="$(exp_allow)"

mk name=order-092b-bf-teet-teet-not-done-deny ac=AC-92 \
  note='the same dispatch with TEET not done: W-ORDER naming TEET.' \
  state=state/p2-teettc.json desc='[W:1 P:BF-TEET R:executor] fix the e2e findings' model=sonnet \
  seed="$(seedspec a:bf-TEET)" \
  expect="$(exp_order 'TEET')"

mk name=order-093a-bteet-teet-not-done-deny ac=AC-93 \
  note='BTEET after BF-TEET, TEET not done: the blocker reported is TEET.' \
  state=state/p2-teettc.json desc='[W:1 P:BTEET R:executor] make the e2e brutal' model=opus \
  expect="$(exp_order 'TEET')"

mk name=order-093b-bteet-teet-findings-zero-allow ac=AC-93 \
  note='TEET done with FINDINGS: 0, so BF-TEET is skipped: BTEET is allowed.' \
  state=state/p2-teet.json desc='[W:1 P:BTEET R:executor] make the e2e brutal' model=opus \
  seed="$(seedspec f:TEET:0)" \
  expect="$(exp_allow)"

mk name=order-094a-bteet-x-bteet-not-done-deny ac=AC-94 \
  note='BTEET-X after BTEET, BTEET not done: W-ORDER naming BTEET.' \
  state=state/p2-teet.json desc='[W:1 P:BTEET-X R:executor] execute the brutal e2e' model=sonnet \
  seed="$(seedspec f:TEET:0)" \
  expect="$(exp_order 'BTEET')"

mk name=order-094b-bteet-x-bteet-done-allow ac=AC-94 \
  note='the same dispatch with BTEET done: allow.' \
  state=state/p2-bteet.json desc='[W:1 P:BTEET-X R:executor] execute the brutal e2e' model=sonnet \
  expect="$(exp_allow)"

mk name=order-095a-bf-bteet-x-not-done-deny ac=AC-95 \
  note='BF-BTEET after BTEET-X with the approval present and .wave/findings/BTEET.md = FINDINGS: 1: W-ORDER naming BTEET-X.' \
  state=state/p2-bteet.json desc='[W:1 P:BF-BTEET R:executor] fix the brutal e2e findings' model=sonnet \
  seed="$(seedspec f:BTEET:1 a:bf-BTEET)" \
  expect="$(exp_order 'BTEET-X')"

mk name=order-095b-bf-bteet-x-done-allow ac=AC-95 \
  note='the same dispatch with BTEET-X done: allow.' \
  state=state/p2-bteetx.json desc='[W:1 P:BF-BTEET R:executor] fix the brutal e2e findings' model=sonnet \
  seed="$(seedspec f:BTEET:1 a:bf-BTEET)" \
  expect="$(exp_allow)"

mk name=order-096a-vb-bteet-x-not-done-deny ac=AC-96 \
  note='VB after BTEET-X,BF-BTEET with BTEET-X not done and BF-BTEET skipped (FINDINGS: 0): W-ORDER naming BTEET-X.' \
  state=state/p2-bteet.json desc='[W:1 P:VB R:executor] bump the version' model=haiku \
  seed="$(seedspec f:BTEET:0)" \
  expect="$(exp_order 'BTEET-X')"

mk name=order-096b-vb-bteet-x-done-allow ac=AC-96 \
  note='BTEET-X done and .wave/findings/BTEET.md = FINDINGS: 0, so BF-BTEET is skipped: VB is allowed.' \
  state=state/p2-bteetx.json desc='[W:1 P:VB R:executor] bump the version' model=haiku \
  seed="$(seedspec f:BTEET:0)" \
  expect="$(exp_allow)"

mk name=order-097a-commit-bteet-x-not-done-deny ac=AC-97 \
  note='COMMIT shares VB predecessor set; BTEET-X not done: W-ORDER naming BTEET-X.' \
  state=state/p2-bteet.json desc='[W:1 P:COMMIT R:executor] commit the change' model=sonnet \
  seed="$(seedspec f:BTEET:0)" \
  expect="$(exp_order 'BTEET-X')"

mk name=order-097b-commit-vb-not-done-allow ac=AC-97 \
  note='BTEET-X done and VB NOT done: COMMIT is still allowed - the framework parallel finalization is not serialised.' \
  state=state/p2-bteetx.json desc='[W:1 P:COMMIT R:executor] commit the change' model=sonnet \
  seed="$(seedspec f:BTEET:0)" \
  expect="$(exp_allow)"

mk name=order-098a-cl-bteet-x-not-done-deny ac=AC-98 \
  note='CL with BTEET-X not done: the reason carries only W-ORDER and names BTEET-X.' \
  state=state/p2-bteet.json desc='[W:1 P:CL R:executor] clean up between waves' model=sonnet \
  seed="$(seedspec f:BTEET:0)" \
  expect="$(exp_order 'BTEET-X')"

mk name=order-098b-cl-commit-not-done-allow ac=AC-98 \
  note='BTEET-X done and COMMIT not done: CL is allowed.' \
  state=state/p2-bteetx.json desc='[W:1 P:CL R:executor] clean up between waves' model=sonnet \
  seed="$(seedspec f:BTEET:0)" \
  expect="$(exp_allow)"

mk name=order-099a-ccp-bteet-x-not-done-deny ac=AC-99 \
  note='CCP with BTEET-X not done: W-ORDER naming BTEET-X.' \
  state=state/p2-bteet.json desc='[W:1 P:CCP R:executor] save the checkpoint' model=sonnet \
  seed="$(seedspec f:BTEET:0)" \
  expect="$(exp_order 'BTEET-X')"

mk name=order-099b-ccp-cl-not-done-allow ac=AC-99 \
  note='BTEET-X done and CL not done: CCP is allowed.' \
  state=state/p2-bteetx.json desc='[W:1 P:CCP R:executor] save the checkpoint' model=sonnet \
  seed="$(seedspec f:BTEET:0)" \
  expect="$(exp_allow)"

mk name=order-100a-ad-anytime-mid-wave-allow ac=AC-100 \
  note='AD is when=anytime: with AC+ACB+TDE-RED done and TDE-GREEN in flight it is allowed with no W-ORDER.' \
  state=state/p2-red.json desc='[W:1 P:AD R:writer] update the dashboard' model=haiku \
  expect="$(exp_allow)"

mk name=order-100b-ad-anytime-empty-phases-allow ac=AC-100 \
  note='the same anytime row against phases {}: still allowed - the continuous dashboard must be dispatchable throughout the wave.' \
  state=state/valid-full.json desc='[W:1 P:AD R:writer] update the dashboard' model=haiku \
  expect="$(exp_allow)"

# ---------------------------------------------------------------------------
# P2.B  Demo-mode order (AC-101..106)
# ---------------------------------------------------------------------------

mk name=order-101-demo-ac-fresh-allow ac=AC-101 \
  note='demo mode, phases {}, ui false: AC is allowed.' \
  state=state/demo-fresh.json desc='[W:1 P:AC R:lead] write the ACs' model=opus \
  expect="$(exp_allow)"

mk name=order-102a-demo-dr-ac-not-done-deny ac=AC-102 \
  note='demo mode with ui true, AC not done: DR is denied naming AC only - ACB is full-only, so the demo predecessor set excludes it.' \
  state=state/p2-demo-ui-fresh.json desc='[W:1 P:DR R:lead] review the design' model=opus \
  expect="$(jq -c --argjson e "$(exp_order 'AC')" -n '$e + {stdout_absent:["ACB"]}')"

mk name=order-102b-demo-dr-ac-done-allow ac=AC-102 \
  note='the same demo dispatch with AC done: allow.' \
  state=state/p2-demo-ui-ac.json desc='[W:1 P:DR R:lead] review the design' model=opus \
  expect="$(exp_allow)"

mk name=order-103a-demo-tde-red-ac-not-done-deny ac=AC-103 \
  note='demo mode, ui false, AC not done: TDE-RED is denied naming AC only (ACB is full-only, DR is skipped).' \
  state=state/demo-fresh.json desc='[W:1 P:TDE-RED R:executor] write the failing tests' model=sonnet \
  expect="$(jq -c --argjson e "$(exp_order 'AC')" -n '$e + {stdout_absent:["ACB"]}')"

mk name=order-103b-demo-tde-red-ac-done-allow ac=AC-103 \
  note='the same demo dispatch with AC done: allow.' \
  state=state/demo-ac-done.json desc='[W:1 P:TDE-RED R:executor] write the failing tests' model=sonnet \
  expect="$(exp_allow)"

mk name=order-104a-demo-tde-green-red-not-done-deny ac=AC-104 \
  note='demo mode, AC done, TDE-RED not done: TDE-GREEN is denied naming TDE-RED.' \
  state=state/demo-ac-done.json desc='[W:1 P:TDE-GREEN R:executor] make the tests pass' model=sonnet \
  expect="$(exp_order 'TDE-RED')"

mk name=order-104b-demo-tde-green-red-done-allow ac=AC-104 \
  note='the same demo dispatch with TDE-RED done: allow.' \
  state=state/p2-demo-red.json desc='[W:1 P:TDE-GREEN R:executor] make the tests pass' model=sonnet \
  expect="$(exp_allow)"

mk name=order-105-demo-teet-green-not-done-deny ac=AC-105 \
  note='demo mode, TDE-GREEN not done: TEET is denied naming TDE-GREEN and naming no full-only code (TEET-TC, BF-TEET).' \
  state=state/p2-demo-red.json desc='[W:1 P:TEET R:executor] run the end-to-end suite' model=sonnet \
  expect="$(jq -c --argjson e "$(exp_order 'TDE-GREEN')" -n '$e + {stdout_absent:["TEET-TC","BF-TEET"]}')"

mk name=order-106a-demo-teet-tc-skipped-allow ac=AC-106 \
  note='the shipped TEET row whose after is TDE-GREEN,TEET-TC: in demo, TEET-TC is skipped because its modes exclude demo, so TEET is allowed once TDE-GREEN is done.' \
  state=state/p2-demo-green.json desc='[W:1 P:TEET R:executor] run the end-to-end suite' model=sonnet \
  expect="$(exp_allow)"

mk name=order-106b-full-teet-tc-not-done-deny ac=AC-106 \
  note='the identical row in full mode with TEET-TC not done: denied. The skip is mode-conditional, not a blanket ignore.' \
  state=state/p2-oa.json desc='[W:1 P:TEET R:executor] run the end-to-end suite' model=sonnet \
  expect="$(exp_order 'TEET-TC')"

# ---------------------------------------------------------------------------
# P2.C  Conditions (AC-75, AC-80, AC-92 third clause)
# ---------------------------------------------------------------------------

mk name=cond-075a-cr-disabled-empty-deny ac=AC-75 \
  note='cr_enabled false and TDE-GREEN done: a CR dispatch is denied W-COND. Data state EMPTY - .wave/ holds only state.json, so no artifact could have decided this.' \
  state=state/p2-green.json desc='[W:1 P:CR R:reviewer] review the change' model=sonnet \
  expect="$(exp_deny W-COND 'condition `cr` is false' 'CR' 'cr_enabled')"

mk name=cond-075b-cr-disabled-partial-deny ac=AC-75 \
  note='the same deny with data state PARTIAL - earlier artifacts present, later ones absent. The condition, not an artifact, decides.' \
  state=state/p2-green.json desc='[W:1 P:CR R:reviewer] review the change' model=sonnet \
  seed='{".wave/ac.md":"AC-1 the first criterion\n",".wave/red.md":"RED-VERIFIED failing=12\n"}' \
  expect="$(exp_deny W-COND 'condition `cr` is false')"

mk name=cond-075c-cr-disabled-full-deny ac=AC-75 \
  note='the same deny with data state FULL - every artifact for the done phases present, including a CR artifact. Still denied: the flag is the authority.' \
  state=state/p2-green.json desc='[W:1 P:CR R:reviewer] review the change' model=sonnet \
  seed='{".wave/ac.md":"AC-1 the first criterion\n",".wave/acb.md":"ACB-VERIFIED\n",".wave/red.md":"RED-VERIFIED failing=12\n",".wave/green.md":"GREEN-VERIFIED passing=12 failing=0\n",".wave/cr.md":"CR-VERIFIED\n"}' \
  expect="$(exp_deny W-COND 'condition `cr` is false')"

mk name=cond-080-bf-bc-findings-zero-deny ac=AC-80 \
  note='BC done and .wave/findings/BC.md first line FINDINGS: 0: BF-BC is denied W-COND naming findings:BC and the zero count.' \
  state=state/p2-bc.json desc='[W:1 P:BF-BC R:executor] fix the findings' model=sonnet \
  seed="$(seedspec f:BC:0 a:bf-BC)" \
  expect="$(exp_deny W-COND 'condition `findings:BC` is false' 'FINDINGS: 0')"

mk name=cond-092c-bf-teet-findings-zero-deny ac=AC-92 \
  note='TEET done with FINDINGS: 0: BF-TEET is denied W-COND. The BF row of a scan that found nothing is skipped, not blocked.' \
  state=state/p2-teet.json desc='[W:1 P:BF-TEET R:executor] fix the e2e findings' model=sonnet \
  seed="$(seedspec f:TEET:0 a:bf-TEET)" \
  expect="$(exp_deny W-COND 'condition `findings:TEET` is false' 'FINDINGS: 0')"

# ---------------------------------------------------------------------------
# P2.D  Scope gate (AC-107..112)
# ---------------------------------------------------------------------------

mk name=scope-107-ui-unknown-deny ac=AC-107 \
  note='ui "unknown" with AC+ACB done: TDE-RED is denied W-SCOPE naming ui and the one command that answers it.' \
  state=state/p2-acb-ui-unknown.json desc='[W:1 P:TDE-RED R:executor] write the failing tests' model=sonnet \
  expect="$(exp_deny W-SCOPE 'without ui set' 'scripts/wave-set.sh ui true|false')"

mk name=scope-108-behaviour-change-unknown-deny ac=AC-108 \
  note='ui false, behaviour_change "unknown": denied W-SCOPE naming behaviour_change and `scripts/wave-set.sh behaviour-change true|false` (the CLI key is hyphenated, the state key is not).' \
  state=state/p2-acb-bc-unknown.json desc='[W:1 P:TDE-RED R:executor] write the failing tests' model=sonnet \
  expect="$(exp_deny W-SCOPE 'without behaviour_change set' 'scripts/wave-set.sh behaviour-change true|false')"

mk name=scope-109-cr-enabled-unknown-deny ac=AC-109 \
  note='ui and behaviour_change false, cr_enabled "unknown": denied W-SCOPE naming cr_enabled.' \
  state=state/p2-acb-cr-unknown.json desc='[W:1 P:TDE-RED R:executor] write the failing tests' model=sonnet \
  expect="$(exp_deny W-SCOPE 'without cr_enabled set' 'scripts/wave-set.sh cr true|false')"

mk name=scope-110-all-flags-false-allow ac=AC-110 \
  note='all three flags explicitly false with AC+ACB done: TDE-RED is allowed. Negative control for AC-107..109 - a silent skip is impossible, an explicit false is fine.' \
  state=state/p2-acb.json desc='[W:1 P:TDE-RED R:executor] write the failing tests' model=sonnet \
  expect="$(exp_allow W-SCOPE)"

mk name=scope-111-unknown-on-ac-allow ac=AC-111 \
  note='every flag "unknown" and phases {}: an AC dispatch is allowed - the scope gate is on TDE-RED, not on every phase, so a wave can start before the questions are answered.' \
  state=state/unknown-scope.json desc='[W:1 P:AC R:lead] write the ACs' model=opus \
  expect="$(exp_allow)"

mk name=scope-112a-behaviour-change-true-dr-deny ac=AC-112 \
  note='ui false, behaviour_change true, AC+ACB done, DR not done: TDE-RED is denied W-ORDER naming DR as required because state.behaviour_change is true - DR condition is ui|behaviour_change.' \
  state=state/p2-acb-bc.json desc='[W:1 P:TDE-RED R:executor] write the failing tests' model=sonnet \
  expect="$(exp_order 'DR' 'DR (required because state.behaviour_change is true)')"

mk name=scope-112b-behaviour-change-true-dr-done-allow ac=AC-112 \
  note='the same with DR done and .wave/dr.md carrying no OPEN: line: allowed.' \
  state=state/p2-dr-bc.json desc='[W:1 P:TDE-RED R:executor] write the failing tests' model=sonnet \
  seed='{".wave/dr.md":"DR-VERIFIED\nEvery item was settled in conversation.\n"}' \
  expect="$(exp_allow)"

# --- fix round 1: "unknown" is UNANSWERED, never false ----------------------
#
# `wave-init.sh` writes `ui`, `behaviour_change` and `cr_enabled` as the string
# "unknown", and every later wave inherits it. A condition arm that read that as
# `false` denied `W-COND` and told the orchestrator "this wave declares no design
# review" — a statement nobody had made. The controller's ruling: an unanswered
# flag denies `W-SCOPE`, naming the flag and the one command that answers it.
#
# The W-SCOPE negative control stays `scope-110`; these cases carry
# `stdout_absent` on `W-COND` instead, because the defect was not "no deny" but
# "the wrong deny with a false statement in it". "TDE-RED with ui unknown still
# W-SCOPE" is `scope-107` and needs no new case — it is in this group's mutant
# filter so it is exercised as a control.

mk name=scope-113a-dr-ui-unknown-scope-deny ac='AC-107 (fix round 1: the controller ruling on "unknown")' \
  note='ui "unknown" with AC+ACB done: a DR dispatch is denied W-SCOPE naming ui and the command that answers it - NOT W-COND, which would state that the wave declares no design review when nobody has said so.' \
  state=state/p2-acb-ui-unknown.json desc='[W:1 P:DR R:lead] review the design' model=opus \
  expect="$(jq -c --argjson e "$(exp_deny W-SCOPE 'without ui set' 'scripts/wave-set.sh ui true|false')" -n '$e + {stdout_absent:["W-COND","declares no design review"]}')"

mk name=scope-113b-dr-both-unknown-scope-deny ac='AC-107 (fix round 1)' \
  note='both flags of DR condition unanswered: the reason names ui AND behaviour_change, and its remedy names the first one to answer.' \
  state=state/p2-acb-ui-bc-unknown.json desc='[W:1 P:DR R:lead] review the design' model=opus \
  expect="$(jq -c --argjson e "$(exp_deny W-SCOPE 'without ui and behaviour_change set' 'scripts/wave-set.sh ui true|false')" -n '$e + {stdout_absent:["W-COND"]}')"

mk name=scope-113c-dr-bc-unknown-scope-deny ac='AC-108 (fix round 1)' \
  note='ui false and behaviour_change "unknown": the reason names behaviour_change and the hyphenated CLI key, not the underscored state key.' \
  state=state/p2-acb-bc-unknown.json desc='[W:1 P:DR R:lead] review the design' model=opus \
  expect="$(jq -c --argjson e "$(exp_deny W-SCOPE 'without behaviour_change set' 'scripts/wave-set.sh behaviour-change true|false')" -n '$e + {stdout_absent:["W-COND"]}')"

mk name=scope-114-cr-unknown-scope-deny ac='AC-109 (fix round 1)' \
  note='cr_enabled "unknown" with TDE-GREEN done: a CR dispatch is denied W-SCOPE naming cr_enabled, not W-COND claiming the flag is false.' \
  state=state/p2-green-cr-unknown.json desc='[W:1 P:CR R:reviewer] review the change' model=sonnet \
  expect="$(jq -c --argjson e "$(exp_deny W-SCOPE 'without cr_enabled set' 'scripts/wave-set.sh cr true|false')" -n '$e + {stdout_absent:["W-COND"]}')"

mk name=scope-115-bc-cr-unknown-not-skipped-deny ac='AC-77, AC-109 (fix round 1: the transitive half)' \
  note='the load-bearing half of the ruling: BC after CR with cr_enabled "unknown". An unanswered condition must not be SKIPPED THROUGH the way a false one is - before the fix this allowed, because unknown read as false, CR counted as skipped, and the walk carried on to the satisfied TDE-GREEN. It now denies W-SCOPE, and names neither W-COND nor W-ORDER.' \
  state=state/p2-green-cr-unknown.json desc='[W:1 P:BC R:executor] scan for bugs' model=sonnet \
  expect="$(jq -c --argjson e "$(exp_deny W-SCOPE 'without cr_enabled set' 'scripts/wave-set.sh cr true|false')" -n '$e + {stdout_absent:["W-COND","W-ORDER"]}')"

mk name=scope-116a-dr-ui-true-allow ac='AC-69 (fix round 1: the answered-true control)' \
  note='the scope-113a state with ui answered TRUE instead of unknown: the DR dispatch is allowed. It isolates the flag VALUE as the discriminator, with everything else identical.' \
  state=state/p2-acb-ui.json desc='[W:1 P:DR R:lead] review the design' model=opus \
  expect="$(exp_allow)"

mk name=scope-116b-dr-both-false-cond-deny ac='AC-75 (fix round 1: the answered-false control)' \
  note='the same dispatch with both flags answered FALSE: still W-COND, and the reason may still say the wave declares no design review, because now that IS what the state says. The pair 113a/116b is the whole finding: same rule, same phase, different deny, and the difference is answered-versus-unanswered.' \
  state=state/p2-acb.json desc='[W:1 P:DR R:lead] review the design' model=opus \
  expect="$(jq -c --argjson e "$(exp_deny W-COND 'condition `ui|behaviour_change` is false' 'DR' 'state.ui and state.behaviour_change are both false')" -n '$e + {stdout_absent:["W-SCOPE"]}')"

# ---------------------------------------------------------------------------
# P2.E  Dispatch-time gates (AC-83, AC-147..160)
# ---------------------------------------------------------------------------

DRMD_TWO_OPEN='DR-VERIFIED
OPEN: which token carries the danger red in dark mode?
OPEN: does the drawer overlay the E-STOP at 1280px?
'

mk name=gate-083a-sea-findings-absent-artifact-deny ac=AC-83 \
  note='BC done and .wave/findings/BC.md absent: the SEA dispatch is denied W-ARTIFACT naming the file, carrying only that id. The condition cannot be evaluated, so the wave stops rather than guessing.' \
  state=state/p2-bc.json desc='[W:1 P:SEA R:executor] scan for silent errors' model=sonnet \
  expect="$(exp_deny W-ARTIFACT '.wave/findings/BC.md is missing' 'BC must produce .wave/findings/BC.md')"

mk name=gate-083b-sea-findings-no-marker-deny ac=AC-83 \
  note='the same with the findings file present but carrying no ^FINDINGS: [0-9]+$ line: denied W-MARKER.' \
  state=state/p2-bc.json desc='[W:1 P:SEA R:executor] scan for silent errors' model=sonnet \
  seed="$(seedspec fbad:BC)" \
  expect="$(exp_deny W-MARKER 'marker `^FINDINGS: [0-9]+$` not found' '.wave/findings/BC.md')"

mk name=gate-083c-sea-findings-valid-allow ac=AC-83 \
  note='a valid findings file (FINDINGS: 0, so BF-BC is skipped): the SEA dispatch is allowed. Negative control for W-ARTIFACT.' \
  state=state/p2-bc.json desc='[W:1 P:SEA R:executor] scan for silent errors' model=sonnet \
  seed="$(seedspec f:BC:0)" \
  expect="$(exp_allow W-ARTIFACT)"

mk name=gate-083d-sea-findings-valid-bf-done-allow ac=AC-83 \
  note='the other reading of the same clause: a valid findings file reporting 3 with BF-BC done. Allowed, and it proves the artifact gate is about readability, not about the count.' \
  state=state/p2-bfbc.json desc='[W:1 P:SEA R:executor] scan for silent errors' model=sonnet \
  seed="$(seedspec f:BC:3)" \
  expect="$(exp_allow)"

mk name=gate-147-dr-two-open-no-approval-deny ac=AC-147 \
  note='ui true, AC+ACB+DR done, .wave/dr.md carrying two OPEN: lines and no .wave/approvals/dr-open.md: TDE-RED is denied W-DR-OPEN naming the count 2, both files, and the unanswered lines verbatim. The count is derived by re-reading dr.md, never from state.' \
  state=state/p2-dr-ui.json desc='[W:1 P:TDE-RED R:executor] write the failing tests' model=sonnet \
  seed="$(jq -nc --arg c "$DRMD_TWO_OPEN" '{".wave/dr.md": $c}')" \
  expect="$(exp_deny W-DR-OPEN '2 OPEN line(s) in .wave/dr.md against 0 RESOLVED line(s) in .wave/approvals/dr-open.md' 'OPEN: which token carries the danger red in dark mode?' 'OPEN: does the drawer overlay the E-STOP at 1280px?')"

mk name=gate-148-dr-one-resolved-deny ac=AC-148 \
  note='the same with dr-open.md holding one RESOLVED: line: still denied, naming 2 OPEN against 1 RESOLVED.' \
  state=state/p2-dr-ui.json desc='[W:1 P:TDE-RED R:executor] write the failing tests' model=sonnet \
  seed="$(jq -nc --arg c "$DRMD_TWO_OPEN" '{".wave/dr.md": $c, ".wave/approvals/dr-open.md": "RESOLVED: use --red-700 for danger in both themes.\n"}')" \
  expect="$(exp_deny W-DR-OPEN '2 OPEN line(s) in .wave/dr.md against 1 RESOLVED line(s)')"

mk name=gate-149-dr-two-resolved-allow ac=AC-149 \
  note='dr-open.md holding two RESOLVED: lines: allowed. The gate is the approval artifact, not the absence of text - the user answers DR items in conversation and nothing rewrites dr.md. Negative control for W-DR-OPEN.' \
  state=state/p2-dr-ui.json desc='[W:1 P:TDE-RED R:executor] write the failing tests' model=sonnet \
  seed="$(jq -nc --arg c "$DRMD_TWO_OPEN" '{".wave/dr.md": $c, ".wave/approvals/dr-open.md": "RESOLVED: use --red-700 for danger in both themes.\nRESOLVED: the E-STOP gets its own stacking context.\n"}')" \
  expect="$(exp_allow W-DR-OPEN)"

mk name=gate-150-dr-open-inside-fence-allow ac=AC-150 \
  note='dr.md whose only OPEN: lines are inside a fenced code block, and no dr-open.md: allowed - fenced blocks are stripped before counting.' \
  state=state/p2-dr-ui.json desc='[W:1 P:TDE-RED R:executor] write the failing tests' model=sonnet \
  seed='{".wave/dr.md":"DR-VERIFIED\nThe format of an open item is:\n```text\nOPEN: an example of the format\nOPEN: and a second example\n```\nNothing is actually open.\n"}' \
  expect="$(exp_allow)"

mk name=gate-151a-dr-reopen-and-indented-allow ac=AC-151 \
  note='dr.md containing `REOPEN: old item` and an indented `  OPEN: note` but no line beginning OPEN:: allowed - the scan is anchored at ^OPEN:.' \
  state=state/p2-dr-ui.json desc='[W:1 P:TDE-RED R:executor] write the failing tests' model=sonnet \
  seed='{".wave/dr.md":"DR-VERIFIED\nREOPEN: old item from wave 0\n  OPEN: indented note, not an open item\n"}' \
  expect="$(exp_allow)"

mk name=gate-151b-dr-one-anchored-open-deny ac=AC-151 \
  note='the gate-151a file plus one line that does begin OPEN:: denied with count 1. The pair is the anchor assertion.' \
  state=state/p2-dr-ui.json desc='[W:1 P:TDE-RED R:executor] write the failing tests' model=sonnet \
  seed='{".wave/dr.md":"DR-VERIFIED\nREOPEN: old item from wave 0\n  OPEN: indented note, not an open item\nOPEN: which breakpoint owns the drawer?\n"}' \
  expect="$(exp_deny W-DR-OPEN '1 OPEN line(s) in .wave/dr.md against 0 RESOLVED line(s)' 'OPEN: which breakpoint owns the drawer?')"

mk name=gate-152-dr-done-artifact-absent-deny ac=AC-152 \
  note='ui true and DR marked done but .wave/dr.md absent: TDE-RED is denied W-ARTIFACT naming .wave/dr.md - the gate cannot read what the phase claims to have produced.' \
  state=state/p2-dr-ui.json desc='[W:1 P:TDE-RED R:executor] write the failing tests' model=sonnet \
  expect="$(exp_deny W-ARTIFACT '.wave/dr.md is missing' 'DR must produce .wave/dr.md')"

mk name=gate-153-visual-bc-no-approval-deny ac=AC-153 \
  note='ui true, TDE-GREEN done, .wave/approvals/green-visual.md absent: a BC dispatch is denied W-VISUAL. Every phase ordered after TDE-GREEN is gated, not only TEET.' \
  state=state/p2-green-ui.json desc='[W:1 P:BC R:executor] scan for bugs' model=sonnet \
  expect="$(exp_deny W-VISUAL 'visual approval required before BC' '.wave/approvals/green-visual.md' '.wave/screenshots/green-')"

mk name=gate-154a-visual-teet-empty-deny ac=AC-154 \
  note='the same gate on TEET with TEET-TC done. Data state EMPTY - .wave/ holds only state.json.' \
  state=state/p2-teettc-ui.json desc='[W:1 P:TEET R:executor] run the end-to-end suite' model=sonnet \
  expect="$(exp_deny W-VISUAL 'visual approval required before TEET')"

mk name=gate-154b-visual-teet-partial-deny ac=AC-154 \
  note='data state PARTIAL - .wave/approvals/ exists and holds another approval, but green-visual.md is absent: still denied.' \
  state=state/p2-teettc-ui.json desc='[W:1 P:TEET R:executor] run the end-to-end suite' model=sonnet \
  seed="$(seedspec a:bf-BC)" \
  expect="$(exp_deny W-VISUAL 'visual approval required before TEET')"

mk name=gate-154c-visual-teet-approved-allow ac=AC-154 \
  note='data state FULL - green-visual.md present: allowed.' \
  state=state/p2-teettc-ui.json desc='[W:1 P:TEET R:executor] run the end-to-end suite' model=sonnet \
  seed="$(seedspec a:green-visual)" \
  expect="$(exp_allow)"

mk name=gate-155-visual-ui-false-allow ac=AC-155 \
  note='ui false and the approval absent: the AC-154 dispatch is allowed - the visual gate is ui-conditional.' \
  state=state/p2-teettc.json desc='[W:1 P:TEET R:executor] run the end-to-end suite' model=sonnet \
  expect="$(exp_allow)"

mk name=gate-156-visual-bc-approved-allow ac=AC-156 \
  note='ui true and green-visual.md present: the gate-153 dispatch is allowed. Negative control for W-VISUAL - it isolates the approval file as the discriminator, with ui still true.' \
  state=state/p2-green-ui.json desc='[W:1 P:BC R:executor] scan for bugs' model=sonnet \
  seed="$(seedspec a:green-visual)" \
  expect="$(exp_allow W-VISUAL)"

mk name=gate-157a-bf-approval-absent-deny ac=AC-157 \
  note='BC done with findings 3 and .wave/approvals/bf-BC.md absent: BF-BC is denied W-BF-APPROVAL naming the path it wants.' \
  state=state/p2-bc.json desc='[W:1 P:BF-BC R:executor] fix the findings' model=sonnet \
  seed="$(seedspec f:BC:3)" \
  expect="$(exp_deny W-BF-APPROVAL '.wave/approvals/bf-BC.md' 'before re-running BF-BC')"

mk name=gate-157b-bf-approval-present-allow ac=AC-157 \
  note='the same with the approval present: allowed. Negative control for W-BF-APPROVAL, and for W-COND (the condition is true here and false in cond-080).' \
  state=state/p2-bc.json desc='[W:1 P:BF-BC R:executor] fix the findings' model=sonnet \
  seed="$(seedspec f:BC:3 a:bf-BC)" \
  expect="$(exp_allow W-BF-APPROVAL)"

mk name=gate-158-bf-approval-lowercase-deny ac=AC-158 \
  note='only .wave/approvals/bf-bc.md (lower case) present: still denied - the lookup is byte-exact, not case-folded.' \
  state=state/p2-bc.json desc='[W:1 P:BF-BC R:executor] fix the findings' model=sonnet \
  seed="$(seedspec f:BC:3 a:bf-bc)" \
  expect="$(exp_deny W-BF-APPROVAL '.wave/approvals/bf-BC.md')"

mk name=gate-159-bf-approval-not-shared-deny ac=AC-159 \
  note='SEA done with findings 2 and only .wave/approvals/bf-BC.md present: BF-SEA is denied naming bf-SEA.md - approvals are per phase, never shared.' \
  state=state/p2-sea.json desc='[W:1 P:BF-SEA R:executor] fix the silent-error findings' model=sonnet \
  seed="$(seedspec f:SEA:2 a:bf-BC)" \
  expect="$(exp_deny W-BF-APPROVAL '.wave/approvals/bf-SEA.md' 'before re-running BF-SEA')"

mk name=gate-160a-bf-bc-own-findings-no-marker-deny ac=AC-160 \
  note='BC done, bf-BC.md present, .wave/findings/BC.md present but with no ^FINDINGS: [0-9]+$ line: BF-BC is denied W-MARKER quoting the regex and the offending first line.' \
  state=state/p2-bc.json desc='[W:1 P:BF-BC R:executor] fix the findings' model=sonnet \
  seed="$(seedspec fbad:BC a:bf-BC)" \
  expect="$(exp_deny W-MARKER 'marker `^FINDINGS: [0-9]+$` not found' 'first line: "no count on this line"')"

mk name=gate-160b-bf-bc-own-findings-marker-allow ac=AC-160 \
  note='the same dispatch with a well-formed findings file: allowed. Negative control for W-MARKER.' \
  state=state/p2-bc.json desc='[W:1 P:BF-BC R:executor] fix the findings' model=sonnet \
  seed="$(seedspec f:BC:2 a:bf-BC)" \
  expect="$(exp_allow W-MARKER)"

# ---------------------------------------------------------------------------
# P2.F  Round ceiling (AC-161..166, AC-169)
# ---------------------------------------------------------------------------

mk name=round-161-two-rounds-no-approval-deny ac=AC-161 \
  note='state.rounds["TDE-GREEN/executor"] == 2 and no rerun approval: the third round is denied W-ROUND naming the counter, the approval path and the surface-to-user remedy.' \
  state=state/p2-red-rounds2.json desc='[W:1 P:TDE-GREEN R:executor] make the tests pass' model=sonnet \
  expect="$(exp_deny W-ROUND 'state.rounds["TDE-GREEN/executor"] == 2' '.wave/approvals/rerun-TDE-GREEN-executor.md' 'surface the repeated failure to the user')"

mk name=round-162-one-round-allow ac=AC-162 \
  note='the same dispatch with the counter at 1: allowed. Negative control for W-ROUND and the boundary that kills an off-by-one.' \
  state=state/p2-red-rounds1.json desc='[W:1 P:TDE-GREEN R:executor] make the tests pass' model=sonnet \
  expect="$(exp_allow W-ROUND)"

mk name=round-163-two-rounds-approved-allow ac=AC-163 \
  note='the counter at 2 with .wave/approvals/rerun-TDE-GREEN-executor.md present: allowed.' \
  state=state/p2-red-rounds2.json desc='[W:1 P:TDE-GREEN R:executor] make the tests pass' model=sonnet \
  seed="$(seedspec a:rerun-TDE-GREEN-executor)" \
  expect="$(exp_allow)"

mk name=round-164-role-scoped-counter-allow ac=AC-164 \
  note='the executor counter at 2 and no reviewer rounds recorded: a reviewer dispatch is allowed - the counter is keyed on phase AND role.' \
  state=state/p2-red-rounds2.json desc='[W:1 P:TDE-GREEN R:reviewer] review the change' model=opus \
  expect="$(exp_allow)"

mk name=round-165-role-scoped-approval-deny ac=AC-165 \
  note='both counters at 2 and only the executor approval present: the reviewer dispatch is denied naming rerun-TDE-GREEN-reviewer.md - one approval cannot unlock a different role.' \
  state=state/p2-red-rounds2-both.json desc='[W:1 P:TDE-GREEN R:reviewer] review the change' model=opus \
  seed="$(seedspec a:rerun-TDE-GREEN-executor)" \
  expect="$(exp_deny W-ROUND '.wave/approvals/rerun-TDE-GREEN-reviewer.md')"

mk name=round-166-per-wave-counter-allow ac=AC-166 \
  note='a fresh wave 2 whose rounds is {}: the dispatch is allowed - the counter is per wave, and nothing carries over.' \
  state=state/p2-red-wave2.json desc='[W:2 P:TDE-GREEN R:executor] make the tests pass' model=sonnet \
  expect="$(exp_allow)"

mk name=round-169-anytime-exempt-allow ac=AC-169 \
  note='state.rounds["AD/writer"] == 5 on an anytime row: allowed - an anytime row is exempt from the ceiling.' \
  state=state/p2-ad-rounds5.json desc='[W:1 P:AD R:writer] update the dashboard' model=haiku \
  expect="$(exp_allow)"

# ---------------------------------------------------------------------------
# P2.G  Budgets (AC-170..180)
# ---------------------------------------------------------------------------

p2_ledger() {
  # p2_ledger <phase> <output>... -> one ledger line per output value, in the
  # shape spec section 9 pins. The literal budget numbers live in the case
  # notes and in the expected reason, so a wrong hooks/budgets.tsv value reds
  # the case instead of silently rescaling it.
  local phase="$1"; shift
  local out="" v i=0
  for v in "$@"; do
    i=$((i + 1))
    out="$out$(jq -nc --arg a "agent-$phase-$i" --arg p "$phase" --argjson o "$v" \
      '{agent:$a, phase:$p, role:"executor", requested:"sonnet",
        resolved:"claude-sonnet-4-5-20250929", tier_ok:true, tier_verified:true,
        input:1234, output:$o, cache_read:0, cache_create:0, turns:7,
        stopped:"2026-09-09T12:30:00Z"}')
"
  done
  printf '%s' "$out"
}

mk name=budget-170-over-one-x-warn ac=AC-170 \
  note='hooks/budgets.tsv gives TDE-GREEN 3000 output tokens and its fanout is 1, so the effective budget is 3000; the ledger sums 4200 (1.4x): allowed with a W-BUDGET warning naming 4200, 3000 and 1.4x.' \
  state=state/p2-red.json desc='[W:1 P:TDE-GREEN R:executor] make the tests pass' model=sonnet \
  seed="$(jq -nc --arg l "$(p2_ledger TDE-GREEN 2000 1500 700)" '{".wave/ledger.jsonl": $l}')" \
  expect="$(exp_warn W-BUDGET 'TDE-GREEN exceeded budget (spent 4200, limit 3000, 1.4x)')"

mk name=budget-171-under-budget-allow ac=AC-171 \
  note='the same ledger summing 2700 (0.9x of 3000): allowed with no W-BUDGET text in stdout. Negative control for W-BUDGET.' \
  state=state/p2-red.json desc='[W:1 P:TDE-GREEN R:executor] make the tests pass' model=sonnet \
  seed="$(jq -nc --arg l "$(p2_ledger TDE-GREEN 2000 700)" '{".wave/ledger.jsonl": $l}')" \
  expect="$(exp_allow W-BUDGET)"

mk name=budget-172-over-two-x-deny ac=AC-172 \
  note='the ledger summing 6300 (2.1x) with no .wave/approvals/budget-TDE-GREEN.md: denied W-BUDGET naming the ratio and the approval path.' \
  state=state/p2-red.json desc='[W:1 P:TDE-GREEN R:executor] make the tests pass' model=sonnet \
  seed="$(jq -nc --arg l "$(p2_ledger TDE-GREEN 3000 3300)" '{".wave/ledger.jsonl": $l}')" \
  expect="$(exp_deny W-BUDGET 'spent 6300, limit 3000, 2.1x' '.wave/approvals/budget-TDE-GREEN.md')"

mk name=budget-173-over-two-x-approved-allow ac=AC-173 \
  note='the same overage with .wave/approvals/budget-TDE-GREEN.md present: allowed, and the warning is not re-emitted either.' \
  state=state/p2-red.json desc='[W:1 P:TDE-GREEN R:executor] make the tests pass' model=sonnet \
  seed="$(jq -nc --arg l "$(p2_ledger TDE-GREEN 3000 3300)" --arg a "Approved by the user on 2026-09-09."$'\n' \
    '{".wave/ledger.jsonl": $l, ".wave/approvals/budget-TDE-GREEN.md": $a}')" \
  expect="$(exp_allow)"

mk name=budget-174a-exactly-one-x-allow ac=AC-174 \
  note='the ledger summing exactly 3000 (1.0x): allowed with no warning - the boundary is strictly greater.' \
  state=state/p2-red.json desc='[W:1 P:TDE-GREEN R:executor] make the tests pass' model=sonnet \
  seed="$(jq -nc --arg l "$(p2_ledger TDE-GREEN 2000 1000)" '{".wave/ledger.jsonl": $l}')" \
  expect="$(exp_allow)"

mk name=budget-174b-exactly-two-x-warn ac=AC-174 \
  note='the ledger summing exactly 6000 (2.0x): allowed with a warning and NO deny - the deny boundary is strictly greater than 2x.' \
  state=state/p2-red.json desc='[W:1 P:TDE-GREEN R:executor] make the tests pass' model=sonnet \
  seed="$(jq -nc --arg l "$(p2_ledger TDE-GREEN 3000 3000)" '{".wave/ledger.jsonl": $l}')" \
  expect="$(exp_warn W-BUDGET 'spent 6000, limit 3000, 2.0x')"

mk name=budget-175-per-phase-sum-allow ac=AC-175 \
  note='a ledger holding only TDE-RED lines far over the TDE-RED budget: a TDE-GREEN dispatch is allowed with no warning - budgets are summed per phase.' \
  state=state/p2-red.json desc='[W:1 P:TDE-GREEN R:executor] make the tests pass' model=sonnet \
  seed="$(jq -nc --arg l "$(p2_ledger TDE-RED 9000 9000)" '{".wave/ledger.jsonl": $l}')" \
  expect="$(exp_allow)"

mk name=budget-176-no-ledger-allow ac=AC-176 \
  note='.wave/ledger.jsonl absent: allowed with no W-BUDGET output - an absent ledger is not a measurement.' \
  state=state/p2-red.json desc='[W:1 P:TDE-GREEN R:executor] make the tests pass' model=sonnet \
  expect="$(exp_allow)"

# Line 1 parses, line 2 is truncated mid-object, line 3 parses. The parsable
# lines sum to 2,000 — under the 3,000 budget — so if the malformed line's
# 99,000 were counted the case would go red on a W-BUDGET instead of a W-STATE.
P2_LEDGER_MALFORMED="$(jq -nc '{agent:"agent-tg-a", phase:"TDE-GREEN", role:"executor", requested:"sonnet", resolved:"claude-sonnet-4-5-20250929", tier_ok:true, tier_verified:true, input:1234, output:1000, cache_read:0, cache_create:0, turns:7, stopped:"2026-09-09T12:30:00Z"}')
{\"phase\": \"TDE-GREEN\", \"output\": 99000
$(jq -nc '{agent:"agent-tg-b", phase:"TDE-GREEN", role:"executor", requested:"sonnet", resolved:"claude-sonnet-4-5-20250929", tier_ok:true, tier_verified:true, input:1234, output:1000, cache_read:0, cache_create:0, turns:7, stopped:"2026-09-09T12:30:00Z"}')
"

mk name=budget-177-malformed-line-warn ac=AC-177 \
  note='a ledger whose 2nd line is malformed JSON: allowed, the parsable lines are summed (2000, under budget), additionalContext carries W-STATE naming the skipped line number, and there is no deny - a corrupt ledger must never manufacture a W-BUDGET.' \
  state=state/p2-red.json desc='[W:1 P:TDE-GREEN R:executor] make the tests pass' model=sonnet \
  seed="$(jq -nc --arg l "$P2_LEDGER_MALFORMED" '{".wave/ledger.jsonl": $l}')" \
  expect="$(jq -nc '{exit:0, decision:"warn", rule:"W-STATE", reason_template:"W-STATE", reason_contains:["line 2"], stdout_absent:["W-BUDGET"]}')"

mk name=budget-177b-well-formed-ledger-allow ac='AC-177 (companion: the W-STATE negative control)' \
  note='the budget-177 ledger with its malformed line removed: allowed, and stdout carries no W-STATE at all. Negative control for W-STATE - budget-177, prompt-185a and prompt-185b are the only .json cases that assert a W-STATE warning, and a rule with a positive case and no negative control is a harness failure by design.' \
  state=state/p2-red.json desc='[W:1 P:TDE-GREEN R:executor] make the tests pass' model=sonnet \
  seed="$(jq -nc --arg l "$(p2_ledger TDE-GREEN 1000 1000)" '{".wave/ledger.jsonl": $l}')" \
  expect="$(jq -nc '{exit:0, decision:"silent", negative_control_for:"W-STATE", stdout_absent:["W-STATE","W-BUDGET"]}')"

mk name=budget-179a-fanout-under-effective-allow ac=AC-179 \
  note='TEET has fanout 3 and a 2000-token budget, so the effective budget is 6000; the ledger sums 5000 (2.5x the row value, 0.83x the effective budget): allowed with no deny and no warning.' \
  state=state/p2-teettc.json desc='[W:1 P:TEET R:executor] run the end-to-end suite' model=sonnet \
  seed="$(jq -nc --arg l "$(p2_ledger TEET 2000 2000 1000)" '{".wave/ledger.jsonl": $l}')" \
  expect="$(exp_allow)"

mk name=budget-179b-fanout-over-two-x-deny ac=AC-179 \
  note='the same phase with the ledger summing 13000 (6.5x the row value): denied, naming the effective budget 6000 and the ratio against it.' \
  state=state/p2-teettc.json desc='[W:1 P:TEET R:executor] run the end-to-end suite' model=sonnet \
  seed="$(jq -nc --arg l "$(p2_ledger TEET 5000 5000 3000)" '{".wave/ledger.jsonl": $l}')" \
  expect="$(exp_deny W-BUDGET 'spent 13000, limit 6000, 2.1x' '.wave/approvals/budget-TEET.md')"

mk name=budget-180-anytime-exempt-allow ac=AC-180 \
  note='a ledger of AD lines summing 2500, five times the 500-token AD budget: allowed with no W-BUDGET - an anytime row is exempt from the budget gate.' \
  state=state/valid-full.json desc='[W:1 P:AD R:writer] update the dashboard' model=haiku \
  seed="$(jq -nc --arg l "$(p2_ledger AD 1500 1000)" '{".wave/ledger.jsonl": $l}')" \
  expect="$(exp_allow)"

# ---------------------------------------------------------------------------
# P2.H  Prompt size and verbatim pastes (AC-181..189)
# ---------------------------------------------------------------------------

p2_rep() {
  # p2_rep <char> <count> -> <count> copies of <char>, without a trailing
  # newline. Built with awk so a 24,000-character fixture does not depend on
  # `seq` producing 24,000 words.
  command awk -v c="$1" -v n="$2" 'BEGIN { s = ""; for (i = 0; i < n; i++) s = s c; printf "%s", s }'
}

P2_PROMPT_8001="$(p2_rep x 8001)"
P2_PROMPT_8000="$(p2_rep x 8000)"
P2_PROMPT_24001="$(p2_rep x 24001)"
# 23,001 ASCII plus 1,000 four-byte emoji = 24,001 Unicode scalar values and
# 27,001 bytes: the case that separates a scalar-value count from a byte count.
P2_PROMPT_EMOJI="$(p2_rep x 23001)$(p2_rep '😀' 1000)"

# A 6,000-character .wave/ac.md whose lines are all distinct, so the longest
# block it shares with a prompt is exactly the pasted one and not an artefact
# of repetition. `@` never appears in it, which is why the prompt can end the
# pasted block with `@@` and pin the measured length at exactly 4,200.
P2_AC_MD="$(command awk 'BEGIN {
  s = ""; i = 0;
  while (length(s) < 6000) {
    i++;
    s = s sprintf("AC-%04d the %04dth acceptance criterion, with padding text so the line is long enough to matter.\n", i, i);
  }
  printf "%s", substr(s, 1, 6000);
}')"
# The file is pure ASCII, so a bash substring is byte-exact here regardless of
# locale — which is what "byte-identical block" means.
P2_PASTE_4200="${P2_AC_MD:0:4200}"
P2_PASTE_3900="${P2_AC_MD:0:3900}"
# 4,200 characters that share no 4,000-character block with anything under
# .wave/: a different prefix and a different padding sentence.
P2_UNRELATED_4200="$(command awk 'BEGIN {
  s = ""; i = 0;
  while (length(s) < 4200) {
    i++;
    s = s sprintf("ZZ-%04d an unrelated line that appears in no wave artifact whatsoever, only in this prompt.\n", i);
  }
  printf "%s", substr(s, 1, 4200);
}')"

mk name=prompt-181-8001-warn ac=AC-181 \
  note='a prompt of 8,001 characters: allowed with a W-PROMPT warning naming the measured length and the 8,000-character cap.' \
  state=state/valid-full.json desc='[W:1 P:AC R:lead] write the ACs' model=opus \
  prompt="$P2_PROMPT_8001" \
  expect="$(exp_warn W-PROMPT 'prompt is 8001 characters, over the 8000-character lean-context cap')"

mk name=prompt-182-8000-allow ac=AC-182 \
  note='the same prompt at exactly 8,000 characters: allowed with no W-PROMPT output. Boundary negative control.' \
  state=state/valid-full.json desc='[W:1 P:AC R:lead] write the ACs' model=opus \
  prompt="$P2_PROMPT_8000" \
  expect="$(exp_allow W-PROMPT)"

mk name=prompt-183-24001-warn-no-deny ac=AC-183 \
  note='a prompt of 24,001 characters carrying no .wave/ file content: allowed with a warning naming both the 8,000 and the 24,000 thresholds, and NO deny - the framework needs cross-team data to pass through the orchestrator, so a hard cap would force a worse brief.' \
  state=state/valid-full.json desc='[W:1 P:AC R:lead] write the ACs' model=opus \
  prompt="$P2_PROMPT_24001" \
  expect="$(jq -nc '{exit:0, decision:"warn", rule:"W-PROMPT", reason_template:"W-PROMPT", reason_contains:["prompt is 24001 characters","8000-character lean-context cap","24000-character"], stdout_absent:["permissionDecision"]}')"

mk name=prompt-184-absent-allow ac=AC-184 \
  note='tool_input.prompt absent entirely: allowed with no W-PROMPT - an absent prompt is length 0, never an error.' \
  state=state/valid-full.json desc='[W:1 P:AC R:lead] write the ACs' model=opus \
  prompt=@absent \
  expect="$(exp_allow)"

mk name=prompt-185a-array-warn ac=AC-185 \
  note='tool_input.prompt sent as a JSON array: allowed with additionalContext carrying W-STATE naming the unexpected type, never a deny - the size checks measured nothing, so they say nothing.' \
  state=state/valid-full.json desc='[W:1 P:AC R:lead] write the ACs' model=opus \
  promptjson='["first part","second part"]' \
  expect="$(jq -nc '{exit:0, decision:"warn", rule:"W-STATE", reason_template:"W-STATE", reason_contains:["JSON array"], stdout_absent:["W-PROMPT","W-PASTE","permissionDecision"]}')"

mk name=prompt-185b-number-warn ac=AC-185 \
  note='the same with tool_input.prompt sent as a JSON number.' \
  state=state/valid-full.json desc='[W:1 P:AC R:lead] write the ACs' model=opus \
  promptjson='12345' \
  expect="$(jq -nc '{exit:0, decision:"warn", rule:"W-STATE", reason_template:"W-STATE", reason_contains:["JSON number"], stdout_absent:["W-PROMPT","W-PASTE","permissionDecision"]}')"

mk name=prompt-185c-string-prompt-allow ac='AC-185 (companion)' \
  note='the prompt-185a/b dispatch with tool_input.prompt sent as an ordinary short string: silent allow, no W-STATE. It isolates the type as the discriminator, so the two type warnings above cannot be passing for some other reason.' \
  state=state/valid-full.json desc='[W:1 P:AC R:lead] write the ACs' model=opus \
  prompt='Write the acceptance criteria into .wave/ac.md.' \
  expect="$(jq -nc '{exit:0, decision:"silent", stdout_absent:["W-STATE","W-PROMPT","W-PASTE"]}')"

mk name=prompt-186-scalar-values-not-bytes-warn ac=AC-186 \
  note='24,001 Unicode scalar values including 1,000 four-byte emoji (27,001 bytes): the warning names 24001, because length is counted in scalar values after JSON unescaping, not in bytes.' \
  state=state/valid-full.json desc='[W:1 P:AC R:lead] write the ACs' model=opus \
  prompt="$P2_PROMPT_EMOJI" \
  expect="$(exp_warn W-PROMPT 'prompt is 24001 characters')"

mk name=paste-187-4200-block-deny ac=AC-187 \
  note='.wave/ac.md of 6,000 characters and a prompt carrying a 4,200-character block byte-identical to its first 4,200: denied W-PASTE naming the file, the measured block length and the remedy that the subagent reads the file itself.' \
  state=state/valid-full.json desc='[W:1 P:AC R:lead] write the ACs' model=opus \
  prompt="Context follows.
$P2_PASTE_4200@@ end of pasted material, proceed." \
  seed="$(jq -nc --arg c "$P2_AC_MD" '{".wave/ac.md": $c}')" \
  expect="$(exp_deny W-PASTE 'a 4200-character block' '.wave/ac.md' 'the subagent can read .wave/ files itself')"

mk name=paste-188-3900-block-allow ac=AC-188 \
  note='the same with a 3,900-character identical block: allowed with no W-PASTE. Boundary negative control - the threshold is 4,000. The prompt is padded past 4,000 characters on purpose: without the padding the case would pass because the whole prompt is too short to be scanned at all, which pins the wrong boundary and let a lowered threshold survive the mutation sweep.' \
  state=state/valid-full.json desc='[W:1 P:AC R:lead] write the ACs' model=opus \
  prompt="Context follows.
$P2_PASTE_3900@@ end of pasted material, proceed. $(p2_rep q 250)" \
  seed="$(jq -nc --arg c "$P2_AC_MD" '{".wave/ac.md": $c}')" \
  expect="$(exp_allow W-PASTE)"

mk name=paste-189-unrelated-block-allow ac=AC-189 \
  note='a 4,200-character block matching no file under .wave/, in a prompt of 24,001 characters: allowed with no W-PASTE (the size warning still fires) - the deny is on the pollution pattern, not on size.' \
  state=state/valid-full.json desc='[W:1 P:AC R:lead] write the ACs' model=opus \
  prompt="$P2_UNRELATED_4200$(p2_rep y 19801)" \
  seed="$(jq -nc --arg c "$P2_AC_MD" '{".wave/ac.md": $c}')" \
  expect="$(jq -nc '{exit:0, decision:"warn", rule:"W-PROMPT", reason_template:"W-PROMPT", reason_contains:["prompt is 24001 characters"], stdout_absent:["W-PASTE","permissionDecision"]}')"

printf '%s case files in %s\n' "$count" "$WV_CASES_DIR"
