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

# What is left of the reason corpus's 400-character bound after this template
# (164 fixed characters) and its five other arguments at their longest (a wave id,
# a mode, "enforce=warn (violations will be reported, not blocked)", a phase code,
# and the wave id again). Measured, not guessed: tests/tools/reason-corpus.sh
# prints the resulting maximum and fails if it is exceeded.
WV_SESSION_EXTRA_MAX=150

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

  # THE ADVISORY CLAUSES, collected and then BOUNDED.
  #
  # This banner is a template plus an `extra` assembled at run time, and `extra`
  # grew with the situation: two clauses at once, one of them carrying a filename
  # of any length, pushed the rendered reason to 440 characters against a
  # 400-character bound — and it did so with no commit to blame, because the
  # second clause only appears once real time passes 24h after the wave started.
  # So the clauses are short, they are collected into a list, and the list is
  # capped (lib.sh's wv_list_cap, which truncates rather than exempting a long
  # item). WV_SESSION_EXTRA_MAX is what is left of the 400-character bound after
  # the template and the five other arguments at their longest; it is stated here,
  # in the code that enforces it, and tests/cases/session-327b-worst-case-banner
  # is the fixture that turns every clause on so the corpus can see the maximum.
  local -a clauses=()
  if [ "$source_val" = "compact" ]; then
    local latest
    if latest="$(wv_latest_checkpoint)"; then
      clauses+=("compaction ran; re-read .wave/checkpoints/$latest in a fresh terminal (Invariant 7).")
    else
      clauses+=("compaction ran; no checkpoint — re-derive from .wave/state.json in a fresh terminal (Invariant 7).")
    fi
  fi

  if wv_wave_stale_24h; then
    clauses+=("wave open >24h; scripts/wave-close.sh closes it.")
  fi

  local extra=""
  if [ "${#clauses[@]}" -gt 0 ]; then
    extra=" $(wv_list_cap "${#clauses[@]}" "$WV_SESSION_EXTRA_MAX" ' ' "${clauses[@]}")"
  fi

  wv_rule_warn W-SESSION "$WV_WAVE" "$WV_MODE" "$enforce_clause" "$last_done" "$WV_WAVE" "$extra"
  return 0
}

wv_main
wv_emit_flush
exit 0
