#!/usr/bin/env bash
# tests/cases/init-362b-scope-reject.sh — AC-362, the negative half.
#
# An unknown key, or a non-boolean value: wave-set.sh exits non-zero and the
# state is left byte-identical (no write attempted at all).
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

state_file="$WV_PROJECT/.wave/state.json"
before="$(cat "$state_file")"

run_cli scripts/wave-set.sh bogus-key true
[ "$CLI_EXIT" != "0" ] || fail "an unknown key must exit non-zero"

run_cli scripts/wave-set.sh ui maybe
[ "$CLI_EXIT" != "0" ] || fail "a non-boolean value must exit non-zero"

after="$(cat "$state_file")"
[ "$before" = "$after" ] || fail "state.json changed after rejected wave-set.sh calls"

exit $rc
