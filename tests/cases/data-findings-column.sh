#!/usr/bin/env bash
# tests/cases/data-findings-column.sh — AC-346 (finding 4, fix round 3)
#
# BC, SEA, DS, BSEA, TEET, BTEET name their own code in the `findings`
# column; every other row is `-`; and every `findings:<CODE>` condition
# names a code whose row has a non-`-` findings entry (so no BF-* row is
# permanently unevaluable).

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
[ -f "$PHASES" ] || { fail "$PHASES does not exist"; exit 1; }

declare -A own_code=( [BC]=1 [SEA]=1 [DS]=1 [BSEA]=1 [TEET]=1 [BTEET]=1 )

# code\tfindings\tcondition, joined with 0x1f (never a tab — see
# data-artifacts-markers.sh for why a bash `read` with IFS=$'\t' cannot be
# trusted on phases.tsv's empty `after`/`condition` cells).
while IFS=$'\x1f' read -r code findings cond; do
  [ -n "$code" ] || continue
  if [ -n "${own_code[$code]:-}" ]; then
    [ "$findings" = "$code" ] || fail "$code should have findings='$code', got '$findings'"
  else
    [ "$findings" = "-" ] || fail "$code should have findings='-' (only BC/SEA/DS/BSEA/TEET/BTEET name themselves), got '$findings'"
  fi

  case "$cond" in
    findings:*)
      scan_code="${cond#findings:}"
      scan_findings="$(awk -F'\t' -v s="$scan_code" '$1==s{print $12}' "$PHASES")"
      if [ -z "$scan_findings" ]; then
        fail "$code's condition names scan '$scan_code' which has no row in phases.tsv"
      elif [ "$scan_findings" = "-" ]; then
        fail "$code's condition is findings:$scan_code, but $scan_code's own findings column is '-' — this BF-* row can never be evaluated"
      fi
      ;;
  esac
done < <(awk -F'\t' 'NR==1{next} /^#/{next} {print $1"\037"$12"\037"$4}' "$PHASES")

# sanity: exactly 6 rows name their own code
own_count=$(awk -F'\t' 'NR>1 && $1==$12{c++} END{print c+0}' "$PHASES")
[ "$own_count" = "6" ] || fail "expected exactly 6 rows with findings==code, got $own_count"

exit $rc
