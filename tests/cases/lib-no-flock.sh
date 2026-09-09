#!/usr/bin/env bash
# tests/cases/lib-no-flock.sh — AC-33.
#
# An active wave and `flock` absent from PATH (jq present, so the guard has to
# name the right tool): exit 0, no block, one stderr line naming flock, and
# `state.json` unmodified. State without a lock is state we cannot write
# safely, so the whole call fails open rather than writing unlocked.
set -u

# shellcheck source=tests/lib/assert.sh
source "$(dirname "$0")/../lib/assert.sh"

name="$(basename "$0" .sh)"
shim="$WV_RUN_TMP/shim-no-flock"
rm -rf "$shim"
mkdir -p "$shim"
ln -s "$(command -v jq)" "$shim/jq"     # jq present, flock absent
ln -s "$(command -v bash)" "$shim/bash"   # run_hook resolves bash through this PATH

case_file="$WV_RUN_TMP/$name.json"
jq -n --arg path "$shim" '{
  script: "lib.sh",
  env: { PATH: $path, WV_DRIVE: "block:W-ARTIFACT" },
  seed: { state: "state/valid-full.json" },
  stdin: {
    hook_event_name: "SubagentStop",
    agent_id: "abe831e9837f3dcee",
    agent_type: "general-purpose",
    agent_transcript_path: "/nonexistent/subagents/abe831e9837f3dcee.jsonl",
    last_assistant_message: "done",
    stop_hook_active: false,
    cwd: "."
  }
}' > "$case_file"

rc=0
fail() { printf 'ASSERT FAIL: %s\n' "$*" >&2; rc=1; }

WV_PROJECT=""
if ! run_hook lib.sh "$case_file"; then
  printf 'run_hook could not run the library: %s\n' "$WV_LAST_STDERR" >&2
  exit 1
fi
before="$(cat "$WV_PROJECT/.wave/state.json")"

assert_exit 0 || rc=1
[ -z "$WV_LAST_STDOUT" ] || fail "stdout must be empty with flock absent, got: '$WV_LAST_STDOUT'"

lines="$(printf '%s\n' "$WV_LAST_STDERR" | command grep -c .)"
[ "$lines" = "1" ] || fail "want exactly 1 stderr line, got $lines: '$WV_LAST_STDERR'"
case "$WV_LAST_STDERR" in
  *flock*) : ;;
  *) fail "the stderr line does not name flock: '$WV_LAST_STDERR'" ;;
esac
case "$WV_LAST_STDERR" in
  *"enforcement is disabled for this call"*) : ;;
  *) fail "the stderr line does not say enforcement is off for this call: '$WV_LAST_STDERR'" ;;
esac
[ "$before" = "$(cat "$WV_TESTS_DIR/fixtures/state/valid-full.json")" ] || \
  fail "state.json was modified while flock was unavailable"

exit $rc
