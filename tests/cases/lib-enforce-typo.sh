#!/usr/bin/env bash
# tests/cases/lib-enforce-typo.sh — AC-19, with AC-20's mirror as its control.
#
# AC-19: an unrecognised `enforce` value falls back to `block` (so the deny
# still fires — a typo must never silently switch the layer off) *and* is
# reported as a `W-STATE` warning riding on the same JSON object's
# `additionalContext` (Global Constraint 5 allows exactly one object on
# stdout, so the warning cannot be a second object).
# AC-20's half of the pair — a *missing* `enforce` key is the documented
# default and is NOT reported — is asserted here too, because the JSON case
# schema can assert the deny but not the absence of a second rule id in the
# additionalContext channel.
set -u

# shellcheck source=tests/lib/assert.sh
source "$(dirname "$0")/../lib/assert.sh"

name="$(basename "$0" .sh)"

mkcase() {
  # mkcase <state-fixture> -> path of a JSON case file named after this case,
  # so run_hook's positive run marker lands in the log tests/run.sh checks.
  local fixture="$1" case_file="$WV_RUN_TMP/$name.json"
  jq -n --arg f "$fixture" '{
    script: "lib.sh",
    env: { WV_DRIVE: "deny:W-TAG" },
    seed: { state: $f },
    stdin: {
      hook_event_name: "PreToolUse",
      tool_name: "Agent",
      cwd: ".",
      tool_input: {
        description: "probe dispatch",
        prompt: "Do the thing.",
        subagent_type: "general-purpose",
        model: "sonnet"
      },
      tool_use_id: "toolu_016jDXUebmA9qCw58g1rxGuH"
    }
  }' > "$case_file"
  printf '%s' "$case_file"
}

rc=0
fail() { printf 'ASSERT FAIL: %s\n' "$*" >&2; rc=1; }

# --- AC-19: enforce:"nonsense" ------------------------------------------
WV_PROJECT=""
if ! run_hook lib.sh "$(mkcase state/enforce-typo.json)"; then
  printf 'run_hook could not run the library: %s\n' "$WV_LAST_STDERR" >&2
  exit 1
fi
assert_exit 0 || rc=1
assert_deny W-TAG || rc=1

ctx="$(printf '%s' "$WV_LAST_STDOUT" | jq -r '.hookSpecificOutput.additionalContext // ""')"
case "$ctx" in
  "[W-STATE] "*) : ;;
  *) fail "enforce typo: additionalContext does not carry a rendered W-STATE: '$ctx'" ;;
esac
case "$ctx" in
  *nonsense*) : ;;
  *) fail "enforce typo: the W-STATE warning does not name the unrecognised value: '$ctx'" ;;
esac

# --- AC-20's mirror: no enforce key at all ------------------------------
WV_PROJECT=""
if ! run_hook lib.sh "$(mkcase state/no-enforce.json)"; then
  printf 'run_hook could not run the library: %s\n' "$WV_LAST_STDERR" >&2
  exit 1
fi
assert_exit 0 || rc=1
assert_deny W-TAG || rc=1
case "$WV_LAST_STDOUT" in
  *W-STATE*) fail "a missing enforce key must not be reported: '$WV_LAST_STDOUT'" ;;
esac

exit $rc
