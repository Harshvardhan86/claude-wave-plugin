#!/usr/bin/env bash
# tests/cases/data-models-full.sh — AC-348 (finding 4, fix round 3)
#
# data-all.sh only ever checked haiku->1. This is the full AC: the exact
# tier ranks for all four models, opusplan/default declared unknown, the
# fable-assumption note present, and nothing else in the file.

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

TSV=hooks/models.tsv
[ -f "$TSV" ] || { fail "$TSV does not exist"; exit 1; }

declare -A expect=( [haiku]=1 [sonnet]=2 [opus]=3 [fable]=4 [opusplan]=unknown [default]=unknown )
declare -A actual=()

while IFS=$'\t' read -r token rank; do
  [ -z "$token" ] && continue
  case "$token" in '#'*|token) continue ;; esac
  actual["$token"]="$rank"
done < "$TSV"

for token in "${!expect[@]}"; do
  want="${expect[$token]}"
  got="${actual[$token]:-}"
  if [ -z "$got" ]; then
    fail "models.tsv has no row for '$token'"
  elif [ "$got" != "$want" ]; then
    fail "models.tsv maps '$token' -> '$got', expected '$want'"
  fi
done

# "holds nothing else": exact row set, exact row count
for token in "${!actual[@]}"; do
  [ -n "${expect[$token]:-}" ] || fail "models.tsv has an unexpected token '$token'"
done
row_count=$(command grep -v '^#' "$TSV" | command grep -vc '^token')
[ "$row_count" = "6" ] || fail "models.tsv should have exactly 6 data rows, got $row_count"

# the fable-assumption note: a comment recording it is not a measured claim.
command grep -q '^#.*fable' "$TSV" || fail "models.tsv is missing a comment noting fable's rank is an assumption"
command grep -qi 'assumption' "$TSV" || fail "models.tsv's fable comment must say it is an assumption, not a measured claim"

exit $rc
