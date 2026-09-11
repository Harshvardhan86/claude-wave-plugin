#!/usr/bin/env bash
# tests/cases/stop-207-directory-block.sh — AC-207: the artifact path exists but
# is a DIRECTORY. Block(W-ARTIFACT) saying it is not a regular file, with no
# crash and nothing from grep on stderr — `command grep -E` on a directory
# prints "Is a directory" unless the type is checked first, and that line would
# both pollute the hook's channel and read as a failed scan.
set -u

# shellcheck source=tests/lib/assert.sh
source "$(dirname "$0")/../lib/assert.sh"
# shellcheck source=tests/lib/stop.sh
source "$(dirname "$0")/../lib/stop.sh"

name="${WV_CASE_NAME:-$(basename "$0" .sh)}"
log="${WV_CASE_LOG:-$WV_RUN_TMP/logs/$name.log}"
rc=0
fail() { printf 'ASSERT FAIL: %s\n' "$*" >&2; rc=1; }
printf 'RAN subagent-stop.sh %s decision=block\n' "$name" >> "$log"

# The project is made here, not by run_hook, so the directory can be planted
# before the hook runs (seed.files only ever writes regular files).
WV_PROJECT="$(mkproj)"
mkdir -p "$WV_PROJECT/.wave/ac.md" || { fail "could not plant the directory"; exit 1; }

st="$WV_RUN_TMP/$name-state.json"
c="$WV_RUN_TMP/$name.json"
stop_state "$st" ".active = {a1: $(stop_active AC reviewer opus)}" || exit 1
stop_case "$c" "$(printf '.seed.state = "%s"' "$st")" || exit 1
run_hook subagent-stop.sh "$c" || { fail "run_hook: $WV_LAST_STDERR"; exit 1; }

assert_block W-ARTIFACT || fail "want block(W-ARTIFACT)"
assert_reason_contains 'not a regular file' || fail "the reason must say the path is not a regular file"
assert_reason_contains '.wave/ac.md' || fail "the reason must name the path"
[ -z "$WV_LAST_STDERR" ] || fail "stderr must be empty, got '$WV_LAST_STDERR'"
[ "$(stop_phase_status AC)" != "done" ] || fail "AC must not be done"
[ -d "$WV_PROJECT/.wave/ac.md" ] || fail "the directory must be left alone"

exit $rc
