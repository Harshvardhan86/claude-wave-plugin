#!/usr/bin/env bash
# tests/cases/lib-no-jq.sh — AC-32.
#
# An active wave, a denyable fixture, and `jq` absent from PATH: exit 0, stdout
# empty, and exactly one stderr line naming jq and saying enforcement is off
# for this call. A JSON case cannot express it — PATH has to point at a shim
# directory whose absolute path is only known at run time (jq and flock both
# live in /usr/bin on the reference box, so no static PATH excludes one of
# them while keeping the other).
set -u

# shellcheck source=tests/lib/assert.sh
source "$(dirname "$0")/../lib/assert.sh"

name="$(basename "$0" .sh)"
shim="$WV_RUN_TMP/shim-no-jq"
rm -rf "$shim"
mkdir -p "$shim"
ln -s "$(command -v bash)" "$shim/bash"   # run_hook resolves bash through this PATH
# nothing else: no jq, no flock, no coreutils at all

case_file="$WV_RUN_TMP/$name.json"
jq -n --arg path "$shim" '{
  script: "lib.sh",
  env: { PATH: $path, WV_DRIVE: "deny:W-TAG" },
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

rc=0
fail() { printf 'ASSERT FAIL: %s\n' "$*" >&2; rc=1; }

WV_PROJECT=""
if ! run_hook lib.sh "$case_file"; then
  printf 'run_hook could not run the library: %s\n' "$WV_LAST_STDERR" >&2
  exit 1
fi

assert_exit 0 || rc=1
[ -z "$WV_LAST_STDOUT" ] || fail "stdout must be empty with jq absent, got: '$WV_LAST_STDOUT'"

lines="$(printf '%s\n' "$WV_LAST_STDERR" | command grep -c .)"
[ "$lines" = "1" ] || fail "want exactly 1 stderr line, got $lines: '$WV_LAST_STDERR'"
case "$WV_LAST_STDERR" in
  *jq*) : ;;
  *) fail "the stderr line does not name jq: '$WV_LAST_STDERR'" ;;
esac
case "$WV_LAST_STDERR" in
  *"enforcement is disabled for this call"*) : ;;
  *) fail "the stderr line does not say enforcement is off for this call: '$WV_LAST_STDERR'" ;;
esac

exit $rc
