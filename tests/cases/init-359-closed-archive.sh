#!/usr/bin/env bash
# tests/cases/init-359-closed-archive.sh — AC-359.
#
# An existing state.json whose status is "closed": wave-init.sh moves it to
# .wave/archive/<its started>-state.json (no --force required) and writes a
# fresh state.json for the new wave.
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
started1="$(jq -r '.started' "$WV_PROJECT/.wave/state.json")"

run_cli scripts/wave-close.sh
[ "$CLI_EXIT" = "0" ] || fail "wave-close.sh: exit $CLI_EXIT, stderr: $CLI_STDERR"
assert_state '.status == "closed"' || rc=1

run_cli scripts/wave-init.sh --wave 2 --mode full --feature y
[ "$CLI_EXIT" = "0" ] || fail "second init over a closed wave: want exit 0, got $CLI_EXIT (stderr: $CLI_STDERR)"

assert_state '.wave == "2"' || rc=1
assert_state '.status == "active"' || rc=1

archived="$WV_PROJECT/.wave/archive/${started1}-state.json"
[ -f "$archived" ] || fail "expected archive file $archived not found"
if [ -f "$archived" ]; then
  [ "$(jq -r '.wave' "$archived")" = "1" ] || fail "$archived does not hold wave 1's state"
  [ "$(jq -r '.status' "$archived")" = "closed" ] || fail "$archived status is not 'closed'"
fi

exit $rc
