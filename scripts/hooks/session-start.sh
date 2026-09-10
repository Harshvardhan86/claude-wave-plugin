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

# THE BOUND ON ANY ONE RENDERED REASON, tests/tools/reason-corpus.sh's
# WV_MAX_REASON. It is the number this file spends against, and it is the number the
# gate measures, so it is named here rather than folded into a derived constant.
WV_SESSION_MAX_REASON=400
#
# The "(+N more)" tail wv_list_cap appends when it drops an item, plus the separator
# in front of it. wv_list_cap appends that tail PAST its character budget (an item it
# admitted is never retracted to make room for the tail), so a caller that must not
# exceed a hard total has to reserve it. There are only ever two clauses here, so the
# tail is always "(+1 more)" — 9 characters, plus one space.
WV_SESSION_TAIL_RESERVE=10
#
# THE FALLBACK CAP: what is left of the 400 after every other term in this banner is
# at its longest, DERIVED term by term from values that are themselves bounded. It is
# no longer the budget the ordinary case is measured against — that is computed at run
# time in wv_main below, from the banner actually being rendered — but it is what this
# file falls back to if the measured render still will not fit, which is the one case
# a run-time measurement cannot rescue (a state.json carrying a longer id than
# wave-init.sh will create: hand-edited, or written by an older version).
#
# The figure before this one was derived from the same terms except that the wave id
# was not bounded at all, so a 40-character id rendered 458 and a 24-character one 405:
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
# WHY THIS IS ONLY THE FALLBACK. Every term above is at its MAXIMUM at once, and an
# ordinary wave is nowhere near it: a wave with the id `1`, enforce=block and `AC` as
# its last done phase renders 185 characters before `extra`, so 214 are free and the
# constant hands it 109. Measured, that dropped the Invariant-7 advisory behind
# "(+1 more)" on a 244-character banner — both clauses render at 329 — and the clause
# it dropped is the one naming the checkpoint to re-read, at the exact moment
# (post-compaction, deep into a long wave) that advisory exists to be read. The
# constant is a bound on the WORST case being used as the budget for EVERY case; the
# 400 is the invariant, and it is measurable, so wv_main measures it.
# session-327e-short-id-stale-checkpoint is the ordinary wave, session-327c the
# longest accepted input, session-327d the collision where the cap still binds.
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

  # THE ADVISORY CLAUSES, collected and then BOUNDED BY MEASUREMENT.
  #
  # This banner is a template plus an `extra` assembled at run time, and `extra`
  # grew with the situation: two clauses at once, one of them carrying a filename
  # of any length, pushed the rendered reason to 440 characters against a
  # 400-character bound — and it did so with no commit to blame, because the
  # second clause only appears once real time passes 24h after the wave started.
  # So the clauses are short, they are collected into a list, and the list is
  # capped (lib.sh's wv_list_cap, which truncates rather than exempting a long
  # item).
  #
  # WHAT IT IS CAPPED AT IS MEASURED, NOT ASSUMED. The budget is what the 400 has
  # left after the banner ACTUALLY BEING RENDERED — this wave's id, mode, enforce
  # clause and last done phase — is accounted for, which is one wv_render of the same
  # template with an empty `extra`. A worst-case constant is the wrong instrument for
  # this job even when it is correctly derived: it is right about the maximum and
  # wrong about every input below it, and being wrong here means silently discarding
  # an advisory that fits (measured: 244 characters rendered, 155 unspent, the
  # Invariant-7 clause behind "(+1 more)").
  #
  # tests/cases/session-327c-max-banner is the fixture that puts every term at its
  # maximum at once so the corpus measures this reason's real maximum (378 of 400),
  # session-327d is the collision where the cap still binds, and
  # session-327e-short-id-stale-checkpoint is the ordinary wave where it must not.
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
    # The banner with NOTHING appended: the same template, the same arguments, an
    # empty `extra`. wv_rule_warn rewrites `W-` to `W_` inside its arguments and this
    # does not, which cannot change a LENGTH (two characters either way), and length
    # is all this render is read for.
    local base budget
    base="$(wv_render W-SESSION "$WV_WAVE" "$WV_MODE" "$enforce_clause" "$last_done" "$WV_WAVE" "")"
    budget=$(( WV_SESSION_MAX_REASON - ${#base} - 1 ))   # -1: the space before `extra`
    [ "$budget" -ge 0 ] || budget=0

    extra=" $(wv_list_cap "${#clauses[@]}" "$budget" ' ' "${clauses[@]}")"
    if [ $(( ${#base} + ${#extra} )) -gt "$WV_SESSION_MAX_REASON" ]; then
      # The cap bound, and wv_list_cap's "(+N more)" tail is appended PAST the budget
      # it was given. Spend again with that tail reserved — the clause that survives
      # is still the first one, so this changes the length and not the priority.
      extra=" $(wv_list_cap "${#clauses[@]}" "$(( budget - WV_SESSION_TAIL_RESERVE ))" ' ' "${clauses[@]}")"
    fi

    # THE ≤400 INVARIANT, ASSERTED RATHER THAN ARGUED. If the measured budget still
    # cannot hold this banner, the run-time measurement has nothing left to give: the
    # template plus this wave's own arguments is already at or past the bound, which a
    # state.json carrying an id longer than wave-init.sh will create can do. Fall back
    # to the worst-case constant — the behaviour that shipped — so an unbounded id
    # renders the same over-long banner it always did, rather than a NEW shape derived
    # from a negative budget. It is a fallback, not a fix: no render-time truncation
    # here would make that state legal, and wave-init.sh is where the id is bounded.
    if [ $(( ${#base} + ${#extra} )) -gt "$WV_SESSION_MAX_REASON" ]; then
      extra=" $(wv_list_cap "${#clauses[@]}" "$WV_SESSION_EXTRA_MAX" ' ' "${clauses[@]}")"
    fi
  fi

  wv_rule_warn W-SESSION "$WV_WAVE" "$WV_MODE" "$enforce_clause" "$last_done" "$WV_WAVE" "$extra"
  return 0
}

wv_main
wv_emit_flush
exit 0
