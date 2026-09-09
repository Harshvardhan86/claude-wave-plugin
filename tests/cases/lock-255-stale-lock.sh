#!/usr/bin/env bash
# tests/cases/lock-255-stale-lock.sh — AC-255: a lock file whose recorded holder
# pid is DEAD must not wedge the wave. A hook that crashed between acquiring and
# releasing leaves its pid behind in `.wave/lock`; the file is not the lock (the
# kernel released that when the process died), so the next writer takes it
# immediately and its ledger line is written.
set -u

# shellcheck source=tests/lib/assert.sh
source "$(dirname "$0")/../lib/assert.sh"
# shellcheck source=tests/lib/stop.sh
source "$(dirname "$0")/../lib/stop.sh"

name="${WV_CASE_NAME:-$(basename "$0" .sh)}"
log="${WV_CASE_LOG:-$WV_RUN_TMP/logs/$name.log}"
rc=0
fail() { printf 'ASSERT FAIL: %s\n' "$*" >&2; rc=1; }
printf 'RAN subagent-stop.sh %s decision=allow\n' "$name" >> "$log"

# A pid that is certainly dead: start a process, reap it, reuse its number.
( exit 0 ) &
dead=$!
wait "$dead" 2>/dev/null
if kill -0 "$dead" 2>/dev/null; then
  fail "could not obtain a dead pid ($dead is still alive)"
  exit 1
fi

WV_PROJECT="$(mkproj)"
mkdir -p "$WV_PROJECT/.wave"
printf '%s\n' "$dead" > "$WV_PROJECT/.wave/lock"
lock_inode_before="$(stat -c %i "$WV_PROJECT/.wave/lock")"

st="$WV_RUN_TMP/$name-state.json"
c="$WV_RUN_TMP/$name.json"
stop_state "$st" ".active = {a1: $(stop_active AC reviewer opus)}" || exit 1
stop_case "$c" "$(printf '.seed.state = "%s" | .seed.files = {".wave/ac.md": "AC-1 records the spend\\n"}' "$st")" || exit 1

start="$SECONDS"
run_hook subagent-stop.sh "$c" || { fail "run_hook: $WV_LAST_STDERR"; exit 1; }
elapsed=$((SECONDS - start))

assert_allow || fail "want no block"
[ "$elapsed" -lt 10 ] || fail "took ${elapsed}s: a stale lock must not be waited out"
[ "$(stop_ledger_count)" = "1" ] || fail "ledger has $(stop_ledger_count) line(s), want 1"
[ "$(stop_phase_status AC)" = "done" ] || fail "AC is '$(stop_phase_status AC)', want done"
[ "$(stat -c %i "$WV_PROJECT/.wave/lock")" = "$lock_inode_before" ] || \
  fail "the lock file was replaced; it must never be recreated"

exit $rc
