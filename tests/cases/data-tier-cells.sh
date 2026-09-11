#!/usr/bin/env bash
# tests/cases/data-tier-cells.sh — AC-344 (finding 4, fix round 3)
#
# data-all.sh's AC-344 check only counted 78 cells; it never compared a
# single cell's VALUE against tests/golden/phases-tiers.tsv, so it could not
# fail on a wrong tier. This test does the real cell-by-cell diff, and
# proves the diff is non-vacuous by mutating a temp copy of phases.tsv (one
# tier cell lowered) and showing the comparison catches it.

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

PHASES=hooks/phases.tsv
GOLDEN=tests/golden/phases-tiers.tsv
[ -f "$PHASES" ] || { fail "$PHASES does not exist"; exit 1; }
[ -f "$GOLDEN" ] || { fail "$GOLDEN does not exist"; exit 1; }

# diff_tiers <phases-file> <golden-file> -> prints one "phase col: got != want"
# line per mismatching cell; empty output means all 78 cells match.
diff_tiers() {
  local phases="$1" golden="$2"
  awk -F'\t' '
    FNR==NR {
      if (FNR==1) { next }
      lead[$1]=$7; exe[$1]=$8; rev[$1]=$9
      next
    }
    /^#/ { next }
    FNR==1 { next }
    {
      p=$1
      if (!(p in lead)) { print p": row absent from phases.tsv"; next }
      if (lead[p] != $2) print p" lead: "lead[p]" != "$2
      if (exe[p]  != $3) print p" executor: "exe[p]" != "$3
      if (rev[p]  != $4) print p" reviewer: "rev[p]" != "$4
    }
  ' "$phases" "$golden"
}

diffs="$(diff_tiers "$PHASES" "$GOLDEN")"
if [ -n "$diffs" ]; then
  fail "tier cell mismatch(es):"
  fail "$diffs"
fi

# cell count sanity (kept from the original check)
cells=$(( $(command grep -vc '^#' "$PHASES") - 1 ))
cells=$(( cells * 3 ))
[ "$cells" = "78" ] || fail "should have 78 tier cells, got $cells"
printf 'cells=%s\n' "$cells" >&2

# ---- mutation proof: lower one tier cell in a temp copy, show the diff
# catches it (finding 4: "do this for at least one tier cell") -----------

tmp_phases="$(mktemp "${TMPDIR:-/tmp}/phases-mutated.XXXXXX.tsv")"
trap 'rm -f "$tmp_phases"' EXIT

# ACB executor is `opus` (100%-Opus hardening phase); lower it to `sonnet`.
awk -F'\t' 'BEGIN{OFS="\t"} $1=="ACB"{$8="sonnet"} {print}' "$PHASES" > "$tmp_phases"

mutated_diff="$(diff_tiers "$tmp_phases" "$GOLDEN")"
if [ -z "$mutated_diff" ]; then
  fail "MUTATION PROOF FAILED: lowering ACB's executor cell to sonnet was not caught — the tier comparison is vacuous"
else
  case "$mutated_diff" in
    *"ACB executor: sonnet != opus"*) : ;;
    *) fail "mutation proof caught something, but not the expected cell: $mutated_diff" ;;
  esac
fi

# and the unmutated real file must still be clean (no self-inflicted false
# positive from the mutation harness)
diffs2="$(diff_tiers "$PHASES" "$GOLDEN")"
[ -z "$diffs2" ] || fail "real phases.tsv unexpectedly differs from golden after mutation proof: $diffs2"

exit $rc
