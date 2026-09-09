#!/usr/bin/env bash
# tests/cases/data-after-dag.sh — AC-347 + the controller's SEA/DS/BSEA
# ruling (finding 5, fix round 3)
#
# The controller's ruling: SEA, DS, BSEA depend on BF-BC, BF-SEA, BF-DS
# respectively (not on the scans BC/SEA/DS), matching OA/BTEET, because
# findings are fixed before the next gate runs and a skipped conditional BF
# counts as done. Round 1/2 applied this to hooks/phases.tsv but nothing
# ever asserted it, and AC-347's full "after" contract (every predecessor
# exists, appears earlier, no cycle, shared predecessor sets, AD empty) had
# no test at all.

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

declare -a order=()
declare -A index=()
declare -A after=()   # code -> comma list (may be empty)

# code\tafter joined with 0x1f: `after` is empty for AC/AD, so a bash
# `read -r` with IFS=$'\t' would collapse it (see data-artifacts-markers.sh).
i=0
while IFS=$'\x1f' read -r code aft; do
  [ -n "$code" ] || continue
  order+=("$code")
  index["$code"]=$i
  after["$code"]="$aft"
  i=$((i + 1))
done < <(awk -F'\t' 'NR==1{next} /^#/{next} {print $1"\037"$5}' "$PHASES")

[ "${#order[@]}" = "26" ] || fail "expected 26 rows, got ${#order[@]}"

# ---- every `after` code exists and appears earlier in file order --------

for code in "${order[@]}"; do
  aft="${after[$code]}"
  [ -n "$aft" ] || continue
  IFS=',' read -ra preds <<< "$aft"
  for p in "${preds[@]}"; do
    if [ -z "${index[$p]+set}" ]; then
      fail "$code's after names '$p', which is not a row in $PHASES"
      continue
    fi
    if [ "${index[$p]}" -ge "${index[$code]}" ]; then
      fail "$code's predecessor '$p' does not appear earlier in file order"
    fi
  done
done

# ---- the controller ruling: SEA/DS/BSEA depend on the BF-* row, not the
# scan they wrap --------------------------------------------------------

[ "${after[SEA]:-}" = "BF-BC" ] || fail "SEA's after should be BF-BC (findings are fixed before the next gate), got '${after[SEA]:-}'"
[ "${after[DS]:-}" = "BF-SEA" ] || fail "DS's after should be BF-SEA, got '${after[DS]:-}'"
[ "${after[BSEA]:-}" = "BF-DS" ] || fail "BSEA's after should be BF-DS, got '${after[BSEA]:-}'"

# and this matches how OA/BTEET are already wired (waiting on the
# preceding BF-*, never the bare scan)
[ "${after[OA]:-}" = "BF-BSEA" ] || fail "sanity: OA's after should be BF-BSEA, got '${after[OA]:-}'"
[ "${after[BTEET]:-}" = "BF-TEET" ] || fail "sanity: BTEET's after should be BF-TEET, got '${after[BTEET]:-}'"

# ---- shared predecessor sets: VB/COMMIT/CL/CCP identical; AD empty ------

vb="${after[VB]:-}"; commit="${after[COMMIT]:-}"; cl="${after[CL]:-}"; ccp="${after[CCP]:-}"
[ -n "$vb" ] || fail "VB's after must not be empty"
for pair in "COMMIT:$commit" "CL:$cl" "CCP:$ccp"; do
  nm="${pair%%:*}"; val="${pair#*:}"
  [ "$val" = "$vb" ] || fail "$nm's after ('$val') should equal VB's ('$vb')"
done

[ -z "${after[AD]:-}" ] || fail "AD's after must be empty, got '${after[AD]}'"

# first row of each mode has empty predecessors after mode/condition
# skipping: the very first row of the file (AC) is the first row of BOTH
# modes (full and demo both start at AC), and AC's own `after` is empty.
[ "${order[0]}" = "AC" ] || fail "first row of the file should be AC, got '${order[0]}'"
[ -z "${after[AC]:-}" ] || fail "AC's after must be empty (it is the first row of both modes)"

# ---- acyclic: real DFS cycle detection over the after-graph, independent
# of the file-order check above -----------------------------------------

declare -A color=()   # 0=unvisited 1=in-progress 2=done
declare -a cycle_path=()
cycle_found=0

dfs() {
  local node="$1"
  color["$node"]=1
  cycle_path+=("$node")
  local aft="${after[$node]:-}"
  if [ -n "$aft" ]; then
    IFS=',' read -ra preds <<< "$aft"
    local p
    for p in "${preds[@]}"; do
      case "${color[$p]:-0}" in
        1)
          if [ "$cycle_found" = "0" ]; then
            fail "cycle detected: ${cycle_path[*]} -> $p"
            cycle_found=1
          fi
          return 1
          ;;
        0) dfs "$p" || return 1 ;;
      esac
    done
  fi
  color["$node"]=2
  cycle_path=("${cycle_path[@]:0:$((${#cycle_path[@]} - 1))}")
  return 0
}

for code in "${order[@]}"; do
  if [ "${color[$code]:-0}" = "0" ] && [ "$cycle_found" = "0" ]; then
    dfs "$code" || true
  fi
done

exit $rc
