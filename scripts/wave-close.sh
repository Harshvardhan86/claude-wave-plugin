#!/usr/bin/env bash
# scripts/wave-close.sh — closes the active wave.
#
# Usage:
#   wave-close.sh                       closes the current active wave whatever
#                                        its completeness (AC-363); exits 1 and
#                                        closes NOTHING when the wave changed
#                                        (another wave id or start time) or was
#                                        closed while this script waited for the
#                                        lock — check .wave/state.json, then
#                                        re-run to close the current wave
#   wave-close.sh --if-complete         close only if every when=phase row of
#                                        the active mode is settled (wave
#                                        complete); a silent no-op otherwise
#   wave-close.sh --if-terminal <PHASE> accepted alias for --if-complete; the
#                                        phase argument is ignored
#
# Both forms set status:"closed", ended, and delivery in the same write,
# reusing scripts/hooks/lib.sh's wv_state_update for the locked
# read-modify-write. delivery is the 5.4 table: nothing unanswered or
# missing reads as a pass.
#
# LOCK ORDER. The close is a conditional write, so the facts that authorise
# it are read UNDER the wave lock, never before it: take the lock, re-read
# state.json, check it is still the same active wave (id and start time) the
# caller saw, decide completeness and the delivery verdict, write (a nested
# wv_state_update, which only counts the lock depth up and down), release.
# A hook that records a redo, a changed benefit verdict, a new wave or
# another close while this script waits for the lock is therefore seen, not
# overwritten (tests/cases/complete-close-lock-race.sh). The first read,
# before the lock, only locates the wave and records which one it is. On a
# changed or already-closed wave, --if-complete exits 0 silently (the hook
# that called it reads state.json back and reports); the bare form dies with
# exit 1 naming what changed, and nothing is written.
#
# Wave complete is derived from hooks/phases.tsv, never from a hardcoded
# terminal phase: every when=phase row of the active mode must be settled
# (done, or skipped by mode or condition). anytime rows never count, so AD
# never closes a full-mode wave. Demo closes when its phase rows are
# settled (TEET done, predecessors done or skipped). Solo has no phase
# rows, so --if-complete is always a no-op there.
#
# STDOUT CONTRACT for subagent-stop.sh: under --if-complete and under
# --if-terminal, this script writes NOTHING to stdout — on a match, a
# no-match, or an inactive wave alike — only to stderr. subagent-stop.sh is
# a hook whose stdout must carry exactly one JSON object (or none at all),
# so a plain human line here would corrupt that channel. The bare
# (no-argument) form is the only one that ever prints to stdout, because
# nothing but a human runs it.
set -u

WV_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/hooks/lib.sh
source "$WV_SCRIPT_DIR/hooks/lib.sh"

wv_die() {
  printf 'wave-close.sh: %s\n' "$*" >&2
  exit 1
}

if_complete=0
case "${1:-}" in
  --if-complete)
    if_complete=1
    ;;
  --if-terminal)
    [ -n "${2:-}" ] || wv_die "--if-terminal requires a phase code"
    if_complete=1
    ;;
  "")
    : ;;
  *)
    wv_die "unknown argument: $1" ;;
esac

if ! wv_project_root; then
  [ "$if_complete" = "1" ] && exit 0
  wv_die "no project found from $PWD (no active wave)"
fi

if ! wv_state_read; then
  [ "$if_complete" = "1" ] && exit 0
  case "$WV_STATUS" in
    closed) wv_die "the wave at $WV_ROOT/.wave/state.json is already closed" ;;
    *) wv_die "no active wave found at $WV_ROOT/.wave/state.json" ;;
  esac
fi

# This process measured the wave; the W-UNDELIVERED warning is allowed to
# fire. Hooks set WV_PARSED by parsing stdin; this script has no stdin.
WV_PARSED=1

# The wave the caller is acting on, as first seen.
seen_wave="$WV_WAVE"
seen_started="$(printf '%s' "$WV_STATE" | jq -r '.started // ""' 2>/dev/null)"

if ! wv_lock_acquire; then
  # wv_die exits without flushing the warning queue, so the reason is in the
  # message itself (tests/cases/complete-close-lock-busy.sh).
  wv_warn W-STATE "$(wv_lock_detail), so nothing was recorded and the state was left untouched"
  wv_die "could not write $WV_STATE_FILE: $(wv_lock_detail); nothing was closed, re-run once it is free"
fi

# Everything from here to the write is decided under the lock.
if ! wv_state_read; then
  wv_lock_release
  [ "$if_complete" = "1" ] && exit 0
  case "$WV_STATUS" in
    closed) wv_die "the wave at $WV_ROOT/.wave/state.json was closed while this script waited for the lock" ;;
    *) wv_die "no active wave found at $WV_ROOT/.wave/state.json" ;;
  esac
fi
now_started="$(printf '%s' "$WV_STATE" | jq -r '.started // ""' 2>/dev/null)"
if [ "$WV_WAVE" != "$seen_wave" ] || [ "$now_started" != "$seen_started" ]; then
  wv_lock_release
  [ "$if_complete" = "1" ] && exit 0
  wv_die "the wave at $WV_ROOT/.wave/state.json changed while this script waited for the lock (wave $seen_wave is now wave $WV_WAVE); nothing was closed, re-run to close the current wave"
fi

if [ "$if_complete" = "1" ]; then
  if ! wv_wave_complete; then
    wv_lock_release
    exit 0
  fi
fi

delivery="$(wv_delivery_verdict)"
delivery_json="$(jq -Rn --arg d "$delivery" '$d')"

ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
ts_json="$(jq -Rn --arg t "$ts" '$t')"
if ! wv_state_update ".status = \"closed\" | .ended = ${ts_json} | .delivery = ${delivery_json}"; then
  wv_lock_release
  wv_die "could not write $WV_STATE_FILE"
fi
wv_lock_release

case "$delivery" in
  undelivered|unverified)
    wv_emit_undelivered "$delivery"
    wv_emit_flush
    ;;
esac

if [ "$if_complete" = "1" ]; then
  printf 'wave-close.sh: wave %s closed at %s\n' "$WV_WAVE" "$WV_STATE_FILE" >&2
else
  printf 'wave-close.sh: wave %s closed at %s\n' "$WV_WAVE" "$WV_STATE_FILE"
fi
exit 0
