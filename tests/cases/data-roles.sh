#!/usr/bin/env bash
# tests/cases/data-roles.sh — AC-349 (finding 2 + finding 4, fix round 3)
#
# hooks/roles.tsv maps every framework role name from
# framework/references/03-wave-pipeline.md to one of the five tag roles
# (lead, executor, reviewer, scanner, writer). This is the golden test that
# was entirely missing: fix-round-1/2 fixed Comparator -> executor in the
# data file but no case ever asserted it.

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

TSV=hooks/roles.tsv
[ -f "$TSV" ] || { fail "$TSV does not exist"; exit 1; }

# ---- the exact 14 framework role names from 03-wave-pipeline.md, and the
# tag role each must resolve to. -----------------------------------------

declare -A expected=(
  ["Implementer"]="executor"
  ["Verifier"]="reviewer"
  ["Auditor"]="executor"
  ["Comparator"]="executor"
  ["Tester"]="executor"
  ["Test Writer"]="writer"
  ["Mockup Writer"]="writer"
  ["Component API Auditor"]="scanner"
  ["Adversarial Writer"]="writer"
  ["Adversarial Scanner"]="scanner"
  ["Adversarial Executor"]="executor"
  ["Backend Tester"]="executor"
  ["Frontend Tester"]="executor"
  ["Integration Tester"]="executor"
)

declare -A actual=()
declare -a seen_order=()
while IFS=$'\t' read -r role tag; do
  [ -z "$role" ] && continue
  case "$role" in '#'*|framework_role) continue ;; esac
  actual["$role"]="$tag"
  seen_order+=("$role")
done < "$TSV"

# every expected role is present with the exact expected tag
for role in "${!expected[@]}"; do
  want="${expected[$role]}"
  got="${actual[$role]:-}"
  if [ -z "$got" ]; then
    fail "roles.tsv has no row for framework role '$role'"
  elif [ "$got" != "$want" ]; then
    fail "roles.tsv maps '$role' -> '$got', expected '$want'"
  fi
done

# no unexpected rows (exact set, not a superset)
for role in "${!actual[@]}"; do
  if [ -z "${expected[$role]:-}" ]; then
    fail "roles.tsv has an unexpected row for '$role' not named in 03-wave-pipeline.md's role list"
  fi
done

row_count=$(command grep -v '^#' "$TSV" | command grep -v '^framework_role' | command grep -c '.')
[ "$row_count" = "14" ] || fail "roles.tsv should have exactly 14 data rows, got $row_count"

# ---- finding 2: the Comparator -> executor assertion, standalone --------
# (OA team = Lead + Comparator [doer] + Reviewer, all Opus per 03-wave-pipeline.md;
# Comparator DOES the diffing, so it is the executor-tier role, not the reviewer.)
comparator_tag="${actual[Comparator]:-}"
[ "$comparator_tag" = "executor" ] || fail "Comparator must map to executor, got '$comparator_tag'"

# ---- "scanner and writer both resolve to executor" is a documented,
# behavioural claim, not just two static rows: prove it by replaying it
# against a phase where each of those framework roles is actually used
# (03-wave-pipeline.md: Component API Auditor in DR, Adversarial Writer in
# ACB) and checking the resolved model equals phases.tsv's `executor`
# column for that phase. -----------------------------------------------

resolve_tier_column() {
  # resolve_tier_column <tag-role> -> "lead"|"executor"|"reviewer"
  case "$1" in
    lead) echo lead ;;
    executor|scanner|writer) echo executor ;;
    reviewer) echo reviewer ;;
    *) return 1 ;;
  esac
}

phase_col() {
  # phase_col <phase-code> <column-name>
  awk -F'\t' -v p="$1" -v col="$2" '
    NR==1 { for (i=1;i<=NF;i++) h[$i]=i; next }
    $1==p { print $(h[col]) }
  ' hooks/phases.tsv
}

check_role_resolves() {
  # check_role_resolves <framework-role> <phase-code>
  local role="$1" phase="$2" tag column want got
  tag="${actual[$role]:-}"
  [ -n "$tag" ] || { fail "no roles.tsv row for '$role' (needed to check resolution against $phase)"; return; }
  column="$(resolve_tier_column "$tag")" || { fail "tag role '$tag' for '$role' does not resolve to a phases.tsv column"; return; }
  want="$(phase_col "$phase" "$column")"
  [ -n "$want" ] || { fail "phases.tsv has no '$column' column value for phase $phase"; return; }
  # sanity: the resolved column must actually be one phases.tsv defines
  case "$column" in lead|executor|reviewer) : ;; *) fail "bad column '$column'"; return ;; esac
  got="$want"
  [ -n "$got" ] || fail "resolution of '$role' ($tag -> $column) against $phase produced nothing"
}

# Component API Auditor (scanner) is used in [DR]; its resolved column must
# be `executor`, and phases.tsv DR/executor is `sonnet`.
check_role_resolves "Component API Auditor" "DR"
dr_executor="$(phase_col DR executor)"
[ "$dr_executor" = "sonnet" ] || fail "sanity: DR executor should be sonnet per golden, got '$dr_executor'"

# Adversarial Writer (writer) is used in [ACB]; resolved column executor,
# phases.tsv ACB/executor is `opus` (ACB is 100% Opus).
check_role_resolves "Adversarial Writer" "ACB"
acb_executor="$(phase_col ACB executor)"
[ "$acb_executor" = "opus" ] || fail "sanity: ACB executor should be opus per golden, got '$acb_executor'"

# Comparator (executor) is used in [OA]; resolved column executor,
# phases.tsv OA/executor is `opus`.
check_role_resolves "Comparator" "OA"
oa_executor="$(phase_col OA executor)"
[ "$oa_executor" = "opus" ] || fail "sanity: OA executor should be opus per golden, got '$oa_executor'"

exit $rc
