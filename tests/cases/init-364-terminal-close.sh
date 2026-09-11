#!/usr/bin/env bash
# tests/cases/init-364-terminal-close.sh — AC-364.
#
# `wave-close.sh --if-terminal <PHASE>` is the primitive a future
# subagent-stop.sh (Task 8) calls on every phase completion: it derives the
# mode's terminal phase from hooks/phases.tsv (the LAST row, in file order,
# whose `modes` column includes the active mode -- AD is the last full-mode
# row, TEET the last demo-mode row, matching spec section 4/6 by
# construction rather than by a hardcoded name) and closes the wave only
# when <PHASE> matches it; any other phase is a silent no-op.
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

# ---- mode: full — AD is terminal ------------------------------------------
run_cli scripts/wave-init.sh --wave 1 --mode full --feature x
[ "$CLI_EXIT" = "0" ] || fail "setup init (full): exit $CLI_EXIT, stderr: $CLI_STDERR"

run_cli scripts/wave-close.sh --if-terminal AC
[ "$CLI_EXIT" = "0" ] || fail "--if-terminal AC (full): want exit 0, got $CLI_EXIT (stderr: $CLI_STDERR)"
assert_state '.status == "active"' || fail "AC is not terminal for full mode; the wave must still be active"

run_cli scripts/wave-close.sh --if-terminal AD
[ "$CLI_EXIT" = "0" ] || fail "--if-terminal AD (full): want exit 0, got $CLI_EXIT (stderr: $CLI_STDERR)"
assert_state '.status == "closed"' || fail "AD is terminal for full mode; the wave must be closed"
assert_state '.ended != null' || rc=1

# ---- mode: demo — TEET is terminal ----------------------------------------
run_cli scripts/wave-init.sh --wave 2 --mode demo --feature y
[ "$CLI_EXIT" = "0" ] || fail "setup init (demo): exit $CLI_EXIT, stderr: $CLI_STDERR"

run_cli scripts/wave-close.sh --if-terminal AC
[ "$CLI_EXIT" = "0" ] || fail "--if-terminal AC (demo): want exit 0, got $CLI_EXIT (stderr: $CLI_STDERR)"
assert_state '.status == "active"' || fail "AC is not terminal for demo mode; the wave must still be active"

run_cli scripts/wave-close.sh --if-terminal TEET
[ "$CLI_EXIT" = "0" ] || fail "--if-terminal TEET (demo): want exit 0, got $CLI_EXIT (stderr: $CLI_STDERR)"
assert_state '.status == "closed"' || fail "TEET is terminal for demo mode; the wave must be closed"
assert_state '.ended != null' || rc=1

exit $rc
