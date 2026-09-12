#!/usr/bin/env bash
# scripts/hooks/stop.sh — the Stop hook (spec section 9's scorecard pointer).
#
# Eligible Stop events refresh the leftover inventory before the scorecard
# marker or empty-ledger returns. Outstanding or unmeasured resources produce
# one W-LEFTOVER warning on each firing. A clean inventory keeps the existing
# once-per-wave W-SCORECARD pointer. Solo eligibility still requires a ledger.
# This hook never closes the wave, blocks a stop, or signals a process.

set -u

WV_HOOK_DIR="$(cd "${BASH_SOURCE[0]%/*}" 2>/dev/null && pwd)"
# shellcheck source=scripts/hooks/lib.sh
source "$WV_HOOK_DIR/lib.sh"

wv_stop_terminal_phase_for_mode() {
  # wv_stop_terminal_phase_for_mode <mode> -> the LAST hooks/phases.tsv row
  # (file order) whose `modes` column includes <mode>, or empty if none do.
  # A minimal, read-only copy of scripts/wave-close.sh's function of the same
  # name. The duplication is deliberate and the reason is here rather than in a
  # planning document nobody reading this file has open: stop.sh must never invoke
  # wave-close.sh itself for this, since that
  # script's bare and --if-terminal forms both have the side effect of
  # actually CLOSING the wave, which is not this hook's job.
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

wv_main() {
  wv_parse_stdin || return 0
  [ "$WV_EVENT" = "Stop" ] || return 0
  wv_project_root || return 0
  wv_state_read || return 0

  local ledger="$WV_WAVE_DIR/ledger.jsonl"

  local settled=0
  case "$WV_MODE" in
    full|demo)
      local terminal
      terminal="$(wv_stop_terminal_phase_for_mode "$WV_MODE")"
      [ -n "$terminal" ] || return 0
      [ "$(wv_state_phase_status "$terminal")" = "done" ] && settled=1
      ;;
    *)
      # Solo mode never runs phases.tsv's pipeline and so has no terminal
      # phase (AC-324): a non-empty ledger IS the signal to print, once.
      [ -s "$ledger" ] && settled=1
      ;;
  esac
  [ "$settled" = "1" ] || return 0

  wv_lo_collect
  wv_lo_write_checkpoint
  if [ "$WV_LO_WARN" = "1" ]; then
    wv_rule_warn W-LEFTOVER "$WV_LO_SUMMARY"
    return 0
  fi

  [ -f "$WV_WAVE_DIR/.scorecard-printed" ] && return 0

  [ -s "$ledger" ] || return 0   # Nothing to score; the inventory still landed.
  mkdir -p "$WV_WAVE_DIR" 2>/dev/null
  : > "$WV_WAVE_DIR/.scorecard-printed" 2>/dev/null

  wv_rule_warn W-SCORECARD "$WV_WAVE" "$WV_PLUGIN_DIR/scripts/wave-scorecard.sh (writes .wave/scorecard.md)"
  return 0
}

wv_main
wv_emit_flush
exit 0
