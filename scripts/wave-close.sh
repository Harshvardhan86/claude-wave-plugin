#!/usr/bin/env bash
# scripts/wave-close.sh — closes the active wave.
#
# Usage:
#   wave-close.sh                       unconditional close (AC-363)
#   wave-close.sh --if-terminal <PHASE> close only if <PHASE> is the active
#                                        mode's terminal phase (AC-364); a
#                                        silent no-op otherwise, so a future
#                                        subagent-stop.sh (Task 8) can call
#                                        this on every phase completion
#                                        without judging terminality itself.
#
# Both forms set status:"closed" and ended in the same write, reusing
# scripts/hooks/lib.sh's wv_state_update for the locked read-modify-write.
#
# The mode's terminal phase is derived from hooks/phases.tsv, never
# hardcoded: it is the LAST row (file order) whose `modes` column includes
# the active mode. That is AD for full mode and TEET for demo mode by
# construction (spec sections 4 and 6), and empty for solo mode (phases.tsv
# is not consulted in solo mode at all), so --if-terminal is always a no-op
# there.
#
# STDOUT CONTRACT for Task 8 (subagent-stop.sh): under --if-terminal, this
# script writes NOTHING to stdout — on a match, a no-match, or an inactive
# wave alike — only to stderr. subagent-stop.sh is a hook whose stdout must
# carry exactly one JSON object (or none at all), so a plain human line
# here would corrupt that channel. The bare (no-argument) form is the only
# one that ever prints to stdout, because nothing but a human runs it.
set -u

WV_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/hooks/lib.sh
source "$WV_SCRIPT_DIR/hooks/lib.sh"

wv_die() {
  printf 'wave-close.sh: %s\n' "$*" >&2
  exit 1
}

if_terminal=""
case "${1:-}" in
  --if-terminal)
    if_terminal="${2:-}"
    [ -n "$if_terminal" ] || wv_die "--if-terminal requires a phase code"
    ;;
  "")
    : ;;
  *)
    wv_die "unknown argument: $1" ;;
esac

wv_terminal_phase_for_mode() {
  # wv_terminal_phase_for_mode <mode> -> the last hooks/phases.tsv row (file
  # order) whose modes column includes <mode>, or empty if none do.
  local mode="$1" tsv="$WV_PLUGIN_DIR/hooks/phases.tsv"
  [ -f "$tsv" ] || return 0
  local last="" code modes rest
  while IFS=$'\t' read -r code modes rest; do
    case "$code" in ''|'#'*|code) continue ;; esac
    case ",$modes," in
      *",$mode,"*) last="$code" ;;
    esac
  done < "$tsv"
  printf '%s' "$last"
}

if ! wv_project_root; then
  [ -n "$if_terminal" ] && exit 0
  wv_die "no project found from $PWD (no active wave)"
fi

if ! wv_state_read; then
  [ -n "$if_terminal" ] && exit 0
  case "$WV_STATUS" in
    closed) wv_die "the wave at $WV_ROOT/.wave/state.json is already closed" ;;
    *) wv_die "no active wave found at $WV_ROOT/.wave/state.json" ;;
  esac
fi

if [ -n "$if_terminal" ]; then
  terminal="$(wv_terminal_phase_for_mode "$WV_MODE")"
  [ "$terminal" = "$if_terminal" ] || exit 0
fi

ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
ts_json="$(jq -Rn --arg t "$ts" '$t')"
if ! wv_state_update ".status = \"closed\" | .ended = ${ts_json}"; then
  wv_die "could not write $WV_STATE_FILE"
fi

if [ -n "$if_terminal" ]; then
  printf 'wave-close.sh: wave %s closed at %s\n' "$WV_WAVE" "$WV_STATE_FILE" >&2
else
  printf 'wave-close.sh: wave %s closed at %s\n' "$WV_WAVE" "$WV_STATE_FILE"
fi
exit 0
