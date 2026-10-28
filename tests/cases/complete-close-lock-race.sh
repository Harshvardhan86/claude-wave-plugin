#!/usr/bin/env bash
# complete-close-lock-race.sh — wave-close.sh decides under the wave lock.
#
# The close is a conditional write: "if every phase row is settled, record
# closed + ended + delivery". If the facts that authorise it are read BEFORE
# the lock, a cooperating writer that changes them while the closer waits
# for the lock is overwritten by a decision made on stale facts. Each leg
# below is a real interleaving, driven deterministically, with no product
# function stubbed:
#
#   1. this case takes .wave/lock with flock(1);
#   2. it starts the closer and waits until the closer's own lock descriptor
#      (fd 9, scripts/hooks/lib.sh wv_lock_acquire) is open on that file, so
#      the closer is now blocked on the lock;
#   3. it changes the state the way a hook would (temp file + mv);
#   4. it releases the lock and waits for the closer, with a ceiling.
#
# Legs: control (nothing changes: the closer closes, so the instrument can
# see a close); TEET recorded redo while waiting (must stay active); the
# benefit verdict changes while waiting (the recorded delivery is the one
# true under the lock); a NEW wave is initialised while waiting (its id
# differs: no close, for --if-complete and for the bare form); the wave is
# closed by someone else while waiting (--if-complete is a no-op and does
# not rewrite ended / delivery).
set -u
source "$(dirname "$0")/../lib/assert.sh"
source "$(dirname "$0")/../lib/stop.sh"
name="${WV_CASE_NAME:-$(basename "$0" .sh)}"
log="${WV_CASE_LOG:-$WV_RUN_TMP/logs/$name.log}"
rc=0
fail() { printf 'ASSERT FAIL: %s\n' "$*" >&2; rc=1; }
printf 'RAN scripts/wave-close.sh %s decision=multi\n' "$name" >> "$log"

command -v flock >/dev/null 2>&1 || { fail "flock(1) is not on PATH; this case cannot drive the interleaving"; exit 1; }

closer_pid=""
# The closer is this case's own child: killed by recorded pid, never by a
# pattern, on every exit path.
wv_on_exit '[ -z "$closer_pid" ] || kill "$closer_pid" 2>/dev/null; exec 8>&- 2>/dev/null; wait 2>/dev/null'

DEMO="$WV_TESTS_DIR/fixtures/state/demo-teet-done.json"
FULL="$WV_TESTS_DIR/fixtures/state/full-all-done.json"

newproj() {
  # newproj <state fixture> [jq filter] -> WV_PROJECT seeded with it and an
  # empty .wave/lock, as wave-init.sh leaves it.
  WV_PROJECT="$(mkproj)"
  mkdir -p "$WV_PROJECT/.wave/findings"
  jq "${2:-.}" "$1" > "$WV_PROJECT/.wave/state.json" || return 1
  : > "$WV_PROJECT/.wave/lock"
}

set_state() {
  # set_state <jq filter> — a hook-shaped write: temp file, then mv.
  local s="$WV_PROJECT/.wave/state.json"
  jq "$1" "$s" > "$s.race" && mv -f "$s.race" "$s"
}

RACE_OUT=""; RACE_ERR=""; RACE_RC=""
race() {
  # race <label> <mutator command or :> [closer args...]
  local label="$1" mutate="$2" lock want i
  shift 2
  lock="$WV_PROJECT/.wave/lock"
  want="$(realpath "$lock")"
  RACE_OUT="$WV_RUN_TMP/$name.out"; RACE_ERR="$WV_RUN_TMP/$name.err"; RACE_RC=""
  exec 8>>"$lock"
  flock -w 5 8 || { fail "$label: could not take the lock for the test"; exec 8>&-; return 1; }
  ( cd "$WV_PROJECT" && exec bash "$WV_REPO_ROOT/scripts/wave-close.sh" "$@" >"$RACE_OUT" 2>"$RACE_ERR" 8>&- ) &
  closer_pid=$!
  i=0
  while [ "$(readlink "/proc/$closer_pid/fd/9" 2>/dev/null)" != "$want" ] && [ "$i" -lt 500 ]; do
    kill -0 "$closer_pid" 2>/dev/null || break
    sleep 0.01; i=$((i + 1))
  done
  if [ "$(readlink "/proc/$closer_pid/fd/9" 2>/dev/null)" != "$want" ]; then
    fail "$label: the closer never opened its lock descriptor on $lock (it is not waiting on the wave lock)"
  fi
  $mutate
  flock -u 8; exec 8>&-
  i=0
  while kill -0 "$closer_pid" 2>/dev/null && [ "$i" -lt 300 ]; do sleep 0.1; i=$((i + 1)); done
  if kill -0 "$closer_pid" 2>/dev/null; then
    kill "$closer_pid" 2>/dev/null
    fail "$label: the closer did not finish within 30 s of the lock being released"
  fi
  wait "$closer_pid" 2>/dev/null; RACE_RC=$?
  closer_pid=""
  printf 'race %s: closer exit=%s\n' "$label" "$RACE_RC" >> "$log"
}

field() { jq -r "$1" "$WV_PROJECT/.wave/state.json"; }

# ---- control: nothing changes while the closer waits -> it closes ----------
newproj "$DEMO"
race control : --if-complete
[ "$RACE_RC" = "0" ] || fail "control: closer exited $RACE_RC: $(cat "$RACE_ERR")"
[ "$(field .status)" = "closed" ] || fail "control: a complete demo wave must close once the lock frees, got '$(field .status)'"

# ---- TEET recorded redo while the closer waits ------------------------------
newproj "$DEMO"
teet_redo() { set_state '.phases.TEET.status = "redo"'; }
race redo teet_redo --if-complete
[ "$RACE_RC" = "0" ] || fail "redo: closer exited $RACE_RC: $(cat "$RACE_ERR")"
[ ! -s "$RACE_OUT" ] || fail "redo: --if-complete wrote stdout: $(cat "$RACE_OUT")"
[ "$(field .status)" = "active" ] || fail "redo: the closer closed a wave whose TEET was recorded redo while it waited (status '$(field .status)'); completeness must be decided under the lock"
[ "$(field .phases.TEET.status)" = "redo" ] || fail "redo: TEET's redo was lost: '$(field .phases.TEET.status)'"
[ "$(field '.delivery // "unset"')" = "unset" ] || fail "redo: an active wave must not carry a delivery verdict"
[ "$(field '.ended // "null"')" = "null" ] || fail "redo: an active wave must not carry ended"

# ---- the benefit verdict changes while the closer waits ---------------------
newproj "$FULL" '.behaviour_change = true'
printf '%s' "$(stop_findings_zero)" | jq -r 'to_entries[] | [.key, .value] | @tsv' | while IFS=$'\t' read -r k v; do
  printf 'FINDINGS: 0\n' > "$WV_PROJECT/$k"
done
printf 'BENEFIT: DELIVERED\n' > "$WV_PROJECT/.wave/ben-close.md"
ben_flip() { printf 'BENEFIT: UNDELIVERED\n' > "$WV_PROJECT/.wave/ben-close.md.race" && mv -f "$WV_PROJECT/.wave/ben-close.md.race" "$WV_PROJECT/.wave/ben-close.md"; }
race ben ben_flip --if-complete
[ "$RACE_RC" = "0" ] || fail "ben: closer exited $RACE_RC: $(cat "$RACE_ERR")"
[ "$(field .status)" = "closed" ] || fail "ben: the complete full wave must close, got '$(field .status)'"
[ "$(field '.delivery // "unset"')" = "undelivered" ] || fail "ben: delivery is '$(field '.delivery // "unset"')', want undelivered — the verdict true under the lock, not the one read before it"

# ---- a new wave is initialised while the closer waits ----------------------
newproj "$DEMO"
new_wave() { set_state '.wave = "2" | .started = "2026-09-09T12:30:00Z"'; }
race newwave new_wave --if-complete
[ "$RACE_RC" = "0" ] || fail "newwave: --if-complete exited $RACE_RC: $(cat "$RACE_ERR")"
[ ! -s "$RACE_OUT" ] || fail "newwave: --if-complete wrote stdout: $(cat "$RACE_OUT")"
[ "$(field .wave)" = "2" ] || fail "newwave: the new wave id was lost: '$(field .wave)'"
[ "$(field .status)" = "active" ] || fail "newwave: --if-complete closed wave 2 on a decision it made about wave 1 (status '$(field .status)')"

newproj "$DEMO"
race newwave-bare new_wave
[ "$RACE_RC" = "1" ] || fail "newwave-bare: the bare form must refuse (exit 1) when the wave changed while it waited, got $RACE_RC"
[ "$(field .status)" = "active" ] || fail "newwave-bare: the bare form closed wave 2, which nobody asked it to close"
command grep -qF 'changed while' "$RACE_ERR" || fail "newwave-bare: the refusal must say the wave changed while it waited: $(cat "$RACE_ERR")"

# ---- somebody else closes the wave while the closer waits ------------------
newproj "$DEMO"
other_close() { set_state '.status = "closed" | .ended = "2026-09-09T12:45:00Z" | .delivery = "not-applicable"'; }
race closed other_close --if-complete
[ "$RACE_RC" = "0" ] || fail "closed: --if-complete exited $RACE_RC: $(cat "$RACE_ERR")"
[ "$(field .ended)" = "2026-09-09T12:45:00Z" ] || fail "closed: the other closer's ended was rewritten: '$(field .ended)'"
[ ! -s "$RACE_ERR" ] || fail "closed: a no-op must say nothing on stderr: $(cat "$RACE_ERR")"

exit $rc
