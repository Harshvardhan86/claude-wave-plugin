#!/usr/bin/env bash
# tests/cases/data-artifacts-markers.sh — AC-345 (finding 4, fix round 3)
#
# Compares hooks/phases.tsv `artifact` and `marker` columns against the
# spec section 6 hand-off table, cell by cell, for all 26 rows. Round 1/2's
# report claimed this AC passed but no case ever asserted it.

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

# code -> "artifact\tmarker", transcribed verbatim from
# docs/design/2026-09-09-hook-enforcement.md §6's hand-off table.
declare -A expect_artifact=(
  [AC]='.wave/ac.md'
  [ACB]='.wave/acb.md'
  [DR]='.wave/dr.md'
  [TDE-RED]='.wave/red.md'
  [TDE-GREEN]='.wave/green.md'
  [CR]='.wave/cr.md'
  [BC]='.wave/findings/BC.md'
  [BF-BC]='.wave/bf-BC.md'
  [SEA]='.wave/findings/SEA.md'
  [BF-SEA]='.wave/bf-SEA.md'
  [DS]='.wave/findings/DS.md'
  [BF-DS]='.wave/bf-DS.md'
  [BSEA]='.wave/findings/BSEA.md'
  [BF-BSEA]='.wave/bf-BSEA.md'
  [OA]='.wave/oa.md'
  [TEET-TC]='.wave/teet-tc.md'
  [TEET]='.wave/teet.md'
  [BF-TEET]='.wave/bf-TEET.md'
  [BTEET]='.wave/bteet.md'
  [BTEET-X]='.wave/bteet-x.md'
  [BF-BTEET]='.wave/bf-BTEET.md'
  [VB]='-'
  [COMMIT]='-'
  [CL]='-'
  [CCP]='.wave/checkpoints/*-ccp.md'
  [AD]='-'
)

declare -A expect_marker=(
  [AC]='^AC-[0-9]+'
  [ACB]='^ACB-VERIFIED'
  [DR]='^DR-VERIFIED'
  [TDE-RED]='^RED-VERIFIED failing=[1-9][0-9]*$'
  [TDE-GREEN]='^GREEN-VERIFIED passing=[1-9][0-9]* failing=0$'
  [CR]='^CR-VERIFIED'
  [BC]='^FINDINGS: [0-9]+$'
  [BF-BC]='^BF-VERIFIED'
  [SEA]='^FINDINGS: [0-9]+$'
  [BF-SEA]='^BF-VERIFIED'
  [DS]='^FINDINGS: [0-9]+$'
  [BF-DS]='^BF-VERIFIED'
  [BSEA]='^FINDINGS: [0-9]+$'
  [BF-BSEA]='^BF-VERIFIED'
  [OA]='^ALIGNMENT: [0-9]+%$'
  [TEET-TC]='^TEET-TC-VERIFIED$'
  [TEET]='^TEET-VERIFIED$'
  [BF-TEET]='^BF-VERIFIED'
  [BTEET]='^BTEET-VERIFIED$'
  [BTEET-X]='^BTEET-X-VERIFIED$'
  [BF-BTEET]='^BF-VERIFIED'
  [VB]='-'
  [COMMIT]='-'
  [CL]='-'
  [CCP]='exists'
  [AD]='-'
)

# diff_handoff <phases-file> -> non-empty on any mismatch
#
# NOTE: this deliberately does NOT do `IFS=$'\t' read -r a b c ... < file`.
# Tab is one of bash's default IFS *whitespace* characters, so `read` still
# collapses adjacent tab delimiters even when IFS is set to nothing but a
# tab — exactly the trap scripts/hooks/lib.sh documents at wv_parse_stdin
# ("tab is IFS whitespace, so IFS=$'\t' read collapses two adjacent tabs
# into one delimiter"). phases.tsv's `after` column is empty for AC/AD, so
# a naive `read` shifts every later column left by one on those two rows.
# awk -F'\t' does not collapse empty fields; re-join with 0x1f (never a
# tab) before handing fields to bash, same workaround lib.sh uses.
diff_handoff() {
  local phases="$1"
  local line code artifact marker
  while IFS=$'\x1f' read -r code artifact marker; do
    [ -n "$code" ] || continue
    [ -n "${expect_artifact[$code]:-}" ] || { echo "$code: not in expected table"; continue; }
    if [ "$artifact" != "${expect_artifact[$code]}" ]; then
      echo "$code artifact: '$artifact' != '${expect_artifact[$code]}'"
    fi
    if [ "$marker" != "${expect_marker[$code]}" ]; then
      echo "$code marker: '$marker' != '${expect_marker[$code]}'"
    fi
  done < <(awk -F'\t' 'NR==1{next} /^#/{next} {print $1"\037"$10"\037"$11}' "$phases")
}

diffs="$(diff_handoff "$PHASES")"
if [ -n "$diffs" ]; then
  fail "artifact/marker mismatch(es):"
  while IFS= read -r line; do fail "  $line"; done <<< "$diffs"
fi

row_count=$(command grep -vc '^#' "$PHASES")
row_count=$((row_count - 1))
[ "$row_count" = "26" ] || fail "expected 26 phase rows, got $row_count"
[ "${#expect_artifact[@]}" = "26" ] || fail "expected table itself should list 26 codes, has ${#expect_artifact[@]}"

# ---- mutation proof: corrupt one artifact/marker cell in a temp copy ----

tmp_phases="$(mktemp "${TMPDIR:-/tmp}/phases-am-mutated.XXXXXX.tsv")"
trap 'rm -f "$tmp_phases"' EXIT

# BC's marker is ^FINDINGS: [0-9]+$; corrupt it to a marker that would never
# match a real findings file.
awk -F'\t' 'BEGIN{OFS="\t"} $1=="BC"{$11="^NOT-A-REAL-MARKER$"} {print}' "$PHASES" > "$tmp_phases"

mutated_diff="$(diff_handoff "$tmp_phases")"
if [ -z "$mutated_diff" ]; then
  fail "MUTATION PROOF FAILED: corrupting BC's marker was not caught — the artifact/marker comparison is vacuous"
else
  case "$mutated_diff" in
    *"BC marker:"*) : ;;
    *) fail "mutation proof caught something, but not the expected cell: $mutated_diff" ;;
  esac
fi

diffs2="$(diff_handoff "$PHASES")"
[ -z "$diffs2" ] || fail "real phases.tsv unexpectedly differs after mutation proof: $diffs2"

exit $rc
