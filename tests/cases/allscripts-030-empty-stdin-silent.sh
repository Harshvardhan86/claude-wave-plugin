#!/usr/bin/env bash
# tests/cases/allscripts-030-empty-stdin-silent.sh — AC-30.
#
# An active wave, but every one of the eleven scripts is fed empty stdin (0
# bytes): each must exit 0, emit no deny/block, write nothing under PROJ.
#
# Global Constraint 4 ("jq absent -> fail open ... The same applies to
# unparseable stdin ... print exactly one line to stderr and exit 0")
# mandates lib.sh's wv_parse_stdin to print exactly one diagnostic line to
# stderr on empty stdin -- it already does, and this is deliberate (the
# constraint's own words: "a hook that could not read its input has
# measured nothing"). So AC-30's "stderr is empty" is read together with the
# qualifier immediately after it in the AC text ("no unbound-variable trace,
# no partial state write"): the operative claim this case enforces is no
# CRASH trace and no partial write, not literally zero bytes on stderr,
# which would contradict a binding Global Constraint every one of these
# eleven scripts already correctly satisfies. See run_all_eleven's own
# comment in tests/lib/assert.sh for the exact allow-listed line.
set -u

# shellcheck source=tests/lib/assert.sh
source "$(dirname "$0")/../lib/assert.sh"

name="$(basename "$0" .sh)"
log="${WV_CASE_LOG:-$WV_RUN_TMP/logs/$name.log}"
mkdir -p "$(dirname "$log")"

rc=0
if run_all_eleven empty-stdin; then
  printf 'RAN allscripts-030 empty-stdin eleven=11 decision=silent\n' >> "$log"
else
  printf 'RAN allscripts-030 empty-stdin eleven=partial decision=silent\n' >> "$log"
  printf 'ASSERT FAIL: %s\n' "$WV_ELEVEN_FAILURES" >&2
  rc=1
fi

exit $rc
