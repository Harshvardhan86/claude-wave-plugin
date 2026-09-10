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

# What is left of the reason corpus's 400-character bound after everything else in
# this banner is at its longest. DERIVED, term by term, from values that are
# themselves bounded — the previous figure was derived from the same terms except
# that the wave id was not bounded at all, so a 40-character id rendered 458 and a
# 24-character one rendered 405:
#
#   164  hooks/reasons.tsv's W-SESSION template with its six %s removed
#    24  the wave id — scripts/wave-init.sh accepts at most 24 characters
#     4  the mode: full | demo | solo
#    55  the longest enforce clause: "enforce=warn (violations will be reported,
#        not blocked)"
#     9  the longest phase code in hooks/phases.tsv, as the last done phase
#        (TDE-GREEN); "none" is shorter
#    24  the wave id AGAIN, inside the dispatch tag
#     1  the space this file puts in front of `extra`
#     1  wv_list_cap's separator before its "(+N more)" tail
#     9  that tail at its longest here: there are only ever two clauses, so it is
#        "(+1 more)" — and it is appended PAST the character budget, which is why
#        it has to be reserved here rather than assumed to be inside it
#   ---
#   291, so `extra` itself may be 109.
#
# Both clauses fit inside 109 at their longest, so the cap only ever binds when
# BOTH fire; the corpus fixture session-327c-max-banner puts every term above at
# its maximum at once and tests/tools/reason-corpus.sh fails if the render exceeds
# 400. It is a bound for any ACCEPTED input: a state.json carrying a longer id than
# wave-init.sh will now create (hand-edited, or written by an older version) renders
# longer, and no render-time check here would make that state legal.
WV_SESSION_EXTRA_MAX=109

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
  # item) at WV_SESSION_EXTRA_MAX, derived term by term where it is defined.
  # tests/cases/session-327c-max-banner is the fixture that puts every term at its
  # maximum at once so the corpus measures this reason's real maximum (378 of 400),
  # and session-327b and session-327d are the two collisions where the cap binds.
  #
  # THE ORDER IS THE PRIORITY. wv_list_cap fills from the front, so the FIRST
  # clause is the one that survives when the budget cannot hold both — the
  # staleness advisory goes first because it is short and names a command to run,
  # and the compaction advisory is the one that ends up behind "(+1 more)".
  local -a clauses=()
  if wv_wave_stale_24h; then
    clauses+=("wave open >24h; scripts/wave-close.sh closes it.")
  fi

  if [ "$source_val" = "compact" ]; then
    local latest
    if latest="$(wv_latest_checkpoint)"; then
      # `wv_latest_checkpoint` returns a project-relative PATH (it prints
      # `.wave/checkpoints/<file>` itself), so this clause must not prefix it
      # again: the shortened wording introduced in fix round 1 did, and rendered
      # `.wave/checkpoints/.wave/checkpoints/<file>` — a path no operator can open.
      # The case asserted the FILENAME, which is a substring of the doubled path,
      # so nothing failed; session-327 now pins the whole path and forbids the
      # doubled prefix.
      #
      # It does not repeat "compaction ran" either, and that is a budget decision
      # rather than a stylistic one: the phrase costs 15 characters, this clause
      # carries a checkpoint path of up to 55, and the derived budget above is 109.
      # The sibling clause below — which has no path to carry — keeps the phrase.
      clauses+=("Invariant 7: re-read $latest in a fresh terminal.")
    else
      clauses+=("compaction ran; no checkpoint — re-derive from .wave/state.json in a fresh terminal (Invariant 7).")
    fi
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
