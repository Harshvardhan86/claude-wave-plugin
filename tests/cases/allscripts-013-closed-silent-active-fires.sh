#!/usr/bin/env bash
# tests/cases/allscripts-013-closed-silent-active-fires.sh — AC-13.
#
# Two halves of one claim, both required:
#   - status:"closed" -> every one of the eleven scripts is a silent no-op
#     on its own denyable fixture (a closed wave stops enforcing without
#     deleting state).
#   - status:"active" (the same fixtures) -> every one of the eleven scripts
#     actually produces its rule. Without this half, the "closed" half would
#     pass just as well against eleven scripts that always do nothing.
set -u

# shellcheck source=tests/lib/assert.sh
source "$(dirname "$0")/../lib/assert.sh"

name="$(basename "$0" .sh)"
log="${WV_CASE_LOG:-$WV_RUN_TMP/logs/$name.log}"
mkdir -p "$(dirname "$log")"

rc=0

if run_all_eleven closed; then
  printf 'RAN allscripts-013 closed eleven=11 decision=silent\n' >> "$log"
else
  printf 'RAN allscripts-013 closed eleven=partial decision=silent\n' >> "$log"
  printf 'ASSERT FAIL: closed leg: %s\n' "$WV_ELEVEN_FAILURES" >&2
  rc=1
fi

if run_all_eleven active; then
  printf 'RAN allscripts-013 active eleven=11 decision=fires\n' >> "$log"
else
  printf 'RAN allscripts-013 active eleven=partial decision=fires\n' >> "$log"
  printf 'ASSERT FAIL: active leg: %s\n' "$WV_ELEVEN_FAILURES" >&2
  rc=1
fi

exit $rc
