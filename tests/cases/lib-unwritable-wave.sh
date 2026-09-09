#!/usr/bin/env bash
# tests/cases/lib-unwritable-wave.sh — AC-29 at the library level.
#
# AC-29 is written against pre-compact.sh (Task 9): an active wave whose
# `.wave` directory is mode 0555 must still exit 0, write nothing, and report
# a rendered `W-STATE` naming the unwritable directory. Everything in that
# criterion that belongs to this task lives in `wv_state_update`: the
# read-modify-write must fail *open*, never non-zero, and never half-written.
#
# The case carries its own positive control — the same update against a
# writable `.wave` must actually land — so a `wv_state_update` that never
# writes anything cannot pass the unwritable half vacuously.
set -u

# shellcheck source=tests/lib/assert.sh
source "$(dirname "$0")/../lib/assert.sh"

name="$(basename "$0" .sh)"

mkcase() {
  # mkcase <jq-filter> -> path of a JSON case file named after this case.
  local filter="$1" case_file="$WV_RUN_TMP/$name.json"
  jq -n --arg d "update:$filter" '{
    script: "tests/fixtures/drive-lib.sh",
    env: { WV_DRIVE: $d },
    seed: { state: "state/valid-full.json" },
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

# --- positive control: a writable .wave records the update ---------------
WV_PROJECT=""
if ! run_hook tests/fixtures/drive-lib.sh "$(mkcase '.rounds.n = 1')"; then
  printf 'run_hook could not run the library: %s\n' "$WV_LAST_STDERR" >&2
  exit 1
fi
assert_exit 0 || rc=1
assert_allow || rc=1
assert_state '.rounds.n == 1' || rc=1

# --- AC-29: the same update against a 0555 .wave -------------------------
chmod 0555 "$WV_PROJECT/.wave" || { echo "chmod failed" >&2; exit 1; }

run_hook tests/fixtures/drive-lib.sh "$(mkcase '.rounds.n = 2')"
run_rc=$?

chmod 0755 "$WV_PROJECT/.wave"   # restore before asserting, so cleanup works

[ "$run_rc" = "0" ] || { printf 'run_hook could not run the library: %s\n' "$WV_LAST_STDERR" >&2; exit 1; }

assert_exit 0 || rc=1
assert_allow || rc=1
# run_hook re-seeds state.json before each run (a `cp` onto the existing file
# succeeds even in a 0555 directory), so the assertion is that THIS run wrote
# nothing at all — .rounds is still the fixture's empty object.
assert_state '.rounds == {}' || rc=1

ctx="$(printf '%s' "$WV_LAST_STDOUT" | jq -r '.hookSpecificOutput.additionalContext // ""')"
case "$ctx" in
  "[W-STATE] "*) : ;;
  *) fail "unwritable .wave: additionalContext does not carry a rendered W-STATE: '$ctx'" ;;
esac
case "$ctx" in
  *"$WV_PROJECT/.wave"*) : ;;
  *) fail "unwritable .wave: the W-STATE warning does not name the directory: '$ctx'" ;;
esac

# nothing half-written left behind
leftovers="$(ls -A "$WV_PROJECT/.wave" | command grep -c '^\.state\.' )"
[ "$leftovers" = "0" ] || fail "wv_state_update left $leftovers temp file(s) in .wave"

exit $rc
