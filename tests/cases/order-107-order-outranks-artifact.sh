#!/usr/bin/env bash
# tests/cases/order-107-order-outranks-artifact.sh — W-ORDER (precedence 11)
# outranks W-ARTIFACT (12) and W-MARKER (13) on an input that violates both
# (fix round 1, item 4).
#
# THE DEFECT. Two sites emitted an artifact/marker deny BEFORE the order gate had
# run:
#
#   * pre-agent.sh's chain step 11 evaluates the dispatched phase's OWN
#     `condition`. A `findings:<CODE>` condition whose file is absent while <CODE>
#     is done cannot be answered, and the chain denied W-ARTIFACT there and
#     returned — the order gate at step 12 never ran.
#   * `wv_after_unmet_walk` returns 2 the moment ANY predecessor's condition
#     cannot be answered, even when it has ALREADY recorded a genuinely unmet
#     predecessor in WV_UNMET. The unmet predecessor was then never reported.
#
# Both are reachable with the shipped table: VB, COMMIT, CL and CCP all list
# `after=BTEET-X,BF-BTEET`, and BF-BTEET's condition is `findings:BTEET` — so a
# wave with BTEET done, BTEET-X not done and .wave/findings/BTEET.md absent
# violates the order AND cannot answer a condition, in one dispatch.
#
# THE FIX IS A REORDER, NOT A RELAXATION. Status 2 still cannot skip through: it is
# either the deny (when the order is satisfied) or superseded by a HIGHER-precedence
# deny that also stops the dispatch. Nothing is allowed that was refused before.
#
# Four legs, in two pairs, because "W-ORDER wins" is only meaningful beside "and
# W-ARTIFACT still fires when it is the only thing wrong" — a chain that always
# reported W-ORDER would satisfy the first two legs perfectly.
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
  # drive <label> <phase> <role> <model> <bteet-x done?> -> runs pre-agent.sh.
  #
  # BTEET is done and .wave/findings/BTEET.md is deliberately NOT seeded, so
  # BF-BTEET's `findings:BTEET` condition cannot be answered in every leg. What
  # varies is whether BTEET-X is done, i.e. whether the ORDER is also violated.
  local label="$1" phase="$2" role="$3" model="$4" xdone="$5"
  WV_PROJECT="$(mkproj)"
  local st="$WV_RUN_TMP/$name-$label-state.json" c="$WV_RUN_TMP/$name-$label.json"
  local phases='{"BTEET": {"status": "done"}}'
  [ "$xdone" = "yes" ] && phases='{"BTEET": {"status": "done"}, "BTEET-X": {"status": "done"}}'
  if ! jq --argjson p "$phases" \
      '.phases = $p | .ui = false | .behaviour_change = false | .cr_enabled = false' \
      "$WV_TESTS_DIR/fixtures/state/valid-full.json" > "$st"; then
    fail "$label: could not build the state"
    return 1
  fi
  jq -n --arg st "$st" --arg d "[W:1 P:$phase R:$role] probe" --arg m "$model" '{
    script: "pre-agent.sh",
    seed: {state: $st},
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

expect_rule() {
  local label="$1" want="$2" r n
  r="$(reason_of)"
  n="$(printf '%s' "$r" | command grep -oE 'W-[A-Z0-9-]+' | wc -l | tr -d ' ')"
  [ "$n" = "1" ] || fail "$label: the reason carries $n W- tokens: '$r'"
  case "$r" in
    "[$want] "*) printf '  %-34s -> %s\n' "$label" "$want" ;;
    *) fail "$label: want $want, got '$r'" ;;
  esac
}

# ---- pair 1: the dispatched phase's OWN condition (chain step 11) -----------
#
# BF-BTEET's condition is findings:BTEET (absent, BTEET done) and its after is
# BTEET-X.

if drive own-cond-order-unmet BF-BTEET executor sonnet no; then
  expect_rule own-cond-order-unmet W-ORDER
  case "$(reason_of)" in
    *'BTEET-X'*) : ;;
    *) fail "own-cond-order-unmet: the reason must name the unmet predecessor: '$(reason_of)'" ;;
  esac
fi

if drive own-cond-order-met BF-BTEET executor sonnet yes; then
  expect_rule own-cond-order-met W-ARTIFACT
  case "$(reason_of)" in
    *'.wave/findings/BTEET.md'*) : ;;
    *) fail "own-cond-order-met: the reason must name the missing artifact: '$(reason_of)'" ;;
  esac
fi

# ---- pair 2: a PREDECESSOR's condition, inside the order walk ---------------
#
# COMMIT lists after=BTEET-X,BF-BTEET. The walk records BTEET-X as unmet and then
# meets BF-BTEET, whose condition cannot be answered.

if drive pred-cond-order-unmet COMMIT executor sonnet no; then
  expect_rule pred-cond-order-unmet W-ORDER
  case "$(reason_of)" in
    *'BTEET-X'*) : ;;
    *) fail "pred-cond-order-unmet: the reason must name the unmet predecessor: '$(reason_of)'" ;;
  esac
fi

if drive pred-cond-order-met COMMIT executor sonnet yes; then
  expect_rule pred-cond-order-met W-ARTIFACT
  case "$(reason_of)" in
    *'.wave/findings/BTEET.md'*) : ;;
    *) fail "pred-cond-order-met: the reason must name the missing artifact: '$(reason_of)'" ;;
  esac
fi

exit $rc
