#!/usr/bin/env bash
# tests/cases/complete-close-lock-busy.sh — a bare wave-close.sh that cannot
# take the wave lock says WHY on stderr (the lock is held, and for how long it
# waited), exits 1 and writes nothing. Before, it printed only "could not
# write .../state.json": the lock detail was queued as a warning the dying
# script never flushed.
set -u

# shellcheck source=tests/lib/assert.sh
source "$(dirname "$0")/../lib/assert.sh"

name="$(basename "$0" .sh)"
log="${WV_CASE_LOG:-$WV_RUN_TMP/logs/$name.log}"
mkdir -p "$(dirname "$log")"
rc=0
fail() { printf 'ASSERT FAIL: %s\n' "$*" >&2; rc=1; }

command -v flock >/dev/null 2>&1 || { fail "flock(1) is not on PATH; this case cannot hold the lock"; exit 1; }

WV_PROJECT="$(mkproj)"
: > "$WV_PROJECT/README.md"
git -C "$WV_PROJECT" add README.md
git -C "$WV_PROJECT" commit -q -m init
run_cli scripts/wave-init.sh --wave 1 --mode full --feature x
[ "$CLI_EXIT" = "0" ] || fail "init: exit $CLI_EXIT ($CLI_STDERR)"
before="$(sha256sum "$WV_PROJECT/.wave/state.json" | awk '{print $1}')"

wv_on_exit 'exec 8>&- 2>/dev/null'
exec 8>>"$WV_PROJECT/.wave/lock"
flock -w 5 8 || { fail "could not take the lock for the test"; exit 1; }
export WV_LOCK_TIMEOUT_OVERRIDE=1
run_cli scripts/wave-close.sh
unset WV_LOCK_TIMEOUT_OVERRIDE
exec 8>&-

[ "$CLI_EXIT" = "1" ] || fail "a bare close that cannot lock must exit 1, got $CLI_EXIT"
case "$CLI_STDERR" in
  *"could not write"*"was held by another hook for longer than 1s"*) : ;;
  *) fail "stderr must name the held lock and the wait: '$CLI_STDERR'" ;;
esac
[ "$(sha256sum "$WV_PROJECT/.wave/state.json" | awk '{print $1}')" = "$before" ] || fail "state.json changed although the close could not lock"

# Control: the lock free, the same close succeeds.
run_cli scripts/wave-close.sh
[ "$CLI_EXIT" = "0" ] || fail "control: exit $CLI_EXIT ($CLI_STDERR)"

exit $rc
