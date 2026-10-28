#!/usr/bin/env bash
# tests/cases/init-364-terminal-close.sh — AC-364, re-anchored on wave complete.
#
# `wave-close.sh --if-complete` closes only when every when=phase row of the
# active mode is settled. `--if-terminal <PHASE>` is an accepted alias with
# the same meaning; its argument is ignored. An incomplete wave is a silent
# no-op under either form. Solo never auto-closes.
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

# ---- incomplete full wave: both forms are no-ops --------------------------
run_cli scripts/wave-init.sh --wave 1 --mode full --feature x --no-vocabulary --no-behaviour-change --no-ui --no-cr
[ "$CLI_EXIT" = "0" ] || fail "setup init (full): exit $CLI_EXIT, stderr: $CLI_STDERR"

run_cli scripts/wave-close.sh --if-complete
[ "$CLI_EXIT" = "0" ] || fail "--if-complete (incomplete full): want exit 0, got $CLI_EXIT (stderr: $CLI_STDERR)"
assert_state '.status == "active"' || fail "incomplete full wave must stay active under --if-complete"

run_cli scripts/wave-close.sh --if-terminal AC
[ "$CLI_EXIT" = "0" ] || fail "--if-terminal AC (incomplete full): want exit 0, got $CLI_EXIT"
assert_state '.status == "active"' || fail "alias on an incomplete wave must still be a no-op"

run_cli scripts/wave-close.sh --if-terminal AD
[ "$CLI_EXIT" = "0" ] || fail "--if-terminal AD (incomplete full): want exit 0, got $CLI_EXIT"
assert_state '.status == "active"' || fail "AD is anytime and must not close an incomplete wave"

# ---- complete full wave: --if-complete closes; alias argument ignored -----
cp "$WV_TESTS_DIR/fixtures/state/full-all-done.json" "$WV_PROJECT/.wave/state.json"
run_cli scripts/wave-close.sh --if-terminal AC
[ "$CLI_EXIT" = "0" ] || fail "--if-terminal AC (complete full): want exit 0, got $CLI_EXIT"
assert_state '.status == "closed"' || fail "alias on a complete wave must close, argument ignored"
assert_state '.ended != null' || rc=1
assert_state '.delivery != null' || fail "the close write must fold delivery"

# ---- incomplete demo: no-op; complete demo (TEET done): closes ------------
run_cli scripts/wave-init.sh --wave 2 --mode demo --feature y --force --no-vocabulary --no-behaviour-change --no-ui --no-cr
[ "$CLI_EXIT" = "0" ] || fail "setup init (demo): exit $CLI_EXIT, stderr: $CLI_STDERR"

run_cli scripts/wave-close.sh --if-terminal TEET
[ "$CLI_EXIT" = "0" ] || fail "--if-terminal TEET (incomplete demo): want exit 0, got $CLI_EXIT"
assert_state '.status == "active"' || fail "incomplete demo must stay active even if the alias names TEET"

cp "$WV_TESTS_DIR/fixtures/state/demo-teet-done.json" "$WV_PROJECT/.wave/state.json"
run_cli scripts/wave-close.sh --if-complete
[ "$CLI_EXIT" = "0" ] || fail "--if-complete (complete demo): want exit 0, got $CLI_EXIT"
assert_state '.status == "closed"' || fail "demo wave complete (TEET and the other demo phase rows settled) must close"
assert_state '.ended != null' || rc=1

exit $rc
