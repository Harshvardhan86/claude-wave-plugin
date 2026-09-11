#!/usr/bin/env bash
# tests/cases/init-357-solo-mode.sh — AC-357.
#
# --solo sets mode:"solo" and status:"active"; no --mode is required alongside it.
set -u

# shellcheck source=tests/lib/assert.sh
source "$(dirname "$0")/../lib/assert.sh"

name="$(basename "$0" .sh)"
log="${WV_CASE_LOG:-$WV_RUN_TMP/logs/$name.log}"
mkdir -p "$(dirname "$log")"

rc=0
fail() { printf 'ASSERT FAIL: %s\n' "$*" >&2; rc=1; }

WV_PROJECT="$(mkproj)"
: > "$WV_PROJECT/README.md"
git -C "$WV_PROJECT" add README.md
git -C "$WV_PROJECT" commit -q -m init

run_cli scripts/wave-init.sh --solo --feature x --wave 1
[ "$CLI_EXIT" = "0" ] || fail "exit: want 0, got $CLI_EXIT (stderr: $CLI_STDERR)"

assert_state '.mode == "solo"' || rc=1
assert_state '.status == "active"' || rc=1

exit $rc
