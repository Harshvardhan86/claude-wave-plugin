#!/usr/bin/env bash
# tests/cases/init-358c-force-lock-exclusion.sh — fix round 1, review finding 2.
#
# `.wave/lock` is never replaced across a close/init cycle (scripts/hooks/
# lib.sh's header), so under --force it is the SAME lock file a
# still-finishing subagent's locked wv_state_update against the OLD wave may
# be holding. wave-init.sh must take that lock before the archive-or-refuse
# decision and the final write, and hold it across both (scripts/hooks/
# lib.sh's wv_lock_acquire / wv_lock_release, nested-safe) — never write
# through an externally-held lock. Proved by counting, not by argument: an
# outside process holds the lock for 13s (longer than wv_lock_acquire's 10s
# flock timeout); `wave-init.sh --force` must then either wait for it or
# fail loudly after the timeout, and in neither case may it have written
# anything while the lock was held.
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
lock_file="$WV_PROJECT/.wave/lock"
before="$(cat "$state_file")"

# An outside process holds the SAME lock wave-init.sh must take, for longer
# than the library's 10s flock timeout.
( flock -x 9; sleep 13 ) 9>>"$lock_file" &
holder=$!
sleep 0.5   # let the holder actually take it before wave-init.sh tries

start_ts=$(date +%s)
run_cli scripts/wave-init.sh --wave 2 --mode full --feature y --force
elapsed=$(( $(date +%s) - start_ts ))

printf 'lock-exclusion: --force under an externally-held lock -> exit=%s elapsed=%ss (want exit!=0, elapsed>=9)\n' \
  "$CLI_EXIT" "$elapsed"

[ "$CLI_EXIT" != "0" ] || fail "wave-init.sh --force must not succeed while another process holds .wave/lock, but it exited 0"
[ "$elapsed" -ge 9 ] || fail "wave-init.sh returned in ${elapsed}s without ever contending for the held lock (want >=9s, i.e. it actually waited on flock)"
case "$CLI_STDERR" in
  *lock*|*Lock*) : ;;
  *) fail "stderr does not mention the lock: '$CLI_STDERR'" ;;
esac

after_during_hold="$(cat "$state_file")"
[ "$before" = "$after_during_hold" ] || fail "state.json was modified while the lock was externally held (clobbered)"
[ -z "$(find "$WV_PROJECT/.wave/archive" -maxdepth 1 -name '*-state.json' 2>/dev/null)" ] || \
  fail "wave 1 was archived despite never acquiring the lock"

wait "$holder"

# Positive control: once the external holder releases, --force succeeds.
run_cli scripts/wave-init.sh --wave 2 --mode full --feature y --force
[ "$CLI_EXIT" = "0" ] || fail "after the external holder released, --force should now succeed: exit $CLI_EXIT, stderr: $CLI_STDERR"
assert_state '.wave == "2"' || rc=1
assert_state '.status == "active"' || rc=1

exit $rc
