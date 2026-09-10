#!/usr/bin/env bash
# tests/cases/lib-lock-timeout-override.sh — the lock-timeout override may only
# SHORTEN the wait, never lengthen it (fix round 1, item 2).
#
# WV_LOCK_TIMEOUT_OVERRIDE exists so a case can drive the lock-TIMEOUT path in a
# second instead of the shipped ten. As first written it accepted any positive
# integer, so `WV_LOCK_TIMEOUT_OVERRIDE=600` made a hook sit on a contended lock
# for ten minutes — well past the 60s the hook advertises to the platform, which
# would have the platform give up on it mid-write. A seam that can only make the
# wait SHORTER cannot do that: a shorter wait spools its ledger line and warns,
# which is the documented timeout behaviour, and the worst it can cost is a
# recorded step that had to be drained by the next acquisition.
#
# Three inputs, and the two directions are the point: a shorter value must be
# honoured (or the seam is useless and the suite pays 14s a run for nothing), a
# longer one must be REFUSED and say so, and a malformed one must fall back to the
# default rather than to zero.
#
# A value EQUAL to the default is deliberately not a step here: honouring 10 and
# ignoring 10 produce the identical wait, so no measurement at the observable can
# tell them apart and there is nothing to assert. The refusal LINE is reserved for
# a value that would have lengthened the wait or was malformed — an equal value is
# a no-op, not a mistake worth a diagnostic.
#
# Measured at the observable: how long the library actually waits on a lock
# somebody else holds. Not by reading the variable back — that would assert the
# assignment, not the wait.
set -u

# shellcheck source=tests/lib/assert.sh
source "$(dirname "$0")/../lib/assert.sh"

name="${WV_CASE_NAME:-$(basename "$0" .sh)}"
log="${WV_CASE_LOG:-$WV_RUN_TMP/logs/$name.log}"
rc=0
fail() { printf 'ASSERT FAIL: %s\n' "$*" >&2; rc=1; }
printf 'RAN scripts/hooks/lib.sh %s decision=multi\n' "$name" >> "$log"

DRIVER="$WV_REPO_ROOT/tests/fixtures/drive-lib.sh"
default="$(command grep -m1 -oE '^WV_LOCK_TIMEOUT=[0-9]+' "$WV_REPO_ROOT/scripts/hooks/lib.sh" | cut -d= -f2)"
case "$default" in
  ''|*[!0-9]*) fail "could not read WV_LOCK_TIMEOUT out of scripts/hooks/lib.sh (got '$default')"; exit 1 ;;
esac
printf 'shipped default read from lib.sh: %ss\n' "$default"

WV_PROJECT="$(mkproj)"
seed_state state/valid-full.json

# Somebody else holds the lock for the whole of this case. The holder announces
# itself with a file AFTER flock returns, and this shell waits for that file: a
# sleep would only make the case flake on a slow box.
held="$WV_RUN_TMP/$name.held"
rm -f "$held"
( flock 9 && : > "$held" && exec sleep 120 ) 9>>"$WV_PROJECT/.wave/lock" &
holder=$!
waited=0
while [ ! -f "$held" ]; do
  waited=$((waited + 1))
  if [ "$waited" -gt 200 ]; then
    fail "the outside lock holder never took .wave/lock, so nothing was measured"
    kill "$holder" 2>/dev/null
    exit $rc
  fi
  sleep 0.05
done

measure() {
  # measure <override value or empty> -> seconds the library waited, on stdout.
  # WV_DRIVE asks for a state update, which is the path that takes the lock.
  local ov="$1" start end
  start="$(date +%s)"
  ( cd "$WV_PROJECT" && printf '%s' '{"hook_event_name":"PreToolUse","tool_name":"Agent","cwd":"."}' \
      | env ${ov:+WV_LOCK_TIMEOUT_OVERRIDE="$ov"} WV_DRIVE='update:.rounds.n = 1' \
        bash "$DRIVER" ) >"$WV_RUN_TMP/$name.out" 2>"$WV_RUN_TMP/$name.err"
  end="$(date +%s)"
  printf '%s' "$((end - start))"
}

# ---- 1 second: honoured, because it is shorter than the default -------------
t="$(measure 1)"
printf 'override=1  -> waited %ss\n' "$t"
[ "$t" -lt 5 ] || fail "override=1 was not honoured: the library waited ${t}s, want under 5"
case "$(cat "$WV_RUN_TMP/$name.out")" in
  *'[W-STATE]'*) : ;;
  *) fail "override=1: a lock timeout must still warn W-STATE, got '$(cat "$WV_RUN_TMP/$name.out")'" ;;
esac

# ---- longer than the default: REFUSED, and said out loud -------------------
t="$(measure 600)"
printf 'override=600 -> waited %ss\n' "$t"
[ "$t" -lt $((default + 4)) ] || \
  fail "override=600 was honoured: the library waited ${t}s; an override may only SHORTEN the wait"
[ "$t" -ge "$default" ] || \
  fail "override=600 fell back to something shorter than the ${default}s default (waited ${t}s)"
case "$(cat "$WV_RUN_TMP/$name.err")" in
  *'WV_LOCK_TIMEOUT_OVERRIDE'*) : ;;
  *) fail "override=600: the refusal must be reported on stderr, got '$(cat "$WV_RUN_TMP/$name.err")'" ;;
esac

# ---- malformed: the default, never zero -----------------------------------
t="$(measure 'abc')"
printf 'override=abc -> waited %ss\n' "$t"
[ "$t" -ge "$default" ] || \
  fail "a non-numeric override must fall back to the ${default}s default, not to a shorter wait (waited ${t}s)"

kill "$holder" 2>/dev/null
wait "$holder" 2>/dev/null
exit $rc
