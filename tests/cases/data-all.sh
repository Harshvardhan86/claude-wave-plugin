#!/usr/bin/env bash
# tests/cases/data-all.sh — AC-339 through AC-353
# Verify all required data files exist and have correct structure

set -u

# shellcheck source=tests/lib/assert.sh
source "$(dirname "$0")/../lib/assert.sh"

cd "$(git rev-parse --show-toplevel)"

# Print run marker to the test harness log
name="${WV_CASE_NAME:-$(basename "$0" .sh)}"
if [ -n "${WV_CASE_LOG:-}" ]; then
  printf 'RAN %s %s decision=silent\n' "${BASH_SOURCE[0]}" "$name" >> "$WV_CASE_LOG"
fi

rc=0
fail() { printf '%s\n' "$*" >&2; rc=1; }

# Files that must exist
for f in hooks/phases.tsv hooks/models.tsv hooks/roles.tsv hooks/budgets.tsv \
         hooks/planning-paths.tsv hooks/orchestrator-writable.tsv hooks/reasons.tsv \
         tests/golden/phases-tiers.tsv tests/golden/budgets.tsv; do
  [ -f "$f" ] || fail "$f does not exist"
done

# AC-339: 12 columns, 26 full-mode rows
header=$(head -n1 hooks/phases.tsv)
expected_header="code	modes	when	condition	after	fanout	lead	executor	reviewer	artifact	marker	findings"
[ "$header" = "$expected_header" ] || fail "phases.tsv header mismatch"

full_count=$(command grep -v '^#' hooks/phases.tsv | awk -F'\t' '$2 ~ /full/ { print }' | wc -l)
[ "$full_count" = "26" ] || fail "phases.tsv should have 26 full-mode rows, got $full_count"

# Verify order of full-mode rows
expected_order="AC ACB DR TDE-RED TDE-GREEN CR BC BF-BC SEA BF-SEA DS BF-DS BSEA BF-BSEA OA TEET-TC TEET BF-TEET BTEET BTEET-X BF-BTEET VB COMMIT CL CCP AD"
actual_order=$(command grep -v '^#' hooks/phases.tsv | awk -F'\t' '$2 ~ /full/ { print $1 }' | tr '\n' ' ' | sed 's/ $//')
[ "$actual_order" = "$expected_order" ] || fail "full-mode rows in wrong order"

# AC-340: demo modes
demo_rows=$(command grep -v '^#' hooks/phases.tsv | awk -F'\t' '$2 ~ /demo/ { print $1 }' | tr '\n' ' ' | sed 's/ $//')
expected_demo="AC DR TDE-RED TDE-GREEN TEET"
[ "$demo_rows" = "$expected_demo" ] || fail "demo-mode rows should be: $expected_demo, got: $demo_rows"

# AC-341: condition column
dr_cond=$(awk -F'\t' '/^DR\t/ {print $4}' hooks/phases.tsv)
[ "$dr_cond" = "ui|behaviour_change" ] || fail "DR condition should be 'ui|behaviour_change', got '$dr_cond'"

cr_cond=$(awk -F'\t' '/^CR\t/ {print $4}' hooks/phases.tsv)
[ "$cr_cond" = "cr" ] || fail "CR condition should be 'cr', got '$cr_cond'"

# AC-342: when column
ad_when=$(awk -F'\t' '/^AD\t/ {print $3}' hooks/phases.tsv)
[ "$ad_when" = "anytime" ] || fail "AD when should be 'anytime', got '$ad_when'"

# AC-343: fanout column
for phase in TEET-TC TEET BTEET-X BC; do
  fanout=$(awk -F'\t' -v p="$phase" '$1==p {print $6}' hooks/phases.tsv)
  [ "$fanout" = "3" ] || fail "$phase fanout should be 3, got '$fanout'"
done

for phase in AC DR; do
  fanout=$(awk -F'\t' -v p="$phase" '$1==p {print $6}' hooks/phases.tsv)
  [ "$fanout" = "2" ] || fail "$phase fanout should be 2, got '$fanout'"
done

# AC-344: Tier cells (78 total)
cells=0
phases_rows=$(command grep -v '^#' hooks/phases.tsv | tail -n +2 | wc -l)
cells=$((phases_rows * 3))
[ "$cells" = "78" ] || fail "should have 78 tier cells, got $cells"

printf 'cells=%s\n' "$cells" >&2

# AC-348: models.tsv
haiku_rank=$(awk -F'\t' '/^haiku\t/ {print $2}' hooks/models.tsv)
[ "$haiku_rank" = "1" ] || fail "haiku should be rank 1"

# AC-350: budgets.tsv has 26 rows (one per phase)
budget_count=$(command grep -v '^#' hooks/budgets.tsv | tail -n +2 | wc -l)
[ "$budget_count" = "26" ] || fail "budgets.tsv should have 26 rows, got $budget_count"

# AC-351: planning-paths.tsv starts with .wave/**
first_path=$(head -n1 hooks/planning-paths.tsv)
[ "$first_path" = ".wave/**" ] || fail "first path should be .wave/**, got '$first_path'"

# AC-352: orchestrator-writable.tsv
has_readme=$(command grep -c '^README.md$' hooks/orchestrator-writable.tsv || echo 0)
[ "$has_readme" -gt 0 ] || fail "orchestrator-writable.tsv should contain README.md"

# AC-353: reasons.tsv has 31 rules
rule_count=$(command grep -v '^#' hooks/reasons.tsv | command grep -v '^rule_id' | wc -l)
[ "$rule_count" = "31" ] || fail "reasons.tsv should have 31 rules, got $rule_count"

exit $rc
