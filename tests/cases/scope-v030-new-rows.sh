#!/usr/bin/env bash
# tests/cases/scope-v030-new-rows.sh — UIA / BEN / ES / BF-ES / BEN-CLOSE
# dispatch behaviour (design section 11, excluding advisory-agreement,
# wave-close, W-UNDELIVERED and wave-complete).
#
# Each leg builds a state from valid-full.json, drives pre-agent.sh, and
# asserts the deny or the silent allow. Negative controls sit next to their
# deny: the same phase, the flag answered the other way, or the predecessor
# done.
set -u

# shellcheck source=tests/lib/assert.sh
source "$(dirname "$0")/../lib/assert.sh"

name="${WV_CASE_NAME:-$(basename "$0" .sh)}"
log="${WV_CASE_LOG:-$WV_RUN_TMP/logs/$name.log}"
rc=0
fail() { printf 'ASSERT FAIL: %s\n' "$*" >&2; rc=1; }
printf 'RAN pre-agent.sh %s decision=multi\n' "$name" >> "$log"

reason_of() {
  printf '%s' "$WV_LAST_STDOUT" | jq -r \
    '.hookSpecificOutput.permissionDecisionReason // .hookSpecificOutput.additionalContext // empty'
}

drive() {
  # drive <label> <jq-over-valid-full> <phase> <role> <model> [seed-files-json]
  local label="$1" filter="$2" phase="$3" role="$4" model="$5"
  local files="${6:-}"
  WV_PROJECT="$(mkproj)"
  local st="$WV_RUN_TMP/$name-$label-state.json" c="$WV_RUN_TMP/$name-$label.json"
  if ! jq "$filter" "$WV_TESTS_DIR/fixtures/state/valid-full.json" > "$st"; then
    fail "$label: could not build the state"
    return 1
  fi
  local seed
  seed="$(jq -nc --arg st "$st" '{state: $st}')"
  if [ -n "$files" ]; then
    seed="$(printf '%s' "$seed" | jq --argjson f "$files" '.files = $f')"
  fi
  jq -n --argjson seed "$seed" --arg d "[W:1 P:$phase R:$role] probe" --arg m "$model" '{
    script: "pre-agent.sh",
    seed: $seed,
    stdin: {
      session_id: "1a2b0599-4617-4e73-a9c0-2bef462b2626",
      cwd: ".",
      hook_event_name: "PreToolUse",
      tool_name: "Agent",
      tool_input: {description: $d, subagent_type: "general-purpose", model: $m}
    },
    expect: {}
  }' > "$c" || { fail "$label: could not build the case"; return 1; }
  run_hook pre-agent.sh "$c" || { fail "$label: run_hook: $WV_LAST_STDERR"; return 1; }
  return 0
}

expect_deny() {
  local label="$1" rule="$2"
  assert_deny "$rule" || fail "$label: want deny($rule), got '$(reason_of)'"
  assert_reason_matches_template "$rule" || fail "$label: template"
}

expect_allow() {
  local label="$1"
  assert_allow || fail "$label: want silent allow, got '$WV_LAST_STDOUT'"
  assert_stdout_absent W-SCOPE || fail "$label: W-SCOPE leaked"
  assert_stdout_absent W-COND || fail "$label: W-COND leaked"
  assert_stdout_absent W-ORDER || fail "$label: W-ORDER leaked"
}

# ---- both flags unknown: AC, UIA, BEN denied W-SCOPE ----------------------

UNK='.ui = "unknown" | .behaviour_change = "unknown" | .cr_enabled = "unknown" | .vocabulary = "unknown"'

if drive ac-both-unknown "$UNK" AC lead opus; then
  expect_deny ac-both-unknown W-SCOPE
  assert_reason_contains 'vocabulary' || fail "ac-both-unknown: reason must name vocabulary: '$(reason_of)'"
  assert_reason_contains 'scripts/wave-set.sh vocabulary true|false' \
    || fail "ac-both-unknown: reason must name the wave-set command: '$(reason_of)'"
fi

if drive uia-both-unknown "$UNK" UIA lead opus; then
  expect_deny uia-both-unknown W-SCOPE
  assert_reason_contains 'vocabulary' || fail "uia-both-unknown: '$(reason_of)'"
fi

if drive ben-both-unknown "$UNK" BEN lead opus; then
  expect_deny ben-both-unknown W-SCOPE
  # BEN's own flag, or UIA as unanswered predecessor — either is W-SCOPE.
  case "$(reason_of)" in
    *vocabulary*|*behaviour_change*) : ;;
    *) fail "ben-both-unknown: reason must name a flag: '$(reason_of)'" ;;
  esac
fi

# ---- one early answer given, the other unknown -----------------------------
#
# The gate enforces each flag only at the rows that read it: UIA reads
# vocabulary, BEN reads behaviour_change (and has UIA as its predecessor), AC
# names both. So with vocabulary true and behaviour_change unknown UIA is
# allowed, and BEN and AC are W-SCOPE on behaviour_change. "Both answers
# before the first dispatch" is /wave-start's policy, not a gate rule; the
# gate's rule is "both answers before AC".

MIXED_VT='.vocabulary = true | .behaviour_change = "unknown" | .ui = "unknown" | .cr_enabled = "unknown"'
if drive uia-vocab-true-bc-unknown "$MIXED_VT" UIA lead opus; then
  expect_allow uia-vocab-true-bc-unknown
fi
if drive ben-vocab-true-bc-unknown "$MIXED_VT | .phases = {UIA: {status: \"done\"}}" BEN lead opus; then
  expect_deny ben-vocab-true-bc-unknown W-SCOPE
  assert_reason_contains 'behaviour_change' || fail "ben-vocab-true-bc-unknown: '$(reason_of)'"
fi
if drive ac-vocab-true-bc-unknown "$MIXED_VT | .phases = {UIA: {status: \"done\"}}" AC lead opus; then
  expect_deny ac-vocab-true-bc-unknown W-SCOPE
  assert_reason_contains 'behaviour_change' || fail "ac-vocab-true-bc-unknown: '$(reason_of)'"
fi
# The mirror: behaviour_change true, vocabulary unknown. BEN waits on UIA's
# unanswered flag.
MIXED_BT='.vocabulary = "unknown" | .behaviour_change = true | .ui = "unknown" | .cr_enabled = "unknown"'
if drive ben-bc-true-vocab-unknown "$MIXED_BT" BEN lead opus; then
  expect_deny ben-bc-true-vocab-unknown W-SCOPE
  assert_reason_contains 'vocabulary' || fail "ben-bc-true-vocab-unknown: '$(reason_of)'"
fi

# ---- the prose agrees with the legs above ----------------------------------
# Every passage that says when the two early answers are due must keep the
# three facts apart: asking both before init / the first dispatch is the
# command's POLICY; the GATE requires both before AC; UIA needs only
# vocabulary. None may claim the first-dispatch timing is enforced because AC
# names UIA and BEN (the uia-vocab-true-bc-unknown leg is the counterexample).

para() {
  # para <file> <ERE> -> the first blank-line-separated paragraph matching ERE,
  # joined onto one line.
  awk -v RS= -v re="$2" '$0 ~ re { gsub(/\n/, " "); print; exit }' "$WV_REPO_ROOT/$1"
}

prose_check() {
  # prose_check <label> <file> <paragraph-ERE>
  local label="$1" file="$2" text
  text="$(para "$file" "$3")"
  if [ -z "$text" ]; then
    fail "prose $label: no paragraph in $file matches '$3'"
    return
  fi
  printf '%s' "$text" | command grep -qiE 'polic(y|ies)' \
    || fail "prose $label ($file): must call the first-dispatch timing the command's policy: '$text'"
  printf '%s' "$text" | command grep -qE 'before `\[?AC\]?`|`\[?AC\]?`[^.]* cannot be dispatched until' \
    || fail "prose $label ($file): must say the gate requires both answers before AC: '$text'"
  printf '%s' "$text" | command grep -qE '`\[?UIA\]?`[^.;]*(only `vocabulary`|`vocabulary` alone)' \
    || fail "prose $label ($file): must say UIA needs only vocabulary: '$text'"
  if printf '%s' "$text" | command grep -qiE 'first dispatch[*]*,? because|must be known before the first dispatch'; then
    fail "prose $label ($file): still presents the first-dispatch timing as gate-enforced: '$text'"
  fi
}

prose_check ref04-when-due framework/references/04-meta-orchestration.md 'When each answer is due'
prose_check skill-contract skills/wave-orchestrator/SKILL.md 'initialises `[.]wave/state[.]json`'
# Controls: the passages round 4 already corrected keep passing.
prose_check skill-v030 skills/wave-orchestrator/SKILL.md 'Two scope answers before'
prose_check design-3.1 docs/design/2026-09-18-benefit-contract-phases.md '^`AC` names `UIA` and `BEN` as predecessors'

# ---- an ABSENT flag is reported as absent, not as an answer ----------------
# A state written before 0.3.0 has no vocabulary key; the W-COND remedy says so
# instead of claiming the wave answered false.
if drive uia-vocab-absent 'del(.vocabulary) | .behaviour_change = false' UIA lead opus; then
  expect_deny uia-vocab-absent W-COND
  assert_reason_contains 'state.vocabulary is absent from .wave/state.json' \
    || fail "uia-vocab-absent: '$(reason_of)'"
fi
if drive ben-bc-absent 'del(.behaviour_change) | .vocabulary = false' BEN lead opus; then
  expect_deny ben-bc-absent W-COND
  assert_reason_contains 'state.behaviour_change is absent from .wave/state.json' \
    || fail "ben-bc-absent: '$(reason_of)'"
fi
# Answered false still says false.
if drive uia-vocab-false-detail '.vocabulary = false | .behaviour_change = false' UIA lead opus; then
  assert_reason_contains 'state.vocabulary is false in .wave/state.json' \
    || fail "uia-vocab-false-detail: '$(reason_of)'"
fi

# ---- answered false, ui/cr still unknown: AC silent -----------------------

FALSE_EARLY='.ui = "unknown" | .behaviour_change = false | .cr_enabled = "unknown" | .vocabulary = false'

if drive ac-answered-false "$FALSE_EARLY" AC lead opus; then
  expect_allow ac-answered-false
fi

# ---- demo with every flag unknown: AC silent ------------------------------

DEMO_UNK='.mode = "demo" | .ui = "unknown" | .behaviour_change = "unknown" | .cr_enabled = "unknown" | .vocabulary = "unknown"'

if drive demo-unknown-ac "$DEMO_UNK" AC lead opus; then
  expect_allow demo-unknown-ac
fi

# ---- vocabulary=true: AC before UIA is W-ORDER ----------------------------

VOCAB_TRUE='.vocabulary = true | .behaviour_change = false | .ui = false | .cr_enabled = false'

if drive ac-before-uia "$VOCAB_TRUE" AC lead opus; then
  expect_deny ac-before-uia W-ORDER
  assert_reason_contains 'UIA' || fail "ac-before-uia: must name UIA: '$(reason_of)'"
  assert_reason_contains 'required because state.vocabulary is true' \
    || fail "ac-before-uia: missing required-because: '$(reason_of)'"
fi

# Negative: UIA done, AC allowed.
if drive ac-uia-done "$VOCAB_TRUE | .phases = {UIA: {status: \"done\"}}" AC lead opus; then
  expect_allow ac-uia-done
fi

# ---- vocabulary=true: SEA before ES is W-ORDER ----------------------------

THROUGH_BFBC='.vocabulary = true | .behaviour_change = false | .ui = false | .cr_enabled = false | .phases = {
  AC:{status:"done"}, ACB:{status:"done"}, DR:{status:"done"},
  "TDE-RED":{status:"done"}, "TDE-GREEN":{status:"done"}, CR:{status:"done"},
  BC:{status:"done"}, "BF-BC":{status:"done"}
}'

if drive sea-before-es "$THROUGH_BFBC" SEA executor sonnet; then
  expect_deny sea-before-es W-ORDER
  assert_reason_contains 'ES' || fail "sea-before-es: must name ES: '$(reason_of)'"
fi

# ---- vocabulary=true: BF-ES with FINDINGS: 0 is W-COND --------------------

THROUGH_ES="$THROUGH_BFBC | .phases.ES = {status: \"done\"}"
FILES_ES0='{".wave/findings/ES.md": "FINDINGS: 0\n", ".wave/approvals/bf-ES.md": "ok\n"}'

if drive bf-es-zero "$THROUGH_ES" BF-ES executor sonnet "$FILES_ES0"; then
  expect_deny bf-es-zero W-COND
  assert_reason_contains 'findings:ES' || fail "bf-es-zero: must name findings:ES: '$(reason_of)'"
  assert_reason_contains 'FINDINGS: 0' || fail "bf-es-zero: must name the zero count: '$(reason_of)'"
fi

# ---- vocabulary=true: BF-ES FINDINGS: 2, no approval, W-BF-APPROVAL --------

FILES_ES2='{".wave/findings/ES.md": "FINDINGS: 2\n"}'

if drive bf-es-no-approval "$THROUGH_ES" BF-ES executor sonnet "$FILES_ES2"; then
  expect_deny bf-es-no-approval W-BF-APPROVAL
  assert_reason_contains 'bf-ES.md' || fail "bf-es-no-approval: '$(reason_of)'"
fi

# Negative: findings 2 + approval → allow.
FILES_ES2A='{".wave/findings/ES.md": "FINDINGS: 2\n", ".wave/approvals/bf-ES.md": "fix both\n"}'
if drive bf-es-approved "$THROUGH_ES" BF-ES executor sonnet "$FILES_ES2A"; then
  expect_allow bf-es-approved
fi

# ---- vocabulary=false: UIA, ES, BF-ES denied W-COND; BF-ES names findings:ES

VOCAB_FALSE='.vocabulary = false | .behaviour_change = false | .ui = false | .cr_enabled = false'

if drive uia-vocab-false "$VOCAB_FALSE" UIA lead opus; then
  expect_deny uia-vocab-false W-COND
  assert_reason_contains 'vocabulary' || fail "uia-vocab-false: '$(reason_of)'"
  assert_reason_contains 'scripts/wave-set.sh vocabulary true' \
    || fail "uia-vocab-false: must name wave-set: '$(reason_of)'"
fi

if drive es-vocab-false "$THROUGH_BFBC | .vocabulary = false" ES executor sonnet; then
  expect_deny es-vocab-false W-COND
  assert_reason_contains 'vocabulary' || fail "es-vocab-false: '$(reason_of)'"
fi

# BF-ES with no findings file, ES not done, vocab false: W-COND naming findings:ES
if drive bf-es-skipped "$THROUGH_BFBC | .vocabulary = false" BF-ES executor sonnet; then
  expect_deny bf-es-skipped W-COND
  assert_reason_contains 'findings:ES' \
    || fail "bf-es-skipped: WV_COND_TEXT must be findings:ES, got '$(reason_of)'"
  case "$(reason_of)" in
    *'condition `vocabulary`'*) fail "bf-es-skipped: leaked the source condition: '$(reason_of)'" ;;
  esac
  assert_reason_contains 'ES does not run in this wave' \
    || fail "bf-es-skipped: missing skip detail: '$(reason_of)'"
fi

# Absent vocabulary key (older state): same as false.
ABSENT='.vocabulary = null | del(.vocabulary) | .behaviour_change = false | .ui = false | .cr_enabled = false'
if drive uia-vocab-absent "$ABSENT" UIA lead opus; then
  expect_deny uia-vocab-absent W-COND
fi

# SEA dispatchable straight after BF-BC when vocab is false.
if drive sea-after-bfbc-vocab-false "$THROUGH_BFBC | .vocabulary = false" SEA executor sonnet; then
  expect_allow sea-after-bfbc-vocab-false
fi

# ---- vocabulary=unknown at SEA → W-SCOPE, never skipped through -----------

if drive sea-vocab-unknown "$THROUGH_BFBC | .vocabulary = \"unknown\"" SEA executor sonnet; then
  expect_deny sea-vocab-unknown W-SCOPE
  assert_reason_contains 'vocabulary' || fail "sea-vocab-unknown: '$(reason_of)'"
fi

# ---- ES done with FINDINGS: 2, then vocabulary flipped to false: BF-ES still met

FLIP='.vocabulary = false | .behaviour_change = false | .ui = false | .cr_enabled = false | .phases = {
  AC:{status:"done"}, ACB:{status:"done"}, DR:{status:"done"},
  "TDE-RED":{status:"done"}, "TDE-GREEN":{status:"done"}, CR:{status:"done"},
  BC:{status:"done"}, "BF-BC":{status:"done"}, ES:{status:"done"}
}'
if drive bf-es-after-flip "$FLIP" BF-ES executor sonnet "$FILES_ES2A"; then
  expect_allow bf-es-after-flip
fi

# ---- behaviour_change=true, BEN done: COMMIT before BEN-CLOSE denied ------

THROUGH_BFBTEET_BEN='.vocabulary = false | .behaviour_change = true | .ui = false | .cr_enabled = false | .phases = {
  UIA:{status:"done"}, BEN:{status:"done"},
  AC:{status:"done"}, ACB:{status:"done"}, DR:{status:"done"},
  "TDE-RED":{status:"done"}, "TDE-GREEN":{status:"done"}, CR:{status:"done"},
  BC:{status:"done"}, "BF-BC":{status:"done"},
  SEA:{status:"done"}, "BF-SEA":{status:"done"},
  DS:{status:"done"}, "BF-DS":{status:"done"},
  BSEA:{status:"done"}, "BF-BSEA":{status:"done"},
  OA:{status:"done"}, "TEET-TC":{status:"done"}, TEET:{status:"done"},
  "BF-TEET":{status:"done"}, BTEET:{status:"done"}, "BTEET-X":{status:"done"},
  "BF-BTEET":{status:"done"}
}'

if drive commit-before-ben-close "$THROUGH_BFBTEET_BEN" COMMIT executor sonnet; then
  expect_deny commit-before-ben-close W-ORDER
  assert_reason_contains 'BEN-CLOSE' || fail "commit-before-ben-close: '$(reason_of)'"
  assert_reason_contains 'required because BEN ran' \
    || fail "commit-before-ben-close: missing done: because: '$(reason_of)'"
fi

# Negative: BEN-CLOSE done, COMMIT allowed.
if drive commit-ben-close-done "$THROUGH_BFBTEET_BEN | .phases[\"BEN-CLOSE\"] = {status: \"done\"}" COMMIT executor sonnet; then
  expect_allow commit-ben-close-done
fi

# ---- BEN not done and AC done: the legacy discriminator ------------------
#
# A wave started before 0.3.0 has no `vocabulary` key in state.json (every
# 0.3.0 wave-init writes one). In such a wave BEN has no entry in .phases and
# AC, which names BEN in its `after`, is done: the wave was past BEN's position
# when it was upgraded, so BEN is superseded (lib.sh wv_row_superseded),
# BEN-CLOSE is skipped and the tail is unchanged.
#
# A 0.3.0 wave with the same phase map (behaviour_change answered true after
# AC) is NOT legacy: BEN still has to run, so done:BEN is pending on it and
# the tail is refused W-ORDER naming BEN, exactly as completeness keeps the
# wave open (tests/cases/complete-legacy-upgrade.sh).

THROUGH_BFBTEET_NO_BEN='del(.vocabulary) | .behaviour_change = true | .ui = false | .cr_enabled = false | .phases = {
  AC:{status:"done"}, ACB:{status:"done"}, DR:{status:"done"},
  "TDE-RED":{status:"done"}, "TDE-GREEN":{status:"done"}, CR:{status:"done"},
  BC:{status:"done"}, "BF-BC":{status:"done"},
  SEA:{status:"done"}, "BF-SEA":{status:"done"},
  DS:{status:"done"}, "BF-DS":{status:"done"},
  BSEA:{status:"done"}, "BF-BSEA":{status:"done"},
  OA:{status:"done"}, "TEET-TC":{status:"done"}, TEET:{status:"done"},
  "BF-TEET":{status:"done"}, BTEET:{status:"done"}, "BTEET-X":{status:"done"},
  "BF-BTEET":{status:"done"}
}'

if drive commit-ben-not-done "$THROUGH_BFBTEET_NO_BEN" COMMIT executor sonnet; then
  expect_allow commit-ben-not-done
fi

# Legacy: a BEN-CLOSE dispatch is W-COND, and its remedy says there is nothing
# to run and why (the state has no vocabulary key).
if drive ben-close-legacy "$THROUGH_BFBTEET_NO_BEN" BEN-CLOSE lead opus; then
  expect_deny ben-close-legacy W-COND
  assert_reason_contains 'nothing to run for BEN-CLOSE' \
    || fail "ben-close-legacy: remedy must say there is nothing to run: '$(reason_of)'"
  assert_reason_contains 'no vocabulary key' \
    || fail "ben-close-legacy: remedy must name the legacy discriminator: '$(reason_of)'"
fi

# New wave, same phase map: COMMIT and BEN-CLOSE wait for BEN.
NEW_NO_BEN="$THROUGH_BFBTEET_NO_BEN | .vocabulary = false"
if drive commit-ben-not-done-new "$NEW_NO_BEN" COMMIT executor sonnet; then
  expect_deny commit-ben-not-done-new W-ORDER
  assert_reason_contains 'predecessor(s) not done: BEN;' \
    || fail "commit-ben-not-done-new: W-ORDER must name BEN: '$(reason_of)'"
  assert_reason_contains 'BEN (required because state.behaviour_change is true)' \
    || fail "commit-ben-not-done-new: missing because clause: '$(reason_of)'"
fi
if drive ben-close-ben-not-done-new "$NEW_NO_BEN" BEN-CLOSE lead opus; then
  expect_deny ben-close-ben-not-done-new W-ORDER
  assert_reason_contains 'predecessor(s) not done: BEN;' \
    || fail "ben-close-ben-not-done-new: W-ORDER must name BEN: '$(reason_of)'"
fi
# ...and BEN itself is dispatchable after AC in that wave (its only
# predecessor is UIA, skipped by vocabulary false).
if drive ben-after-ac-new "$NEW_NO_BEN" BEN lead opus; then
  expect_allow ben-after-ac-new
fi
# New wave, behaviour_change false: BEN does not run, COMMIT proceeds.
if drive commit-ben-not-done-new-bcfalse "$NEW_NO_BEN | .behaviour_change = false | .ui = false" COMMIT executor sonnet; then
  expect_allow commit-ben-not-done-new-bcfalse
fi

exit $rc
