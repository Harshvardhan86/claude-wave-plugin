#!/usr/bin/env bash
# tests/cases/lib-state-symlink.sh — AC-28.
#
# `.wave/` is a real directory but `state.json` inside it is a symlink whose
# target is outside the project. The library must refuse it: exit 0, no write
# to the target, a rendered `W-STATE` naming the refusal. A JSON case cannot
# create a symlink, hence a `.sh` case.
set -u

# shellcheck source=tests/lib/assert.sh
source "$(dirname "$0")/../lib/assert.sh"

name="$(basename "$0" .sh)"

mkcase() {
  local case_file="$WV_RUN_TMP/$name.json"
  jq -n '{
    script: "tests/fixtures/drive-lib.sh",
    env: { WV_DRIVE: "update:.rounds.n = 99" },
    stdin: {
      hook_event_name: "PostToolUse",
      tool_name: "Agent",
      cwd: ".",
      tool_input: {
        description: "probe dispatch",
        prompt: "Do the thing.",
        subagent_type: "general-purpose",
        model: "sonnet"
      },
      tool_use_id: "toolu_016jDXUebmA9qCw58g1rxGuH",
      tool_response: "{\"status\":\"completed\",\"agentId\":\"abe831e9837f3dcee\",\"resolvedModel\":\"claude-haiku-4-5-20251001\"}"
    }
  }' > "$case_file"
  printf '%s' "$case_file"
}

rc=0
fail() { printf 'ASSERT FAIL: %s\n' "$*" >&2; rc=1; }

outside="$WV_RUN_TMP/elsewhere-state.json"
cp "$WV_TESTS_DIR/fixtures/state/valid-full.json" "$outside"
before="$(cat "$outside")"

WV_PROJECT="$(mkproj)"
mkdir -p "$WV_PROJECT/.wave"
: > "$WV_PROJECT/.wave/lock"
ln -s "$outside" "$WV_PROJECT/.wave/state.json"

if ! run_hook tests/fixtures/drive-lib.sh "$(mkcase)"; then
  printf 'run_hook could not run the library: %s\n' "$WV_LAST_STDERR" >&2
  exit 1
fi

assert_exit 0 || rc=1
assert_allow || rc=1

ctx="$(printf '%s' "$WV_LAST_STDOUT" | jq -r '.hookSpecificOutput.additionalContext // ""')"
case "$ctx" in
  "[W-STATE] "*) : ;;
  *) fail "outside state.json: additionalContext does not carry a rendered W-STATE: '$ctx'" ;;
esac
case "$ctx" in
  *"$outside"*) : ;;
  *) fail "outside state.json: the W-STATE warning does not name the resolved target: '$ctx'" ;;
esac
[ "$(cat "$outside")" = "$before" ] || fail "the state file outside the project was written through the symlink"

exit $rc
