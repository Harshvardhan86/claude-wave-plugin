#!/usr/bin/env bash
# tests/cases/allscripts-013-closed-silent-active-fires.sh — AC-13.
#
# Two halves of one claim, both required:
#   - status:"closed" -> every one of the thirteen scripts is a silent no-op
#     on its own denyable fixture (a closed wave stops enforcing without
#     deleting state).
#   - status:"active" (the same fixtures) -> every one of the thirteen scripts
#     produces its rule or recording, including the poll-419 Monitor denial.
#     post-bash.sh now proves the bgwait-410 recording; silence alone cannot
#     satisfy its active assertion.
set -u

# shellcheck source=tests/lib/assert.sh
source "$(dirname "$0")/../lib/assert.sh"

name="$(basename "$0" .sh)"
log="${WV_CASE_LOG:-$WV_RUN_TMP/logs/$name.log}"
mkdir -p "$(dirname "$log")"

rc=0

if run_all_thirteen closed; then
  printf 'RAN allscripts-013 closed scripts=13 decision=silent\n' >> "$log"
else
  printf 'RAN allscripts-013 closed scripts=partial decision=silent\n' >> "$log"
  printf 'ASSERT FAIL: closed leg: %s\n' "$WV_THIRTEEN_FAILURES" >&2
  rc=1
fi

if run_all_thirteen active; then
  printf 'RAN allscripts-013 active scripts=13 decision=fires\n' >> "$log"
else
  printf 'RAN allscripts-013 active scripts=partial decision=fires\n' >> "$log"
  printf 'ASSERT FAIL: active leg: %s\n' "$WV_THIRTEEN_FAILURES" >&2
  rc=1
fi

exit $rc
