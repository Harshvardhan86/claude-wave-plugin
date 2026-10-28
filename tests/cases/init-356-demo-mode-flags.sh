#!/usr/bin/env bash
# tests/cases/init-356-demo-mode-flags.sh — AC-356.
#
# --mode demo --cr --no-ui --no-behaviour-change --enforce warn sets
# mode:"demo", cr_enabled:true, ui:false, behaviour_change:false,
# enforce:"warn" directly at init time. vocabulary is omitted so it stays
# the JSON string "unknown" (the same default as an unanswered flag).
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

run_cli scripts/wave-init.sh --wave 1 --mode demo --cr --no-ui --no-behaviour-change --enforce warn --feature x
[ "$CLI_EXIT" = "0" ] || fail "exit: want 0, got $CLI_EXIT (stderr: $CLI_STDERR)"

assert_state '.mode == "demo"' || rc=1
assert_state '.cr_enabled == true' || rc=1
assert_state '.ui == false' || rc=1
assert_state '.enforce == "warn"' || rc=1
assert_state '.behaviour_change == false' || rc=1
assert_state '.vocabulary == "unknown"' || rc=1

exit $rc
