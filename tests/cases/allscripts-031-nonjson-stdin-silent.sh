#!/usr/bin/env bash
# tests/cases/allscripts-031-nonjson-stdin-silent.sh — AC-31.
#
# Identical assertions to AC-30 (allscripts-030-empty-stdin-silent.sh) --
# including the same reading of "stderr is empty" against Global Constraint
# 4's mandated one-line fail-open diagnostic; see that case's header -- but
# the eleven scripts are fed the literal bytes "not json at all" instead of
# an empty payload. lib.sh's wv_parse_stdin fails open on unparseable input
# the same way it does on empty input, with its own distinct one-line
# diagnostic.
set -u

# shellcheck source=tests/lib/assert.sh
source "$(dirname "$0")/../lib/assert.sh"

name="$(basename "$0" .sh)"
log="${WV_CASE_LOG:-$WV_RUN_TMP/logs/$name.log}"
mkdir -p "$(dirname "$log")"

rc=0
if run_all_eleven nonjson-stdin; then
  printf 'RAN allscripts-031 nonjson-stdin eleven=11 decision=silent\n' >> "$log"
else
  printf 'RAN allscripts-031 nonjson-stdin eleven=partial decision=silent\n' >> "$log"
  printf 'ASSERT FAIL: %s\n' "$WV_ELEVEN_FAILURES" >&2
  rc=1
fi

exit $rc
