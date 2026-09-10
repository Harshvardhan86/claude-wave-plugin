#!/usr/bin/env bash
# scripts/hooks/session-start.sh — the SessionStart hook (matcher
# `startup|resume|clear|compact`), spec section 10.
#
# One line of additionalContext, only while a wave is active: the wave id,
# mode, enforce (with the "violations will be reported, not blocked"
# sentence when enforce is warn), the last phase marked done (or "none"),
# and the literal tag template. Two more sentences are appended, each only
# when it applies:
#
#   - `source == "compact"`: the invariant-7 advisory naming the latest
#     checkpoint under .wave/checkpoints/ and asking for a fresh terminal
#     (PreCompact's own output is ignored by the platform — this is the one
#     place that advisory can actually reach a human).
#   - the wave has been active for more than 24h: a staleness warning naming
#     scripts/wave-close.sh.
#
# Everything here rides on ONE W-SESSION reason (one JSON object, one `W-`
# token — Global Constraint 5 / the harness's assert_single_rule_token): the
# two optional sentences are folded into that single reason's last argument
# rather than queued as separate rule warnings, precisely so they never add
# a second `W-` token to the same additionalContext string.
#
# Kept on in every mode including solo: this is informational, not part of
# the tag/order/round machinery solo turns off, and nothing in this file
# ever denies anything.

set -u

WV_HOOK_DIR="$(cd "${BASH_SOURCE[0]%/*}" 2>/dev/null && pwd)"
# shellcheck source=scripts/hooks/lib.sh
source "$WV_HOOK_DIR/lib.sh"

wv_main() {
  wv_parse_stdin || return 0
  [ "$WV_EVENT" = "SessionStart" ] || return 0
  wv_project_root || return 0
  wv_state_read || return 0

  local source_val
  source_val="$(wv_json '.source // ""')"

  local last_done="none"
  case "$WV_MODE" in
    full|demo) last_done="$(wv_last_done_phase)" ;;
  esac

  local enforce_clause
  if [ "$WV_ENFORCE" = "warn" ]; then
    enforce_clause="enforce=warn (violations will be reported, not blocked)"
  else
    enforce_clause="enforce=$WV_ENFORCE"
  fi

  local extra=""
  if [ "$source_val" = "compact" ]; then
    local latest
    if latest="$(wv_latest_checkpoint)"; then
      extra="$extra Invariant 7: compaction just ran; re-read the latest checkpoint ($latest) in a fresh terminal before continuing."
    else
      extra="$extra Invariant 7: compaction just ran, but no checkpoint was found under .wave/checkpoints/; a fresh terminal should re-derive state from .wave/state.json and .wave/ledger.jsonl."
    fi
  fi

  if wv_wave_stale_24h; then
    extra="$extra Wave $WV_WAVE has been active for over 24 hours; consider scripts/wave-close.sh if it should be closed."
  fi

  wv_rule_warn W-SESSION "$WV_WAVE" "$WV_MODE" "$enforce_clause" "$last_done" "$WV_WAVE" "$extra"
  return 0
}

wv_main
wv_emit_flush
exit 0
