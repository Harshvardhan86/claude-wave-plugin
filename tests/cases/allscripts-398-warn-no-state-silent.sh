#!/usr/bin/env bash
# tests/cases/allscripts-398-warn-no-state-silent.sh — AC-398.
#
# "enforce: warn" and no state.json: silent no-op for all eleven -- warn
# mode is an escape hatch INSIDE a wave, never a reason to emit anything
# outside one. There is no channel to signal an "enforce: warn" intent
# without a state.json file at all (every script's enforce value is read
# exclusively from state.json by wv_state_read; there is no environment
# variable or ambient default it consults instead), so the case that
# actually exercises this claim is "no .wave/ directory at all" -- distinct
# from AC-12's "leftover .wave/ dir with no state.json inside", covered by
# allscripts-012-leftover-dir-silent.sh, so both no-state shapes are swept.
set -u

# shellcheck source=tests/lib/assert.sh
source "$(dirname "$0")/../lib/assert.sh"

name="$(basename "$0" .sh)"
log="${WV_CASE_LOG:-$WV_RUN_TMP/logs/$name.log}"
mkdir -p "$(dirname "$log")"

rc=0
if run_all_eleven no-wave-dir; then
  printf 'RAN allscripts-398 no-wave-dir eleven=11 decision=silent\n' >> "$log"
else
  printf 'RAN allscripts-398 no-wave-dir eleven=partial decision=silent\n' >> "$log"
  printf 'ASSERT FAIL: %s\n' "$WV_ELEVEN_FAILURES" >&2
  rc=1
fi

exit $rc
