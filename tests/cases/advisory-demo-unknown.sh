#!/usr/bin/env bash
# tests/cases/advisory-demo-unknown.sh — design 3.2, demo freeze.
#
# Every flag unknown, nothing done, demo mode: the advisory names AC and
# the gate allows a P:AC dispatch. UIA and BEN are full-only, so they are
# skipped by mode without their flags being read.
set -u

# shellcheck source=tests/lib/assert.sh
source "$(dirname "$0")/../lib/assert.sh"

name="${WV_CASE_NAME:-$(basename "$0" .sh)}"
log="${WV_CASE_LOG:-$WV_RUN_TMP/logs/$name.log}"
rc=0
fail() { printf 'ASSERT FAIL: %s\n' "$*" >&2; rc=1; }
printf 'RAN pre-agent.sh %s decision=multi\n' "$name" >> "$log"

ST="$WV_TESTS_DIR/fixtures/state/p2-demo-unknown.json"

gate="$WV_RUN_TMP/$name-gate.json"
jq -n --arg st "$ST" '{
  script: "pre-agent.sh",
  seed: {state: $st},
  stdin: {
    session_id: "1a2b0599-4617-4e73-a9c0-2bef462b2626",
    cwd: ".",
    hook_event_name: "PreToolUse",
    tool_name: "Agent",
    tool_input: {
      description: "[W:1 P:AC R:lead] write the ACs",
      subagent_type: "general-purpose",
      model: "opus"
    }
  },
  expect: {}
}' > "$gate" || { fail "could not build the gate case"; exit 1; }

WV_PROJECT="$(mkproj)"
run_hook pre-agent.sh "$gate" || fail "gate run_hook: $WV_LAST_STDERR"
assert_allow || fail "demo gate: want silent allow for P:AC, got '$WV_LAST_STDOUT'"
assert_stdout_absent W-SCOPE || fail "demo gate: W-SCOPE leaked"
assert_stdout_absent W-ORDER || fail "demo gate: W-ORDER leaked"

adv="$WV_RUN_TMP/$name-adv.json"
jq -n --arg st "$ST" '{
  script: "user-prompt.sh",
  seed: {state: $st},
  stdin: {hook_event_name: "UserPromptSubmit", prompt: "continue"}
}' > "$adv" || { fail "could not build the advisory case"; exit 1; }

WV_PROJECT="$(mkproj)"
run_hook user-prompt.sh "$adv" || fail "advisory run_hook: $WV_LAST_STDERR"
assert_warn W-REMINDER || fail "demo advisory: want W-REMINDER, got '$( _wv_reason_text )'"
assert_reason_contains "phase none → AC" \
  || fail "demo advisory: expected 'phase none → AC', got '$( _wv_reason_text )'"

reason="$(_wv_reason_text)"
if [ "${#reason}" -gt 400 ]; then
  fail "demo advisory: reason is ${#reason} characters (bound is 400)"
fi

exit "$rc"
