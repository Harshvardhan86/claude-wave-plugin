#!/usr/bin/env bash
# tests/cases/init-364b-stdout-contract.sh — --if-complete writes nothing to stdout.
#
# subagent-stop.sh calls `wave-close.sh --if-complete` (the --if-terminal
# alias is the same contract) from inside a hook whose stdout must carry
# exactly one JSON object (or none from this call). Under --if-complete and
# under --if-terminal, wave-close.sh must write NOTHING to stdout — on a
# no-op or on an actual close alike. The bare form is the negative control:
# it must still print its human line on stdout.
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

# --if-complete, incomplete wave: no-op, stdout must be empty.
run_cli scripts/wave-close.sh --if-complete
[ "$CLI_EXIT" = "0" ] || fail "--if-complete (no-op): want exit 0, got $CLI_EXIT (stderr: $CLI_STDERR)"
[ -z "$CLI_STDOUT" ] || fail "--if-complete (no-op) wrote to stdout: '$CLI_STDOUT'"

# --if-terminal alias, incomplete: still empty stdout.
run_cli scripts/wave-close.sh --if-terminal AC
[ "$CLI_EXIT" = "0" ] || fail "--if-terminal AC (no-op): want exit 0, got $CLI_EXIT (stderr: $CLI_STDERR)"
[ -z "$CLI_STDOUT" ] || fail "--if-terminal AC (no-op) wrote to stdout: '$CLI_STDOUT'"

# Actual close under --if-complete: stdout must STILL be empty.
cp "$WV_TESTS_DIR/fixtures/state/full-all-done.json" "$WV_PROJECT/.wave/state.json"
run_cli scripts/wave-close.sh --if-complete
[ "$CLI_EXIT" = "0" ] || fail "--if-complete (actual close): want exit 0, got $CLI_EXIT (stderr: $CLI_STDERR)"
[ -z "$CLI_STDOUT" ] || fail "--if-complete (actual close) wrote to stdout: '$CLI_STDOUT'"
assert_state '.status == "closed"' || rc=1

# Alias on a complete wave, same stdout contract.
run_cli scripts/wave-init.sh --wave 3 --mode full --feature z --force
cp "$WV_TESTS_DIR/fixtures/state/full-all-done.json" "$WV_PROJECT/.wave/state.json"
run_cli scripts/wave-close.sh --if-terminal CCP
[ "$CLI_EXIT" = "0" ] || fail "--if-terminal CCP (actual close): want exit 0, got $CLI_EXIT"
[ -z "$CLI_STDOUT" ] || fail "--if-terminal alias (actual close) wrote to stdout: '$CLI_STDOUT'"
assert_state '.status == "closed"' || rc=1

# Negative control: the bare form still prints its human line on stdout.
run_cli scripts/wave-init.sh --wave 2 --mode full --feature y --force
[ "$CLI_EXIT" = "0" ] || fail "second init: exit $CLI_EXIT, stderr: $CLI_STDERR"

run_cli scripts/wave-close.sh
[ "$CLI_EXIT" = "0" ] || fail "bare close: want exit 0, got $CLI_EXIT (stderr: $CLI_STDERR)"
[ -n "$CLI_STDOUT" ] || fail "bare wave-close.sh must still print its human line on stdout, got nothing"
case "$CLI_STDOUT" in
  *"wave 2 closed"*) : ;;
  *) fail "bare wave-close.sh stdout does not name the closed wave: '$CLI_STDOUT'" ;;
esac

exit $rc
