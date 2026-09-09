#!/usr/bin/env bash
# tests/cases/data-planning-paths.sh — AC-351 (finding 1, fix round 3)
#
# hooks/planning-paths.tsv is glob<TAB>label. This golden test proves, in
# both directions, that every row matches the fixture(s) it was written for
# and does NOT match any near-miss fixture — including the AC-296 false-deny
# corpus for an over-broad substring pattern (e.g. "docs/wave*" incorrectly
# catching "docs/waveform.ts").
#
# Matching uses bash's own `[[ path == pattern ]]` glob semantics (no
# extglob): `*` matches any string including "/", so ".wave/**" and
# "analysis/**" behave the same as ".wave/*" and "analysis/*" here — this is
# the same primitive scripts/hooks/pre-commit-guard.sh (not built yet) will
# use to walk hooks/planning-paths.tsv without hardcoding patterns in a
# shell `case`.

set -u

# shellcheck source=tests/lib/assert.sh
source "$(dirname "$0")/../lib/assert.sh"

cd "$(git rev-parse --show-toplevel)"

name="${WV_CASE_NAME:-$(basename "$0" .sh)}"
if [ -n "${WV_CASE_LOG:-}" ]; then
  printf 'RAN %s %s decision=silent\n' "${BASH_SOURCE[0]}" "$name" >> "$WV_CASE_LOG"
fi

rc=0
fail() { printf '%s\n' "$*" >&2; rc=1; }

TSV=hooks/planning-paths.tsv
FIXDIR=tests/fixtures/planning-paths

[ -f "$TSV" ] || { fail "$TSV does not exist"; exit 1; }

# matches <path> <glob> -> 0 if path matches glob, 1 otherwise.
matches() {
  local path="$1" glob="$2"
  # shellcheck disable=SC2053
  [[ "$path" == $glob ]]
}

# ---- load rows -------------------------------------------------------

declare -a row_globs=()
declare -a row_labels=()
while IFS=$'\t' read -r glob label; do
  [ -z "$glob" ] && continue
  case "$glob" in '#'*) continue ;; esac
  row_globs+=("$glob")
  row_labels+=("$label")
done < "$TSV"

# AC-351: exactly the .wave/** row comes first, and every row has a
# non-empty label (two columns, per the Interfaces contract).
[ "${row_globs[0]:-}" = ".wave/**" ] || fail "first row's glob must be .wave/**, got '${row_globs[0]:-}'"
for i in "${!row_globs[@]}"; do
  [ -n "${row_labels[$i]:-}" ] || fail "row $i (${row_globs[$i]}) has no label"
done

# ---- discover fixtures under tests/fixtures/planning-paths ------------

[ -d "$FIXDIR/positive" ] || fail "$FIXDIR/positive does not exist"
[ -d "$FIXDIR/near-miss" ] || fail "$FIXDIR/near-miss does not exist"

# label -> logical path being tested (strip $FIXDIR/positive/<label>/ prefix)
declare -a pos_labels=()
declare -a pos_paths=()
while IFS= read -r f; do
  rel="${f#"$FIXDIR"/positive/}"
  label="${rel%%/*}"
  logical="${rel#"$label"/}"
  pos_labels+=("$label")
  pos_paths+=("$logical")
done < <(find "$FIXDIR/positive" -type f | sort)

declare -a neg_labels=()
declare -a neg_paths=()
while IFS= read -r f; do
  rel="${f#"$FIXDIR"/near-miss/}"
  label="${rel%%/*}"
  logical="${rel#"$label"/}"
  neg_labels+=("$label")
  neg_paths+=("$logical")
done < <(find "$FIXDIR/near-miss" -type f | sort)

[ "${#pos_paths[@]}" -gt 0 ] || fail "no positive fixtures found under $FIXDIR/positive"
[ "${#neg_paths[@]}" -gt 0 ] || fail "no near-miss fixtures found under $FIXDIR/near-miss"

# every_row_matches <path> -> prints the label of the FIRST row that
# matches, or nothing.
first_matching_row() {
  local path="$1" i
  for i in "${!row_globs[@]}"; do
    if matches "$path" "${row_globs[$i]}"; then
      printf '%s' "${row_labels[$i]}"
      return 0
    fi
  done
  return 1
}

# ---- direction 1: every positive fixture matches its own row's glob ---

covered_labels=""
for i in "${!pos_paths[@]}"; do
  label="${pos_labels[$i]}"
  path="${pos_paths[$i]}"
  # the fixture's own directory names the row it must match
  found_idx=-1
  for j in "${!row_labels[@]}"; do
    [ "${row_labels[$j]}" = "$label" ] && found_idx=$j
  done
  if [ "$found_idx" = "-1" ]; then
    fail "positive fixture $path is filed under unknown label '$label' (no such row in $TSV)"
    continue
  fi
  if ! matches "$path" "${row_globs[$found_idx]}"; then
    fail "positive fixture '$path' does NOT match its own row's glob '${row_globs[$found_idx]}' (label $label)"
  fi
  covered_labels="$covered_labels $label"
done

# every row has at least one positive fixture (AC-351)
for label in "${row_labels[@]}"; do
  case " $covered_labels " in
    *" $label "*) ;;
    *) fail "row '$label' has no positive fixture under $FIXDIR/positive" ;;
  esac
done

# ---- direction 2: no near-miss fixture matches ANY row ----------------

for i in "${!neg_paths[@]}"; do
  label="${neg_labels[$i]}"
  path="${neg_paths[$i]}"
  hit="$(first_matching_row "$path" || true)"
  if [ -n "$hit" ]; then
    fail "near-miss fixture '$path' (filed under $label) incorrectly matches row '$hit' — over-broad pattern"
  fi
done

# every row has at least one near-miss fixture filed under its own label
# (AC-351: "at least one positive fixture and one near-miss fixture")
neg_covered=""
for label in "${neg_labels[@]}"; do
  neg_covered="$neg_covered $label"
done
for label in "${row_labels[@]}"; do
  case " $neg_covered " in
    *" $label "*) ;;
    *) fail "row '$label' has no near-miss fixture under $FIXDIR/near-miss" ;;
  esac
done

# ---- direction 3: the exact AC-292..296 corpus, independent of fixture
# filing, straight from the AC text -------------------------------------

declare -a ac_positive=(
  ".wave/state.json"
  ".wave/ledger.jsonl"
  "tasks/todo.md"
  "analysis/x.md"
  "docs/wave3-design-review.md"
  "docs/plan-a.md"
  ".claude/plans/p.md"
  "notes.plan.md"
)
for p in "${ac_positive[@]}"; do
  first_matching_row "$p" >/dev/null || fail "AC-292..296 positive path '$p' matches no row in $TSV"
done

declare -a ac_negative=(
  "src/app.ts"
  "src/analysis/service.ts"
  "metrics_analysis/README.md"
  "docs/waveform.ts"
  "docs/planner.ts"
  "plan.md.snap"
  "tasks.json"
  "docs/design/2026-09-09-hook-enforcement.md"
)
for p in "${ac_negative[@]}"; do
  hit="$(first_matching_row "$p" || true)"
  if [ -n "$hit" ]; then
    fail "AC-296 negative-control path '$p' incorrectly matches row '$hit'"
  fi
done

exit $rc
