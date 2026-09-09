#!/usr/bin/env bash
# tests/tools/mutants-pre-agent.sh [--keep]
#
# The mutation control for `scripts/hooks/pre-agent.sh`: proves the suite is not
# vacuous by breaking one property of the hook at a time and requiring at least
# one case to go red for each. Mutants 1-11 cover part 1 (dispatch identity);
# 12-26 cover part 2 (order, conditions, scope, the dispatch-time gates, the
# round ceiling, the budget and the prompt caps), with at least one mutant per
# rule id part 2 owns so a deleted deny has somewhere to surface. 26 is the
# fix-round-1 finding: an unanswered scope flag folded back into `false`.
#
# Every mutant is applied to a COPY of the tree in a temp directory, so the
# working tree is never touched and a killed run cannot leave a mutation behind
# (the failure mode that makes a mutation harness certify the previous mutant).
# The copy is taken from the CURRENT working tree, not from HEAD, because the
# point is to test the code as it stands. Logs live under the temp root's
# `logs/`, never inside the copied tree, so the measurement cannot write into
# its own subject.
#
# A mutant is `killed` when its filtered run reports at least one REAL failure
# and `SURVIVED` when the run is green. A patch that leaves the file
# byte-identical is `NOT-APPLIED` and counts as a failure: a mutant that never
# applied is indistinguishable from one nothing caught. Each patch asserts its
# own anchor, so a refactor that moves the anchor is reported rather than
# silently skipped.
#
# "REAL" is load-bearing. `tests/run.sh` fails a case when its rule id has a
# positive case but no negative control, and under a narrow --filter the negative
# control routinely lives outside the filter. That FAIL says nothing about the
# mutation, and counting it manufactured a `killed` verdict for a mutant that
# nothing had actually caught (measured: the paste-threshold mutant, whose only
# red was this artefact while the boundary case it was supposed to red passed).
# So a FAIL line whose whole reason is coverage text is stripped out before the
# verdict, and the EFFECT column reports how many were discarded — a mutant that
# survives behind an artefact now says SURVIVED, loudly.
#
# Exit status: 0 only when every mutant was applied, every mutant was killed,
# and the final restore matches the pristine hash.
#
#   bash tests/tools/mutants-pre-agent.sh
#   bash tests/tools/mutants-pre-agent.sh --keep   # leave the temp root behind
#
# Deliberately `set -u`, never `set -e`: a mutant whose run fails must reach
# the table rather than abort the sweep.

set -u

WV_TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WV_REPO_ROOT="$(cd "$WV_TOOLS_DIR/../.." && pwd)"
WV_KEEP=0
[ "${1:-}" = "--keep" ] && WV_KEEP=1

for tool in jq git python3; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'mutants-pre-agent.sh: required tool not found on PATH: %s\n' "$tool" >&2
    exit 1
  fi
done

WV_TMP="$(mktemp -d "${TMPDIR:-/tmp}/wave-mutants.XXXXXX")" || exit 1
WV_TREE="$WV_TMP/tree"
WV_LOGS="$WV_TMP/logs"
mkdir -p "$WV_TREE" "$WV_LOGS" || exit 1

cleanup() {
  if [ "$WV_KEEP" = "1" ]; then
    printf 'temp root kept at %s\n' "$WV_TMP"
  else
    rm -rf "$WV_TMP"
  fi
}
trap cleanup EXIT

# Everything the filtered suite reads: the hook scripts, the data files and the
# harness. `git init` in the copy keeps the cases that ask git for a toplevel
# happy; .git itself is deliberately not copied.
for d in scripts hooks tests; do
  cp -a "$WV_REPO_ROOT/$d" "$WV_TREE/" || exit 1
done
git -C "$WV_TREE" init -q 2>/dev/null

WV_TARGET="$WV_TREE/scripts/hooks/pre-agent.sh"
WV_PRISTINE="$WV_TMP/pre-agent.pristine.sh"
cp "$WV_TARGET" "$WV_PRISTINE" || exit 1
WV_BASE_SHA="$(sha256sum < "$WV_PRISTINE" | cut -d' ' -f1)"

wv_restore() {
  cp "$WV_PRISTINE" "$WV_TARGET"
  local now
  now="$(sha256sum < "$WV_TARGET" | cut -d' ' -f1)"
  if [ "$now" != "$WV_BASE_SHA" ]; then
    printf 'FATAL: restore failed (%s != %s)\n' "$now" "$WV_BASE_SHA" >&2
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# Each mutant is a function that writes the BODY of a python patch to stdout:
# `s` holds the script's text, and whatever the body leaves in `s` is written
# back. The prelude and epilogue are added here, so a mutant is only its
# anchor, its replacement and its assertion.
# ---------------------------------------------------------------------------

wv_build_patch() {
  # wv_build_patch <label> <body-function> -> the patch script's path
  local label="$1" body="$2"
  local f="$WV_LOGS/$label.py"
  {
    printf '%s\n' 'import sys' 'p = sys.argv[1]' 's = open(p).read()'
    "$body"
    printf '%s\n' 'open(p, "w").write(s)'
  } > "$f"
  printf '%s' "$f"
}

wv_total=0
wv_survived=0
declare -a wv_rows=()

wv_run_mutant() {
  # wv_run_mutant <label> <body-function> <filter>...
  local label="$1" body="$2"
  shift 2
  wv_total=$((wv_total + 1))

  local patch
  patch="$(wv_build_patch "$label" "$body")"
  if ! python3 "$patch" "$WV_TARGET" 2>"$WV_LOGS/$label.patch.err"; then
    wv_rows+=("$label|NOT-APPLIED|$(tr '\n' ' ' < "$WV_LOGS/$label.patch.err" | tail -c 40)|-")
    wv_survived=$((wv_survived + 1))
    wv_restore
    return
  fi
  local mut_sha
  mut_sha="$(sha256sum < "$WV_TARGET" | cut -d' ' -f1)"
  if [ "$mut_sha" = "$WV_BASE_SHA" ]; then
    wv_rows+=("$label|NOT-APPLIED|patch changed nothing (hash unchanged)|-")
    wv_survived=$((wv_survived + 1))
    wv_restore
    return
  fi

  local -a args=()
  local f
  for f in "$@"; do args+=(--filter "$f"); done
  local log="$WV_LOGS/$label.log"
  ( cd "$WV_TREE" && bash tests/run.sh "${args[@]}" ) > "$log" 2>&1

  local summary total
  summary="$(command grep -m1 '^total=' "$log")"
  total="${summary#total=}"; total="${total%% *}"

  # Split the FAIL lines into real assertion diffs and pure coverage artefacts.
  # A line reading `FAIL <case>: rule W-X: no negative control` (only that) is
  # the harness telling us the filter is narrow, not the suite catching a mutant.
  local real=0 artefact=0 first="" fl stripped
  while IFS= read -r fl; do
    [ -n "$fl" ] || continue
    stripped="$(printf '%s' "$fl" | sed -E \
      's/rule W-[A-Z0-9-]+: (no positive case|no negative control)(,(no positive case|no negative control))*;?[[:space:]]*//g')"
    case "$stripped" in
      'FAIL '*': '|'FAIL '*':')
        artefact=$((artefact + 1))
        ;;
      *)
        real=$((real + 1))
        [ -n "$first" ] || first="$(printf '%s' "$fl" | cut -d' ' -f2 | tr -d ':')"
        ;;
    esac
  done < <(command grep '^FAIL ' "$log")

  local note=""
  [ "$artefact" -gt 0 ] && note=" (+$artefact coverage artefact(s) ignored)"

  if [ "$real" -eq 0 ]; then
    wv_rows+=("$label|SURVIVED|${total:-?} cases ran, none red$note|-")
    wv_survived=$((wv_survived + 1))
  else
    wv_rows+=("$label|killed|$real of ${total:-?} red$note|${first:-?}")
  fi
  wv_restore
}

# --- 1. the tier comparison is off by one ----------------------------------
wv_body_offbyone() { cat <<'PY'
old = 'if [ "$requested" -lt "$need_rank" ]; then'
new = 'if [ "$requested" -le "$need_rank" ]; then'
assert old in s, "anchor missing: the tier comparison"
s = s.replace(old, new)
PY
}

# --- 2. the tag grammar loses its byte-0 anchor ----------------------------
wv_body_anchor() { cat <<'PY'
old = "WV_TAG_RE='^\\[W:"
new = "WV_TAG_RE='\\[W:"
assert old in s, "anchor missing: WV_TAG_RE"
s = s.replace(old, new)
PY
}

# --- 3. the nested-dispatch deny is removed --------------------------------
wv_body_nested() { cat <<'PY'
old = """  if [ -n "$WV_AGENT_ID" ]; then
    wv_rule_deny W-NESTED "$WV_AGENT_ID"
    return 0
  fi"""
assert old in s, "anchor missing: the nested branch"
s = s.replace(old, "  :")
PY
}

# --- 4. the solo bypass is removed ----------------------------------------
wv_body_solo() { cat <<'PY'
old = """  case "$WV_MODE" in
    full|demo) : ;;
    *) wv_solo_rules; return 0 ;;
  esac"""
assert old in s, "anchor missing: the mode switch"
s = s.replace(old, "  :")
PY
}

# --- 5. scanner/writer resolve to the lead column -------------------------
wv_body_alias() { cat <<'PY'
old = '    executor|scanner|writer) cell="$exe" ;;'
new = '    executor) cell="$exe" ;;\n    scanner|writer) cell="$lead" ;;'
assert old in s, "anchor missing: the role column map"
s = s.replace(old, new)
PY
}

# --- 6. the TSV reader stops re-delimiting tabs to US ---------------------
wv_body_tabcollapse() { cat <<'PY'
old = """    rec="${line//$'\\t'/$'\\x1f'}"
    IFS=$'\\x1f' read -r"""
new = """    rec="$line"
    IFS=$'\\t' read -r"""
assert old in s, "anchor missing: the TSV re-delimiting"
s = s.replace(old, new)
PY
}

# --- 7. the fork deny is removed ------------------------------------------
wv_body_fork() { cat <<'PY'
old = """  if [ "$WV_SUBAGENT" = "fork" ]; then
    wv_rule_deny W-FORK
    return 0
  fi"""
assert old in s, "anchor missing: the fork branch"
s = s.replace(old, "  :")
PY
}

# --- 8. the wave id is coerced instead of compared byte for byte -----------
wv_body_waveid() { cat <<'PY'
old = '  if [ "$WV_TAG_WAVE" != "$WV_WAVE" ]; then'
new = '  if [ "${WV_TAG_WAVE#0}" != "$WV_WAVE" ]; then'
assert old in s, "anchor missing: the wave comparison"
s = s.replace(old, new)
PY
}

# --- 9. an unreadable model denies instead of warning ---------------------
wv_body_unknowndeny() { cat <<'PY'
old = '    wv_rule_warn W-MODEL-UNKNOWN'
new = '    wv_rule_deny W-MODEL-UNKNOWN'
assert old in s, "anchor missing: the unknown-model warning"
s = s.replace(old, new)
PY
}

# --- 10. the W- neutralisation is dropped (AC-389) ------------------------
wv_body_neutralise() { cat <<'PY'
old = '    args+=("${arg//W-/W_}")'
new = '    args+=("$arg")'
assert old in s, "anchor missing: the W- neutralisation"
assert s.count(old) == 2, "expected the substitution in both emit wrappers"
s = s.replace(old, new)
PY
}

# --- 11. the hook_event_name guard is dropped -----------------------------
wv_body_eventguard() { cat <<'PY'
old = '  [ "$WV_EVENT" = "PreToolUse" ] || return 0\n'
assert old in s, "anchor missing: the event guard"
s = s.replace(old, "")
PY
}

# --- part 2: order, conditions, scope, the gates, rounds, budgets ----------
#
# One mutant per property part 2 adds, and one per rule id it owns, so a rule
# whose deny is deleted has somewhere to show up. The filters are deliberately
# narrow: the point of each row is "at least one case notices", and a mutant
# that has to run 300 cases to prove it takes minutes to say so.

# --- 12. the order check is removed entirely ------------------------------
wv_body_orderremoved() { cat <<'PY'
old = """    wv_after_unmet "$WV_TAG_PHASE" >/dev/null
    case "$?" in
      1)
        wv_rule_deny W-ORDER "$WV_UNMET" "$WV_TAG_PHASE" "$WV_ORDER_DETAIL"
        return 0
        ;;
      2)
        wv_rule_deny "$WV_COND_RULE" "${WV_COND_ARGS[@]}"
        return 0
        ;;
    esac"""
assert old in s, "anchor missing: the W-ORDER branch"
s = s.replace(old, "    :")
PY
}

# --- 13. the findings condition is inverted -------------------------------
wv_body_condinverted() { cat <<'PY'
old = '      [ "$count" -ge 1 ] && return 0'
new = '      [ "$count" -lt 1 ] && return 0'
assert old in s, "anchor missing: the findings-count comparison"
s = s.replace(old, new)
PY
}

# --- 14. the skip rule is removed: a false condition no longer counts as done
wv_body_skiprule() { cat <<'PY'
old = '    1) WV_PHASE_DONE_WHY="condition"; return 0 ;;'
new = '    1) return 1 ;;'
assert old in s, "anchor missing: the condition arm of wv_phase_done"
s = s.replace(old, new)
PY
}

# --- 15. the order walk stops at a skipped row instead of looking through it
wv_body_ordernottransitive() { cat <<'PY'
old = """          *)
            wv_after_unmet_walk "$p"
            [ "$?" = "2" ] && return 2
            continue
            ;;"""
new = """          *) continue ;;"""
assert old in s, "anchor missing: the skipped-row recursion"
s = s.replace(old, new)
PY
}

# --- 16. the round ceiling is off by one ----------------------------------
wv_body_roundoffbyone() { cat <<'PY'
old = '  [ "$n" -ge 2 ] || return 0'
new = '  [ "$n" -ge 3 ] || return 0'
assert old in s, "anchor missing: the round ceiling comparison"
s = s.replace(old, new)
PY
}

# --- 17. the budget 2x boundary stops being strictly greater ---------------
wv_body_budget2x() { cat <<'PY'
old = '  if [ "$spent" -gt $(( limit * 2 )) ]; then'
new = '  if [ "$spent" -ge $(( limit * 2 )) ]; then'
assert old in s, "anchor missing: the budget deny boundary"
s = s.replace(old, new)
PY
}

# --- 18. the 8,000-character prompt cap stops being strictly greater -------
wv_body_promptcap() { cat <<'PY'
old = '  elif [ "$WV_PROMPT_LEN" -gt 8000 ]; then'
new = '  elif [ "$WV_PROMPT_LEN" -ge 8000 ]; then'
assert old in s, "anchor missing: the 8000-character prompt cap"
s = s.replace(old, new)
PY
}

# --- 19. the scope gate is removed ----------------------------------------
wv_body_scoperemoved() { cat <<'PY'
old = """  if [ "$WV_TAG_PHASE" = "TDE-RED" ] && ! wv_scope_ready; then
    wv_rule_deny W-SCOPE "$WV_SCOPE_FLAG" "$WV_SCOPE_ARG"
    return 0
  fi"""
assert old in s, "anchor missing: the W-SCOPE branch"
s = s.replace(old, "  :")
PY
}

# --- 20. the visual-approval gate is never called -------------------------
wv_body_visualremoved() { cat <<'PY'
old = '  wv_visual_gate || return 0'
assert old in s, "anchor missing: the wv_visual_gate call"
s = s.replace(old, "  :")
PY
}

# --- 21. the bug-fix approval gate is never called ------------------------
wv_body_bfremoved() { cat <<'PY'
old = '  wv_bf_approval_gate || return 0'
assert old in s, "anchor missing: the wv_bf_approval_gate call"
s = s.replace(old, "  :")
PY
}

# --- 22. dr.md's fenced blocks are no longer stripped ---------------------
wv_body_drfence() { cat <<'PY'
old = 'stripped="$(command awk \'/^```/ { fence = !fence; next } !fence\' "$file" 2>/dev/null)"'
new = 'stripped="$(cat "$file" 2>/dev/null)"'
assert old in s, "anchor missing: the dr.md fence stripping"
s = s.replace(old, new)
PY
}

# --- 23. the pasted-block threshold drops below 4,000 ---------------------
# Both halves of one threshold: the awk that measures the block and the shell
# check that acts on it. Changing either alone is invisible, because the other
# still filters the result — which is itself worth knowing.
wv_body_pastethreshold() { cat <<'PY'
old_awk = 'min = 4000; seed = 2000'
new_awk = 'min = 3000; seed = 1500'
old_sh = '    [ "$len" -ge 4000 ] || continue'
new_sh = '    [ "$len" -ge 3000 ] || continue'
assert old_awk in s, "anchor missing: the awk paste threshold"
assert old_sh in s, "anchor missing: the shell paste threshold"
s = s.replace(old_awk, new_awk).replace(old_sh, new_sh)
PY
}

# --- 24. a findings file a done phase never wrote is treated as pending ----
wv_body_artifactpending() { cat <<'PY'
old = """        if [ "$(wv_state_phase_status "$src")" = "done" ]; then
          WV_COND_RULE=W-ARTIFACT
          WV_COND_ARGS=("$rel" "$src" "$rel")
          return 2
        fi"""
assert old in s, "anchor missing: the W-ARTIFACT branch"
s = s.replace(old, "        :")
PY
}

# --- 26. an unanswered scope flag is folded back into `false` --------------
# The fix-round-1 defect, as a mutant: both condition arms stop consulting
# wv_unanswered_scope, so `unknown` reads as `false` again. A DR or CR dispatch
# is then denied W-COND carrying a statement nobody made, and an unanswered
# condition on a predecessor is silently skipped through to its successor.
wv_body_unknownisfalse() { cat <<'PY'
old_ui = '      wv_unanswered_scope "$WV_UI" ui "$WV_BC" behaviour_change && return 2\n'
old_cr = '      wv_unanswered_scope "$WV_CR" cr_enabled && return 2\n'
assert old_ui in s, "anchor missing: the ui|behaviour_change unanswered check"
assert old_cr in s, "anchor missing: the cr unanswered check"
s = s.replace(old_ui, "").replace(old_cr, "")
PY
}

# --- 25. a findings file with no marker line is accepted ------------------
wv_body_markerignored() { cat <<'PY'
old = '  [ "$n" != "0" ] || return 2'
new = '  [ "$n" != "0" ] || return 0'
assert old in s, "anchor missing: the findings marker check"
s = s.replace(old, new)
PY
}

wv_run_mutant offbyone     wv_body_offbyone     'tier-*' 'model-13*'
wv_run_mutant anchor       wv_body_anchor       'tag-*'
wv_run_mutant nested       wv_body_nested       'nested-*'
wv_run_mutant solo         wv_body_solo         'solo-dispatch-*' 'model-121*'
wv_run_mutant alias        wv_body_alias        'tier-113*' 'tier-114*'
wv_run_mutant tabcollapse  wv_body_tabcollapse  'tier-*' 'role-*' 'mode-*'
wv_run_mutant fork         wv_body_fork         'fork-*'
wv_run_mutant waveid       wv_body_waveid       'tag-02*'
wv_run_mutant unknowndeny  wv_body_unknowndeny  'model-12*'
wv_run_mutant neutralise   wv_body_neutralise   '*-token-*'
wv_run_mutant eventguard   wv_body_eventguard   'tag-event-*'

wv_run_mutant orderremoved      wv_body_orderremoved      'order-07*'
wv_run_mutant condinverted      wv_body_condinverted      'cond-*' 'order-074b*'
wv_run_mutant skiprule          wv_body_skiprule          'order-071*' 'order-077*' 'order-081*'
wv_run_mutant ordernottrans     wv_body_ordernottransitive 'order-078*' 'order-105*' 'order-071*'
wv_run_mutant roundoffbyone     wv_body_roundoffbyone     'round-161*' 'round-162*'
wv_run_mutant budget2x          wv_body_budget2x          'budget-174*' 'budget-171*'
wv_run_mutant promptcap         wv_body_promptcap         'prompt-182*'
# 'scope-1*', not 'scope-10*': the narrower glob never matched scope-110, this
# rule's own negative control, so every run of this mutant produced coverage
# artefacts alongside its real red. Widening it also exercises the interaction
# with fix round 1 — for `ui` and `behaviour_change` the condition arm now denies
# the same W-SCOPE independently of this gate, so scope-109 (cr_enabled, which no
# condition in TDE-RED's predecessor set consults) is what uniquely pins it.
wv_run_mutant scoperemoved      wv_body_scoperemoved      'scope-1*'
wv_run_mutant visualremoved     wv_body_visualremoved     'gate-153*' 'gate-154*' 'gate-156*'
wv_run_mutant bfremoved         wv_body_bfremoved         'gate-157*' 'gate-158*'
wv_run_mutant drfence           wv_body_drfence           'gate-150*'
wv_run_mutant pastethreshold    wv_body_pastethreshold    'paste-*' 'prompt-182*'
wv_run_mutant artifactpending   wv_body_artifactpending   'gate-083*' 'gate-160b*'
wv_run_mutant markerignored     wv_body_markerignored     'gate-083b*' 'gate-160*'
wv_run_mutant unknownisfalse    wv_body_unknownisfalse    'scope-11*' 'order-071*' 'order-074b*'

# --- the table ------------------------------------------------------------

printf '\n%-17s %-11s %-33s %s\n' MUTANT VERDICT EFFECT 'FIRST CASE THAT CAUGHT IT'
printf '%s\n' '-----------------------------------------------------------------------------------------'
wv_row=""
for wv_row in "${wv_rows[@]:-}"; do
  [ -z "$wv_row" ] && continue
  IFS='|' read -r wv_label wv_verdict wv_effect wv_first <<<"$wv_row"
  printf '%-17s %-11s %-33s %s\n' "$wv_label" "$wv_verdict" "$wv_effect" "$wv_first"
done
printf '%s\n' '-----------------------------------------------------------------------------------------'

wv_final="$(sha256sum < "$WV_TARGET" | cut -d' ' -f1)"
if [ "$wv_final" = "$WV_BASE_SHA" ]; then wv_restored=yes; else wv_restored=NO; fi
printf 'mutants=%s survived=%s restored=%s\n' "$wv_total" "$wv_survived" "$wv_restored"

[ "$wv_survived" -eq 0 ] && [ "$wv_restored" = "yes" ]
