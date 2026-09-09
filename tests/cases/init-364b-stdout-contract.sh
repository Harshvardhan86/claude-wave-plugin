#!/usr/bin/env bash
# tests/cases/init-364b-stdout-contract.sh — fix round 1, review finding 1.
#
# Task 8's subagent-stop.sh will call `wave-close.sh --if-terminal <PHASE>`
# from inside a hook whose stdout must carry exactly one JSON object (or
# none from this call); a stray human-readable line would corrupt that
# channel. Under --if-terminal, wave-close.sh must write NOTHING to stdout
# — on a no-op (non-terminal phase) or on an actual close alike. The bare
# (no-argument) form is the negative control: it must still print its
# human line on stdout, because nothing but a person runs it directly.
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

# --if-terminal, non-matching phase: no-op, stdout must be empty.
run_cli scripts/wave-close.sh --if-terminal AC
[ "$CLI_EXIT" = "0" ] || fail "--if-terminal AC: want exit 0, got $CLI_EXIT (stderr: $CLI_STDERR)"
[ -z "$CLI_STDOUT" ] || fail "--if-terminal AC (no-op) wrote to stdout: '$CLI_STDOUT'"

# --if-terminal, matching phase: closes, but stdout must STILL be empty.
run_cli scripts/wave-close.sh --if-terminal AD
[ "$CLI_EXIT" = "0" ] || fail "--if-terminal AD: want exit 0, got $CLI_EXIT (stderr: $CLI_STDERR)"
[ -z "$CLI_STDOUT" ] || fail "--if-terminal AD (actual close) wrote to stdout: '$CLI_STDOUT'"
assert_state '.status == "closed"' || rc=1

# Negative control: the bare form still prints its human line on stdout.
run_cli scripts/wave-init.sh --wave 2 --mode full --feature y
[ "$CLI_EXIT" = "0" ] || fail "second init: exit $CLI_EXIT, stderr: $CLI_STDERR"

run_cli scripts/wave-close.sh
[ "$CLI_EXIT" = "0" ] || fail "bare close: want exit 0, got $CLI_EXIT (stderr: $CLI_STDERR)"
[ -n "$CLI_STDOUT" ] || fail "bare wave-close.sh must still print its human line on stdout, got nothing"
case "$CLI_STDOUT" in
  *"wave 2 closed"*) : ;;
  *) fail "bare wave-close.sh stdout does not name the closed wave: '$CLI_STDOUT'" ;;
esac

exit $rc
