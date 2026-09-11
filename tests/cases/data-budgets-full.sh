#!/usr/bin/env bash
# tests/cases/data-budgets-full.sh — AC-350 (finding 4, fix round 3)
#
# data-all.sh only checked the row count. This is the full AC: exactly one
# row per phases.tsv code (no unbudgeted phase, no orphan row), every value
# equals tests/golden/budgets.tsv, and every value is >= 500.
#
# The AC's final clause ("a first dispatch against an empty ledger emits no
# W-BUDGET") is a runtime claim about scripts/hooks/pre-agent.sh, which does
# not exist yet (a later task) — see the deferral note at the bottom.

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
BUDGETS=hooks/budgets.tsv
GOLDEN=tests/golden/budgets.tsv
for f in "$PHASES" "$BUDGETS" "$GOLDEN"; do
  [ -f "$f" ] || { fail "$f does not exist"; exit 1; }
done

declare -A phase_codes=()
while IFS= read -r c; do phase_codes["$c"]=1; done \
  < <(awk -F'\t' 'NR==1{next} /^#/{next} {print $1}' "$PHASES")

declare -A budget_val=()
while IFS=$'\t' read -r code tokens; do
  [ -z "$code" ] && continue
  case "$code" in '#'*|code) continue ;; esac
  if [ -n "${budget_val[$code]:-}" ]; then
    fail "budgets.tsv has more than one row for phase '$code' (orphan duplicate)"
  fi
  budget_val["$code"]="$tokens"
done < "$BUDGETS"

# no unbudgeted phase
for c in "${!phase_codes[@]}"; do
  [ -n "${budget_val[$c]:-}" ] || fail "phase '$c' has no row in budgets.tsv"
done
# no orphan row (a budget for a phase that doesn't exist)
for c in "${!budget_val[@]}"; do
  [ -n "${phase_codes[$c]:-}" ] || fail "budgets.tsv has an orphan row for '$c', which is not a phase in $PHASES"
done

# every value >= 500, and matches golden exactly
declare -A golden_val=()
while IFS=$'\t' read -r code tokens; do
  [ -z "$code" ] && continue
  case "$code" in '#'*|code) continue ;; esac
  golden_val["$code"]="$tokens"
done < "$GOLDEN"

for c in "${!budget_val[@]}"; do
  v="${budget_val[$c]}"
  case "$v" in
    ''|*[!0-9]*) fail "$c's budget '$v' is not a plain non-negative integer"; continue ;;
  esac
  [ "$v" -ge 500 ] || fail "$c's budget $v is below the 500 floor"
  g="${golden_val[$c]:-}"
  [ -n "$g" ] || fail "$c has no corresponding row in $GOLDEN"
  [ "$v" = "$g" ] || fail "$c's budget $v does not match golden $g"
done

row_count=$(command grep -v '^#' "$BUDGETS" | command grep -vc '^code')
[ "$row_count" = "26" ] || fail "budgets.tsv should have exactly 26 rows, got $row_count"

# Deferred: "a first dispatch against an empty ledger emits no W-BUDGET" is
# scripts/hooks/pre-agent.sh runtime behaviour; that script does not exist
# yet in this repo (only scripts/hooks/lib.sh does). This assertion cannot
# be exercised until that task lands, so it is not claimed here.

exit $rc
