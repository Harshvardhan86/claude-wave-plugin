#!/usr/bin/env bash
# tests/cases/allscripts-012-leftover-dir-silent.sh — AC-12.
#
# PROJ/.wave/ exists but holds no state.json (a leftover runtime dir, e.g.
# from a wave that was deleted by hand rather than closed): every one of the
# eleven wired scripts is a silent no-op on its own denyable fixture, and the
# harness proves eleven executions actually happened.
set -u

# shellcheck source=tests/lib/assert.sh
source "$(dirname "$0")/../lib/assert.sh"

name="$(basename "$0" .sh)"
log="${WV_CASE_LOG:-$WV_RUN_TMP/logs/$name.log}"
mkdir -p "$(dirname "$log")"

rc=0
if run_all_eleven leftover-wave-dir; then
  printf 'RAN allscripts-012 leftover-wave-dir eleven=11 decision=silent\n' >> "$log"
else
  printf 'RAN allscripts-012 leftover-wave-dir eleven=partial decision=silent\n' >> "$log"
  printf 'ASSERT FAIL: %s\n' "$WV_ELEVEN_FAILURES" >&2
  rc=1
fi

exit $rc
