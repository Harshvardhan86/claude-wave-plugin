#!/usr/bin/env bash
# tests/cases/init-363-wave-close.sh — AC-363 (the wave-close.sh half; the
# eleven-script silent-no-op half of this AC is exercised once those scripts
# exist, per tests/cases/README.md's per-script conventions in later tasks).
#
# wave-close.sh sets status:"closed" and ended in one write.
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

run_cli scripts/wave-init.sh --wave 1 --mode full --feature x
[ "$CLI_EXIT" = "0" ] || fail "setup init: exit $CLI_EXIT, stderr: $CLI_STDERR"
assert_state '.status == "active"' || rc=1
assert_state '.ended == null' || rc=1

run_cli scripts/wave-close.sh
[ "$CLI_EXIT" = "0" ] || fail "wave-close.sh: exit $CLI_EXIT, stderr: $CLI_STDERR"

assert_state '.status == "closed"' || rc=1
assert_state '.ended != null' || rc=1
assert_state '.ended | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")' || rc=1

exit $rc
