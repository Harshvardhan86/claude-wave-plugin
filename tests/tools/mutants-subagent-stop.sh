#!/usr/bin/env bash
# tests/tools/mutants-subagent-stop.sh [--keep]
#
# The mutation control for `scripts/hooks/subagent-stop.sh`: proves the
# stop/marker/taint/ledger/lock/lean suite is not vacuous by breaking one
# property of the hook at a time and requiring at least one case to go red for
# each. Same construction as tests/tools/mutants-pre-agent.sh and
# tests/tools/mutants-post-agent.sh (read either header first) — a mutant is
# applied to a COPY of the tree in a temp directory, never the working tree, with
# logs OUTSIDE the copied tree so the measurement cannot write into its own
# subject, and a `real` verdict strips pure rule-coverage FAIL lines
# (`no positive case` / `no negative control`) before deciding SURVIVED vs
# killed, because those fire on every narrow --filter regardless of the mutant
# and would otherwise manufacture a false `killed`.
#
# Eighteen mutants: the eight properties the task brief names, the seven the
# round-1 review added (its items 1-7 — the last two land in lib.sh, which is why
# a mutant now names its own target file), and the two Task 13 added with the
# bounded transcript settle and the enforce=warn conversion.
#   1. closingrole    the artifact check is applied to EVERY role's stop, not
#                     only the closing role's
#   2. lastoneout     the last-one-out predicate always says "last", so the
#                     first agent of a fan-out is judged on its siblings' work
#   3. blocktwice     the stop_hook_active guard is dropped, so the hook blocks
#                     again on the stop that follows its own block
#   4. markerloose    the marker regex is stripped of its ^ and $ anchors
#   5. taintinverted  the tier comparison is inverted
#   6. roundskey      the round counter is keyed on the role alone, not
#                     "<PHASE>/<role>"
#   7. drainremoved   the ledger spool is never drained on a stop that
#                     appends nothing of its own
#   8. terminalskip   the terminal-phase wave close is never called
#   9. blockoncekey   the block-once key is the stop_hook_active FLAG again
#                     rather than the `active[<id>].blocked` record
#  10. leanoneshot    the lean-return block stops being a one-shot
#  11. modesignored   the row's `modes` cell is ignored, so a demo wave judges a
#                     full-mode-only phase
#  12. stallquiet     a check skipped because a sibling is still running says
#                     nothing about it
#  13. warnedgrows    the phase's warn list is appended to on every replay
#  14. libtabcollapse lib.sh's hoisted row reader stops re-delimiting tabs to US
#  15. blockswallows  lib.sh's wv_block discards the queued warnings again
#  16. settleremoved  the bounded transcript settle is gone, so a SubagentStop
#                     that beats the transcript flush scores the agent as
#                     unverifiable
#  17. settlenoflag   reaching the settle cap is not recorded, so an
#                     unconfirmed read is indistinguishable from a verified one
#  18. warnviablock   enforce=warn falls back to lib.sh's wv_block warn path,
#                     which leaves the phase artifact-missing and appends a
#                     second, differently-shaped ledger line
#
# Exit status: 0 only when every mutant was applied, every mutant was killed,
# and the final restore matches the pristine hash.
#
#   bash tests/tools/mutants-subagent-stop.sh
#   bash tests/tools/mutants-subagent-stop.sh --keep   # keep the temp root
#
# Deliberately `set -u`, never `set -e`: a mutant whose run fails must reach the
# table rather than abort the sweep.

set -u

WV_TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WV_REPO_ROOT="$(cd "$WV_TOOLS_DIR/../.." && pwd)"
WV_KEEP=0
[ "${1:-}" = "--keep" ] && WV_KEEP=1

for tool in jq git python3; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'mutants-subagent-stop.sh: required tool not found on PATH: %s\n' "$tool" >&2
    exit 1
  fi
done

WV_TMP="$(mktemp -d "${TMPDIR:-/tmp}/wave-mutants-stop.XXXXXX")" || exit 1
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

for d in scripts hooks tests; do
  cp -a "$WV_REPO_ROOT/$d" "$WV_TREE/" || exit 1
done
git -C "$WV_TREE" init -q 2>/dev/null

# Two files can be mutated: this task's own hook, and the library it shares with
# every other hook. The phase-table readers and the block emitter live there
# since the round-1 review hoisted them, and a property that MOVED into lib.sh
# must be mutation-covered where it now lives, not where it used to — so a mutant
# names its own target file.
WV_HOOK_REL="scripts/hooks/subagent-stop.sh"
WV_LIB_REL="scripts/hooks/lib.sh"
WV_TARGET=""
WV_PRISTINE=""
WV_BASE_SHA=""

declare -A WV_PRISTINE_OF=()
declare -A WV_SHA_OF=()
for rel in "$WV_HOOK_REL" "$WV_LIB_REL"; do
  cp "$WV_TREE/$rel" "$WV_TMP/$(basename "$rel").pristine" || exit 1
  WV_PRISTINE_OF["$rel"]="$WV_TMP/$(basename "$rel").pristine"
  WV_SHA_OF["$rel"]="$(sha256sum < "$WV_TMP/$(basename "$rel").pristine" | cut -d' ' -f1)"
done

wv_select_target() {
  WV_TARGET="$WV_TREE/$1"
  WV_PRISTINE="${WV_PRISTINE_OF[$1]}"
  WV_BASE_SHA="${WV_SHA_OF[$1]}"
}

wv_restore() {
  cp "$WV_PRISTINE" "$WV_TARGET"
  # `cp` without -p, so the mutant's mtime cannot outlive it: a
  # timestamp-preserving restore is how a harness ends up testing the PREVIOUS
  # mutant's file.
  touch "$WV_TARGET"
  local now
  now="$(sha256sum < "$WV_TARGET" | cut -d' ' -f1)"
  if [ "$now" != "$WV_BASE_SHA" ]; then
    printf 'FATAL: restore failed (%s != %s)\n' "$now" "$WV_BASE_SHA" >&2
    exit 1
  fi
}

wv_build_patch() {
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
  # wv_run_mutant <label> <body-function> <target-relative-path> <filter>...
  local label="$1" body="$2" target="$3"
  shift 3
  wv_select_target "$target"
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

# --- 1. the artifact check runs at every role's stop ------------------------
wv_body_closingrole() { cat <<'PY'
old = '  if [ "$have_lock" = "1" ] && [ "$is_closing" = "1" ]; then'
new = '  if [ "$have_lock" = "1" ] && [ "$is_closing" != "zzz-never" ]; then'
assert old in s, "anchor missing: the closing-role guard"
s = s.replace(old, new)
PY
}

# --- 2. the last-one-out predicate always says "last" -----------------------
wv_body_lastoneout() { cat <<'PY'
old = '    if [ -z "$siblings" ]; then'
new = '    if [ -z "" ]; then'
assert old in s, "anchor missing: the last-one-out predicate"
s = s.replace(old, new)
PY
}

# --- 3. the stop_hook_active guard on the block path is dropped -------------
wv_body_blocktwice() { cat <<'PY'
old = '  if [ -n "$verdict_rule" ] && [ "$stop_active" = "false" ] \\\n    && [ "$verdict_blocked_before" = "0" ]; then'
new = '  if [ -n "$verdict_rule" ] && [ "0" = "0" ] \\\n    && [ "$verdict_blocked_before" = "0" ]; then'
assert old in s, "anchor missing: the stop_hook_active guard"
s = s.replace(old, new)
PY
}

# --- 4. the marker regex loses its anchors ---------------------------------
wv_body_markerloose() { cat <<'PY'
old = '          if wv_scan "$path" "$marker"; then'
new = '          if wv_scan "$path" "$(printf \'%s\' "$marker" | tr -d \'^$\')"; then'
assert old in s, "anchor missing: the marker scan"
s = s.replace(old, new)
PY
}

# --- 5. the tier comparison is inverted ------------------------------------
wv_body_taintinverted() { cat <<'PY'
old = '''        if [ "$WV_TS_TIER" -ge "$req_rank" ]; then'''
new = '''        if [ "$WV_TS_TIER" -lt "$req_rank" ]; then'''
assert old in s, "anchor missing: the tier comparison"
s = s.replace(old, new)
PY
}

# --- 6. the round counter is keyed on the role alone -----------------------
wv_body_roundskey() { cat <<'PY'
old = '''      key_lit="$(wv_jq_str "$WV_STOP_PHASE/$WV_STOP_ROLE")"'''
new = '''      key_lit="$(wv_jq_str "$WV_STOP_ROLE")"'''
assert old in s, "anchor missing: the rounds key"
s = s.replace(old, new)
PY
}

# --- 7. the ledger spool is never drained ---------------------------------
wv_body_drainremoved() { cat <<'PY'
old = '''    wv_ledger_drain_locked
'''
assert old in s, "anchor missing: the drain call"
s = s.replace(old, "", 1)
PY
}

# --- 8. the terminal-phase close is never called --------------------------
wv_body_terminalskip() { cat <<'PY'
old = '''  if [ "$status_new" = "done" ]; then
    wv_close_if_terminal "$WV_STOP_PHASE"
  fi'''
new = '''  if [ "$status_new" = "done" ] && false; then
    wv_close_if_terminal "$WV_STOP_PHASE"
  fi'''
assert old in s, "anchor missing: the terminal close"
s = s.replace(old, new)
PY
}

# --- 9. the block-once key is the FLAG again, not the record ----------------
wv_body_blockoncekey() { cat <<'PY'
old = '    && [ "$verdict_blocked_before" = "0" ]; then'
new = '    && [ "0" = "0" ]; then'
assert old in s, "anchor missing: the block-once record check"
s = s.replace(old, new)
PY
}

# --- 10. the lean-return block is not a one-shot ----------------------------
wv_body_leanoneshot() { cat <<'PY'
old = '        && [ "$WV_STOP_SEEN" = "0" ] && [ "$have_lock" = "1" ] \\\n        && [ "$lean_blocked_before" = "0" ]; then'
new = '        && [ "$WV_STOP_SEEN" = "0" ] && [ "$have_lock" = "1" ]; then'
assert old in s, "anchor missing: the lean one-shot condition"
s = s.replace(old, new)
PY
}

# --- 11. the row's `modes` cell is ignored ---------------------------------
wv_body_modesignored() { cat <<'PY'
old = '        case ",$row_modes," in\n          *",$WV_MODE,"*)'
new = '        case ",$row_modes,$WV_MODE" in\n          *)'
assert old in s, "anchor missing: the modes gate"
s = s.replace(old, new)
PY
}

# --- 12. a stalled sibling is skipped in silence ---------------------------
wv_body_stallquiet() { cat <<'PY'
old = '      wv_warn W-STATE "$WV_STOP_PHASE\'s closing role'
new = '      : "$WV_STOP_PHASE\'s closing role'
assert old in s, "anchor missing: the stalled-sibling warning"
s = s.replace(old, new)
PY
}

# --- 13. the warn list is appended to, not treated as a set ----------------
wv_body_warnedgrows() { cat <<'PY'
old = '      && [ "$warns_new" = "0" ]; then'
new = '      && [ "[]" = "[]" ]; then'
assert old in s, "anchor missing: the already-recorded-warning check"
s = s.replace(old, new)
old2 = ' | .warned = (((.warned // []) + %s) | unique) |'
new2 = ' | .warned = ((.warned // []) + %s) |'
assert old2 in s, "anchor missing: the unique warn merge"
s = s.replace(old2, new2)
PY
}

# --- 14. lib.sh: the hoisted row reader stops re-delimiting tabs to US -----
wv_body_libtabcollapse() { cat <<'PY'
old = '    rec="${line//$\'\\t\'/$\'\\x1f\'}"\n    code="${rec%%$\'\\x1f\'*}"'
new = '    rec="$line"\n    code="${rec%%$\'\\t\'*}"'
assert old in s, "anchor missing: lib.sh row reader"
s = s.replace(old, new)
PY
}

# --- 16. the bounded transcript settle is gone -----------------------------
wv_body_settleremoved() { cat <<'PY'
old = '''  wv_transcript_settle "$transcript"
'''
assert old in s, "anchor missing: the transcript settle call"
s = s.replace(old, "", 1)
PY
}

# --- 17. reaching the settle cap is not recorded ---------------------------
wv_body_settlenoflag() { cat <<'PY'
old = '  WV_TS_INCOMPLETE=1\n  wv_warn W-STATE'
new = '  WV_TS_INCOMPLETE=0\n  wv_warn W-STATE'
assert old in s, "anchor missing: the settle cap flag"
s = s.replace(old, new)
PY
}

# --- 18. enforce=warn falls back to lib.sh's wv_block warn path ------------
wv_body_warnviablock() { cat <<'PY'
old = '      elif [ "$WV_ENFORCE" = "warn" ]; then'
new = '      elif [ "zzz-never" = "warn" ]; then'
assert old in s, "anchor missing: the enforce=warn artifact conversion"
s = s.replace(old, new)
PY
}

# --- 15. lib.sh: a block discards the warnings it cannot carry -------------
wv_body_blockswallows() { cat <<'PY'
old = '  if [ -n "$WV_WARNINGS" ]; then\n    printf \'%s\\n\' "$WV_WARNINGS" >&2\n    WV_WARNINGS=""\n  fi\n  jq -nc'
new = '  WV_WARNINGS=""\n  jq -nc'
assert old in s, "anchor missing: the block warning flush"
s = s.replace(old, new)
PY
}

H="$WV_HOOK_REL"
L="$WV_LIB_REL"

wv_run_mutant closingrole    wv_body_closingrole    "$H" 'stop-229*' 'stop-228*'
wv_run_mutant lastoneout     wv_body_lastoneout     "$H" 'stop-228*'
wv_run_mutant blocktwice     wv_body_blocktwice     "$H" 'stop-231*'
wv_run_mutant markerloose    wv_body_markerloose    "$H" 'marker-*' 'stop-223*' 'stop-214*'
wv_run_mutant taintinverted  wv_body_taintinverted  "$H" 'taint-23*' 'taint-24*'
wv_run_mutant roundskey      wv_body_roundskey      "$H" 'stop-168*' 'stop-228*'
wv_run_mutant drainremoved   wv_body_drainremoved   "$H" 'lock-254*'
wv_run_mutant terminalskip   wv_body_terminalskip   "$H" 'stop-227*'
wv_run_mutant blockoncekey   wv_body_blockoncekey   "$H" 'stop-blockonce*' 'stop-231*'
wv_run_mutant leanoneshot    wv_body_leanoneshot    "$H" 'lean-oneshot*' 'lean-25*'
wv_run_mutant modesignored   wv_body_modesignored   "$H" 'stop-modes-demo*'
wv_run_mutant stallquiet     wv_body_stallquiet     "$H" 'stop-stalled*' 'stop-228*'
wv_run_mutant warnedgrows    wv_body_warnedgrows    "$H" 'taint-warned*' 'taint-240*'
wv_run_mutant libtabcollapse wv_body_libtabcollapse "$L" 'stop-220*' 'stop-227*'
wv_run_mutant blockswallows  wv_body_blockswallows  "$L" 'stop-warn-flush*' 'marker-204*' 'stop-214*'
wv_run_mutant settleremoved  wv_body_settleremoved  "$H" 'stop-181-*'
wv_run_mutant settlenoflag   wv_body_settlenoflag   "$H" 'stop-181-*' 'taint-243*'
wv_run_mutant warnviablock   wv_body_warnviablock   "$H" 'warn-mode-*'

# --- the table --------------------------------------------------------------

printf '\n%-15s %-11s %-33s %s\n' MUTANT VERDICT EFFECT 'FIRST CASE THAT CAUGHT IT'
printf '%s\n' '-----------------------------------------------------------------------------------------'
wv_row=""
for wv_row in "${wv_rows[@]:-}"; do
  [ -z "$wv_row" ] && continue
  IFS='|' read -r wv_label wv_verdict wv_effect wv_first <<<"$wv_row"
  printf '%-15s %-11s %-33s %s\n' "$wv_label" "$wv_verdict" "$wv_effect" "$wv_first"
done
printf '%s\n' '-----------------------------------------------------------------------------------------'

wv_restored=yes
for rel in "$WV_HOOK_REL" "$WV_LIB_REL"; do
  if [ "$(sha256sum < "$WV_TREE/$rel" | cut -d' ' -f1)" != "${WV_SHA_OF[$rel]}" ]; then
    printf 'NOT RESTORED: %s\n' "$rel" >&2
    wv_restored=NO
  fi
done
printf 'mutants=%s survived=%s restored=%s\n' "$wv_total" "$wv_survived" "$wv_restored"

[ "$wv_survived" -eq 0 ] && [ "$wv_restored" = "yes" ]
