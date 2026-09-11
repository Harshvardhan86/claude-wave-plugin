#!/usr/bin/env bash
# tests/cases/allscripts-013-closed-silent-active-fires.sh — AC-13.
#
# Two halves of one claim, both required:
#   - status:"closed" -> every one of the thirteen scripts is a silent no-op
#     on its own denyable fixture (a closed wave stops enforcing without
#     deleting state).
#   - status:"active" (the same fixtures) -> every one of the thirteen scripts
#     produces its rule, except post-bash.sh and pre-monitor.sh: their positive
#     cases land in Tasks 3–4; Task 2 asserts those two remain silent. The
#     original eleven still prove both halves, so silence alone cannot pass.
set -u

# shellcheck source=tests/lib/assert.sh
source "$(dirname "$0")/../lib/assert.sh"

name="$(basename "$0" .sh)"
log="${WV_CASE_LOG:-$WV_RUN_TMP/logs/$name.log}"
mkdir -p "$(dirname "$log")"

rc=0

if run_all_eleven closed; then
  printf 'RAN allscripts-013 closed scripts=13 decision=silent\n' >> "$log"
else
  printf 'RAN allscripts-013 closed scripts=partial decision=silent\n' >> "$log"
  printf 'ASSERT FAIL: closed leg: %s\n' "$WV_ELEVEN_FAILURES" >&2
  rc=1
fi

if run_all_eleven active; then
  printf 'RAN allscripts-013 active scripts=13 decision=fires\n' >> "$log"
else
  printf 'RAN allscripts-013 active scripts=partial decision=fires\n' >> "$log"
  printf 'ASSERT FAIL: active leg: %s\n' "$WV_ELEVEN_FAILURES" >&2
  rc=1
fi

exit $rc
