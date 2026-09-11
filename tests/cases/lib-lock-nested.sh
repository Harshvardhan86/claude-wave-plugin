#!/usr/bin/env bash
# tests/cases/lib-lock-nested.sh — a nested acquire must not release the outer
# lock.
#
# `wv_lock_acquire` opens the lock on a fixed descriptor, so a second acquire
# inside the first replaces that descriptor and the kernel drops the lock the
# first one held; the matching nested release then leaves the process holding
# nothing while its caller still believes the state file is protected. The
# library already calls the lock twice within one emitter path, so this is a
# real shape, not a hypothetical one.
#
# Proved from the outside, by exclusion: a separate process (with the inherited
# descriptor closed, so it cannot borrow the driver's handle) must be refused
# while the outer holder is between its nested release and its own release, and
# must succeed once the outer release has happened. The second half is the
# control — without it, "excluded" could just mean the competitor never worked.
set -u

# shellcheck source=tests/lib/assert.sh
source "$(dirname "$0")/../lib/assert.sh"

name="$(basename "$0" .sh)"
rc=0
fail() { printf 'ASSERT FAIL: %s\n' "$*" >&2; rc=1; }

case_file="$WV_RUN_TMP/$name.json"
jq -n '{
  script: "tests/fixtures/drive-lib.sh",
  env: { WV_DRIVE: "nested-lock" },
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

WV_PROJECT=""
if ! run_hook tests/fixtures/drive-lib.sh "$case_file"; then
  printf 'run_hook could not run the driver: %s\n' "$WV_LAST_STDERR" >&2
  exit 1
fi
assert_exit 0 || rc=1
printf 'lock nesting probe:\n%s\n' "$WV_LAST_STDOUT"

want_line() {
  local wanted="$1"
  case "$WV_LAST_STDOUT" in
    *"$wanted"*) return 0 ;;
    *) fail "the probe did not report '$wanted'" ;;
  esac
}

want_line 'outer=held depth=1'
want_line 'nested=held depth=2'
want_line 'nested-released depth=1'
want_line 'competitor-while-outer-held=excluded'
want_line 'outer-released depth=0'
want_line 'competitor-after-release=acquired'

exit $rc
