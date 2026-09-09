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
# Eight mutants, one per property the task brief names explicitly:
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

WV_TARGET="$WV_TREE/scripts/hooks/subagent-stop.sh"
WV_PRISTINE="$WV_TMP/subagent-stop.pristine.sh"
cp "$WV_TARGET" "$WV_PRISTINE" || exit 1
WV_BASE_SHA="$(sha256sum < "$WV_PRISTINE" | cut -d' ' -f1)"

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
old = '''  if [ "$have_lock" = "1" ] && [ "$is_closing" = "1" ] \\
    && [ "$(wv_still_running "$WV_STOP_PHASE")" = "0" ]; then'''
new = '''  if [ "$have_lock" = "1" ] && [ "$is_closing" != "zzz-never" ] \\
    && [ "$(wv_still_running "$WV_STOP_PHASE")" = "0" ]; then'''
assert old in s, "anchor missing: the closing-role guard"
s = s.replace(old, new)
PY
}

# --- 2. the last-one-out predicate always says "last" -----------------------
wv_body_lastoneout() { cat <<'PY'
old = '''    && [ "$(wv_still_running "$WV_STOP_PHASE")" = "0" ]; then'''
new = '''    && [ "0" = "0" ]; then'''
assert old in s, "anchor missing: the last-one-out predicate"
s = s.replace(old, new)
PY
}

# --- 3. the stop_hook_active guard on the block path is dropped -------------
wv_body_blocktwice() { cat <<'PY'
old = '''    if [ "$stop_active" = "false" ]; then
      wv_stop_block "$verdict_rule" "${verdict_args[@]}"
    fi'''
new = '''    if [ "$stop_active" = "false" ] || true; then
      wv_stop_block "$verdict_rule" "${verdict_args[@]}"
    fi'''
assert old in s, "anchor missing: the stop_hook_active guard"
s = s.replace(old, new)
PY
}

# --- 4. the marker regex loses its anchors ---------------------------------
wv_body_markerloose() { cat <<'PY'
old = '''          if n="$(wv_scan_count "$path" "$marker")"; then'''
new = '''          if n="$(wv_scan_count "$path" "$(printf '%s' "$marker" | tr -d '^$')")"; then'''
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

wv_run_mutant closingrole   wv_body_closingrole   'stop-229*' 'stop-228*'
wv_run_mutant lastoneout    wv_body_lastoneout    'stop-228*'
wv_run_mutant blocktwice    wv_body_blocktwice    'stop-231*'
wv_run_mutant markerloose   wv_body_markerloose   'marker-*' 'stop-223*'
wv_run_mutant taintinverted wv_body_taintinverted 'taint-23*' 'taint-24*'
wv_run_mutant roundskey     wv_body_roundskey     'stop-168*' 'stop-228*'
wv_run_mutant drainremoved  wv_body_drainremoved  'lock-254*'
wv_run_mutant terminalskip  wv_body_terminalskip  'stop-227*'

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

wv_final="$(sha256sum < "$WV_TARGET" | cut -d' ' -f1)"
if [ "$wv_final" = "$WV_BASE_SHA" ]; then wv_restored=yes; else wv_restored=NO; fi
printf 'mutants=%s survived=%s restored=%s\n' "$wv_total" "$wv_survived" "$wv_restored"

[ "$wv_survived" -eq 0 ] && [ "$wv_restored" = "yes" ]
