#!/usr/bin/env bash
# tests/tools/mutants-pre-agent.sh [--keep]
#
# The mutation control for `scripts/hooks/pre-agent.sh`: proves the
# dispatch-identity suite is not vacuous by breaking one property of the hook
# at a time and requiring at least one case to go red for each.
#
# Every mutant is applied to a COPY of the tree in a temp directory, so the
# working tree is never touched and a killed run cannot leave a mutation behind
# (the failure mode that makes a mutation harness certify the previous mutant).
# The copy is taken from the CURRENT working tree, not from HEAD, because the
# point is to test the code as it stands. Logs live under the temp root's
# `logs/`, never inside the copied tree, so the measurement cannot write into
# its own subject.
#
# A mutant is `killed` when its filtered run reports at least one failure and
# `SURVIVED` when the run is green. A patch that leaves the file byte-identical
# is `NOT-APPLIED` and counts as a failure: a mutant that never applied is
# indistinguishable from one nothing caught. Each patch asserts its own anchor,
# so a refactor that moves the anchor is reported rather than silently skipped.
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

  local summary total failed first
  summary="$(command grep -m1 '^total=' "$log")"
  total="${summary#total=}"; total="${total%% *}"
  failed="${summary##*failed=}"
  first="$(command grep -m1 '^FAIL ' "$log" | cut -d' ' -f2 | tr -d ':')"

  case "$failed" in
    ''|0)
      wv_rows+=("$label|SURVIVED|${total:-?} cases ran, none red|-")
      wv_survived=$((wv_survived + 1))
      ;;
    *)
      wv_rows+=("$label|killed|$failed of ${total:-?} red|${first:-?}")
      ;;
  esac
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
old = '    executor|scanner|writer) cell="$WV_ROW_EXECUTOR" ;;'
new = '    executor) cell="$WV_ROW_EXECUTOR" ;;\n    scanner|writer) cell="$WV_ROW_LEAD" ;;'
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

wv_run_mutant offbyone     wv_body_offbyone     'tier-*' 'model-13*'
wv_run_mutant anchor       wv_body_anchor       'tag-*'
wv_run_mutant nested       wv_body_nested       'nested-*'
wv_run_mutant solo         wv_body_solo         'solo-dispatch-*'
wv_run_mutant alias        wv_body_alias        'tier-113*' 'tier-114*'
wv_run_mutant tabcollapse  wv_body_tabcollapse  'tier-*' 'role-*' 'mode-*'
wv_run_mutant fork         wv_body_fork         'fork-*'
wv_run_mutant waveid       wv_body_waveid       'tag-02*'
wv_run_mutant unknowndeny  wv_body_unknowndeny  'model-12*'
wv_run_mutant neutralise   wv_body_neutralise   '*-token-*'
wv_run_mutant eventguard   wv_body_eventguard   'tag-event-*'

# --- the table ------------------------------------------------------------

printf '\n%-13s %-11s %-33s %s\n' MUTANT VERDICT EFFECT 'FIRST CASE THAT CAUGHT IT'
printf '%s\n' '-----------------------------------------------------------------------------------------'
wv_row=""
for wv_row in "${wv_rows[@]:-}"; do
  [ -z "$wv_row" ] && continue
  IFS='|' read -r wv_label wv_verdict wv_effect wv_first <<<"$wv_row"
  printf '%-13s %-11s %-33s %s\n' "$wv_label" "$wv_verdict" "$wv_effect" "$wv_first"
done
printf '%s\n' '-----------------------------------------------------------------------------------------'

wv_final="$(sha256sum < "$WV_TARGET" | cut -d' ' -f1)"
if [ "$wv_final" = "$WV_BASE_SHA" ]; then wv_restored=yes; else wv_restored=NO; fi
printf 'mutants=%s survived=%s restored=%s\n' "$wv_total" "$wv_survived" "$wv_restored"

[ "$wv_survived" -eq 0 ] && [ "$wv_restored" = "yes" ]
