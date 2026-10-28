#!/usr/bin/env bash
# scripts/hooks/stop.sh — the Stop hook (spec section 9's scorecard pointer).
#
# THIS HOOK NEVER CLOSES THE WAVE, blocks a stop, or signals a process. The
# close-time verdict (W-UNDELIVERED) and the scorecard pointer (W-SCORECARD,
# or W-LEFTOVER, which names the scorecard) belong to a CLOSED wave: the
# closing SubagentStop closes it and announces them in that same call. A
# closed wave is silent here (wv_state_read refuses it).
#
# Full and demo: on a wave that is complete (every when=phase row of the
# active mode settled) but still active — the close failed, the final stop
# was blocked, or the remaining rows were skipped without a closing stop —
# the leftover inventory is refreshed (.wave/checkpoints/) and the Stop
# prints W-STATE "complete but not closed", naming scripts/wave-close.sh,
# and NOTHING else: no verdict, no pointer, no marker. Every such Stop says
# it again, because nothing has silenced it; the remedy closes the wave.
#
# Solo: no close exists and the verdict is always not-applicable, so a
# non-empty ledger is the signal, and the warnings come from the SAME
# composition the closing SubagentStop uses (lib.sh wv_close_announce):
# W-LEFTOVER when leftovers were found and not warned in a prior call,
# otherwise the once-per-wave W-SCORECARD, each with its marker.

set -u

WV_HOOK_DIR="$(cd "${BASH_SOURCE[0]%/*}" 2>/dev/null && pwd)"
# shellcheck source=scripts/hooks/lib.sh
source "$WV_HOOK_DIR/lib.sh"

wv_main() {
  wv_parse_stdin || return 0
  [ "$WV_EVENT" = "Stop" ] || return 0
  wv_project_root || return 0
  wv_state_read || return 0

  local ledger="$WV_WAVE_DIR/ledger.jsonl"

  local settled=0
  case "$WV_MODE" in
    full|demo)
      wv_wave_complete && settled=1
      ;;
    *)
      # Solo mode never runs phases.tsv's pipeline and so has no phase
      # rows (AC-324): a non-empty ledger IS the signal to print, once.
      [ -s "$ledger" ] && settled=1
      ;;
  esac
  [ "$settled" = "1" ] || return 0

  wv_lo_collect
  wv_lo_write_checkpoint

  case "$WV_MODE" in
    full|demo)
      # Complete but not closed (a closed wave never reaches this line). The
      # inventory above still landed; the verdict, the pointer and every
      # once-per-wave marker wait for the close.
      local lo_note=""
      [ "$WV_LO_WARN" = "1" ] && lo_note="; leftovers found, listed in the newest .wave/checkpoints/ file"
      wv_rule_warn W-STATE "wave $WV_WAVE is complete but not closed, so no verdict or scorecard pointer yet (Stop never closes a wave)$lo_note; close it with \`scripts/wave-close.sh\`"
      return 0
      ;;
  esac

  wv_close_announce "$(wv_delivery_verdict)"
  return 0
}

wv_main
wv_emit_flush
exit 0
