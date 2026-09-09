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
  # mk key=value ... ; keys: name ac note state desc prompt model subagent
  # agent tool cmd noinput seed expect
  local name="" ac="" note="" state="state/full-all-done.json"
  local desc="@absent" prompt="Do the thing." model="@absent"
  local subagent="general-purpose" agent="" tool="Agent" cmd=""
  local noinput="" seed="" expect="{}" event="PreToolUse"
  local kv k v
  for kv in "$@"; do
    [ -z "$kv" ] && continue
    k="${kv%%=*}"; v="${kv#*=}"
    case "$k" in
      name) name="$v" ;; ac) ac="$v" ;; note) note="$v" ;;
      state) state="$v" ;; desc) desc="$v" ;; prompt) prompt="$v" ;;
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
    [ "$prompt" = "@absent" ] || ti="$(printf '%s' "$ti" | jq --arg v "$prompt" '. + {prompt: $v}')"
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

printf '%s case files in %s\n' "$count" "$WV_CASES_DIR"
