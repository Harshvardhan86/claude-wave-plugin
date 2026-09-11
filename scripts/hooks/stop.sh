#!/usr/bin/env bash
# scripts/hooks/stop.sh — the Stop hook (spec section 9's scorecard pointer).
#
# `Stop` fires at the end of EVERY assistant turn in the main session, so
# this must stay silent on every turn except the one where the active mode's
# terminal phase (`AD` full, `TEET` demo; solo has none — see below) has
# just become `done` AND the ledger actually has something to score. Once it
# prints, it writes `.wave/.scorecard-printed` and never prints again for
# this wave (AC-322).
#
# This script never renders the scorecard itself — `scripts/wave-scorecard.sh`
# is Task 11's — it only names the command, so the path is correct on day one
# even though that script does not exist until Task 11 ships.
#
# Never blocks the stop: this event's own additionalContext channel
# (lib.sh's wv_warn_channel_is_stdout includes Stop) is only ever used here
# for an informational pointer, never a deny.

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

  [ -f "$WV_WAVE_DIR/.scorecard-printed" ] && return 0

  local ledger="$WV_WAVE_DIR/ledger.jsonl"
  [ -s "$ledger" ] || return 0   # AC-323: nothing to score, stay silent

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
      settled=1
      ;;
  esac
  [ "$settled" = "1" ] || return 0

  mkdir -p "$WV_WAVE_DIR" 2>/dev/null
  : > "$WV_WAVE_DIR/.scorecard-printed" 2>/dev/null

  wv_rule_warn W-SCORECARD "$WV_WAVE" "$WV_PLUGIN_DIR/scripts/wave-scorecard.sh (writes .wave/scorecard.md)"
  return 0
}

wv_main
wv_emit_flush
exit 0
