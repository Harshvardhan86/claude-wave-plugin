#!/usr/bin/env bash
# tests/tools/mutants-tier-cells.sh [--keep]
#
# AC-146: the mutation control that makes AC-344's cell-by-cell tier comparison
# non-vacuous. The phase table has 78 (phase, role) cells — 26 rows x
# {lead, executor, reviewer}. AC-344 proves the shipped table MATCHES
# tests/golden/phases-tiers.tsv; it cannot prove that any given cell is actually
# ENFORCED. A cell nothing exercises is a minimum the plugin claims and does not
# hold, and no amount of table-vs-golden agreement would show it.
#
# So: one cell at a time, in a disposable copy of the tree, the cell is moved by
# exactly one tier in BOTH hooks/phases.tsv and tests/golden/phases-tiers.tsv,
# and the cases for that cell alone are re-run. Mutating both files together is
# deliberate — mutating only the table would red tests/cases/data-tier-cells.sh
# for every cell, which is the table-vs-golden check firing, not the tier rule
# being enforced, and would manufacture 60 false kills.
#
# DIRECTION. A cell above the floor is LOWERED by one tier: the model its
# `*-deny` case names is now acceptable, so that case must stop denying. The two
# cells already at the floor (`haiku`) cannot be lowered, so they are RAISED by
# one instead: the model their `*-allow` case names is now below the minimum, so
# that case must start denying. Either way the mutation changes the verdict of a
# case that names the cell, which is the whole claim.
#
# KILL CRITERION. A red is only counted when the red case's NAME belongs to this
# cell (`tier-<phase>-<role>-*`). A filter-level "something in this run went red"
# would also be satisfied by a coverage artefact or by a neighbouring cell's
# case, and a mutant credited to the wrong case is a mutant that has not been
# shown to be covered at all.
#
# A `-` cell is reported N/A: the phase has no such role, there is no minimum to
# enforce, and there is nothing to lower. Those are counted and printed so the
# 78 are all accounted for, never silently dropped.
#
# Exit status: 0 only when every non-`-` cell was mutated, every mutation was
# applied, every one was killed by one of its own cases, and both files restored
# to their pristine hashes.
#
#   bash tests/tools/mutants-tier-cells.sh
#   bash tests/tools/mutants-tier-cells.sh --keep    # keep the temp root
#
# Deliberately `set -u`, never `set -e`: a cell whose run fails must reach the
# table rather than abort the sweep.

set -u

WV_TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WV_REPO_ROOT="$(cd "$WV_TOOLS_DIR/../.." && pwd)"
WV_KEEP=0
[ "${1:-}" = "--keep" ] && WV_KEEP=1

for tool in jq git python3; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'mutants-tier-cells.sh: required tool not found on PATH: %s\n' "$tool" >&2
    exit 1
  fi
done

WV_TMP="$(mktemp -d "${TMPDIR:-/tmp}/wave-mutants-cells.XXXXXX")" || exit 1
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

for d in scripts hooks tests; do
  cp -a "$WV_REPO_ROOT/$d" "$WV_TREE/" || exit 1
done
git -C "$WV_TREE" init -q 2>/dev/null

WV_PHASES_REL="hooks/phases.tsv"
WV_GOLDEN_REL="tests/golden/phases-tiers.tsv"

declare -A WV_PRISTINE_OF=()
declare -A WV_SHA_OF=()
for rel in "$WV_PHASES_REL" "$WV_GOLDEN_REL"; do
  cp "$WV_TREE/$rel" "$WV_TMP/$(basename "$rel").pristine" || exit 1
  WV_PRISTINE_OF["$rel"]="$WV_TMP/$(basename "$rel").pristine"
  WV_SHA_OF["$rel"]="$(sha256sum < "$WV_TMP/$(basename "$rel").pristine" | cut -d' ' -f1)"
done

wv_restore_all() {
  local rel now
  for rel in "$WV_PHASES_REL" "$WV_GOLDEN_REL"; do
    cp "${WV_PRISTINE_OF[$rel]}" "$WV_TREE/$rel"
    # `cp` without -p, then `touch`: a timestamp-preserving restore is how a
    # harness ends up measuring the PREVIOUS mutant.
    touch "$WV_TREE/$rel"
    now="$(sha256sum < "$WV_TREE/$rel" | cut -d' ' -f1)"
    if [ "$now" != "${WV_SHA_OF[$rel]}" ]; then
      printf 'FATAL: restore failed for %s (%s != %s)\n' "$rel" "$now" "${WV_SHA_OF[$rel]}" >&2
      exit 1
    fi
  done
}

# ---- the tier ladder, read from hooks/models.tsv, never restated -----------
#
# The ladder that decides what "one tier lower" means is data, exactly like the
# table it moves; a hand-written copy here could disagree with the file the hook
# reads and this whole sweep would then be measuring a ladder nothing enforces.

declare -A WV_RANK_OF=()
declare -A WV_NAME_OF=()
while IFS=$'\t' read -r token rank; do
  case "$token" in ''|'#'*|token) continue ;; esac
  case "$rank" in ''|*[!0-9]*) continue ;; esac
  WV_RANK_OF["$token"]="$rank"
  [ -n "${WV_NAME_OF[$rank]:-}" ] || WV_NAME_OF["$rank"]="$token"
done < "$WV_REPO_ROOT/hooks/models.tsv"
if [ "${#WV_RANK_OF[@]}" -lt 2 ]; then
  printf 'mutants-tier-cells.sh: read %s tier(s) out of hooks/models.tsv, expected at least 2\n' \
    "${#WV_RANK_OF[@]}" >&2
  exit 1
fi

# ---- the 78 cells, read from the PRISTINE table ---------------------------

declare -a WV_CELLS=()
while IFS=$'\t' read -r code lead executor reviewer; do
  case "$code" in ''|'#'*|code) continue ;; esac
  WV_CELLS+=("$code|lead|$lead" "$code|executor|$executor" "$code|reviewer|$reviewer")
done < <(awk -F'\t' '{print $1"\t"$7"\t"$8"\t"$9}' "${WV_PRISTINE_OF[$WV_PHASES_REL]}")

wv_cells=${#WV_CELLS[@]}
if [ "$wv_cells" -ne 78 ]; then
  printf 'mutants-tier-cells.sh: enumerated %s cells out of %s, expected 78 (26 rows x 3 roles)\n' \
    "$wv_cells" "$WV_PHASES_REL" >&2
  exit 1
fi

# ---- the mutation --------------------------------------------------------

WV_PATCH="$WV_LOGS/cell.py"
cat > "$WV_PATCH" <<'PY'
# cell.py <phases.tsv> <golden.tsv> <phase code> <role> <old tier> <new tier>
# Rewrites exactly one cell in each file, and fails loudly if either file did
# not contain the value it was told to replace: a mutation that did not apply is
# reported as NOT-APPLIED, never as a survivor of a green run.
import sys

phases, golden, code, role, old, new = sys.argv[1:7]
col_phases = {"lead": 6, "executor": 7, "reviewer": 8}[role]
col_golden = {"lead": 1, "executor": 2, "reviewer": 3}[role]

def rewrite(path, col):
    out, hits = [], 0
    for line in open(path).read().split("\n"):
        f = line.split("\t")
        if f and f[0] == code and len(f) > col and f[col] == old:
            f[col] = new
            hits += 1
            line = "\t".join(f)
        out.append(line)
    assert hits == 1, "%s: expected exactly 1 %s/%s cell holding %r, found %d" % (
        path, code, role, old, hits)
    open(path, "w").write("\n".join(out))

rewrite(phases, col_phases)
rewrite(golden, col_golden)
PY

wv_mutated=0
wv_skipped=0
wv_uncovered=0
declare -a wv_rows=()

wv_run_cell() {
  local code="$1" role="$2" tier="$3"
  local lc
  lc="$(printf '%s' "$code" | tr 'A-Z' 'a-z')"
  local filter="tier-$lc-$role-*"

  case "$tier" in
    ''|-)
      wv_skipped=$((wv_skipped + 1))
      wv_rows+=("$code|$role|-|N/A|no such role in this phase|-")
      return
      ;;
  esac

  local rank="${WV_RANK_OF[$tier]:-}"
  case "$rank" in
    ''|*[!0-9]*)
      wv_mutated=$((wv_mutated + 1))
      wv_uncovered=$((wv_uncovered + 1))
      wv_rows+=("$code|$role|$tier|NOT-APPLIED|hooks/models.tsv maps no rank to $tier|-")
      return
      ;;
  esac

  # Lower by one where there is room; the floor cells are raised instead, so
  # every non-`-` cell is moved by exactly one tier in the direction that
  # changes the verdict of a case naming it.
  local newrank direction
  if [ -n "${WV_NAME_OF[$((rank - 1))]:-}" ]; then
    newrank=$((rank - 1)); direction=lowered
  elif [ -n "${WV_NAME_OF[$((rank + 1))]:-}" ]; then
    newrank=$((rank + 1)); direction=raised
  else
    wv_mutated=$((wv_mutated + 1))
    wv_uncovered=$((wv_uncovered + 1))
    wv_rows+=("$code|$role|$tier|NOT-APPLIED|no neighbouring tier to move $tier to|-")
    return
  fi
  local newtier="${WV_NAME_OF[$newrank]}"

  wv_mutated=$((wv_mutated + 1))
  local label="$lc-$role"
  if ! python3 "$WV_PATCH" "$WV_TREE/$WV_PHASES_REL" "$WV_TREE/$WV_GOLDEN_REL" \
      "$code" "$role" "$tier" "$newtier" 2>"$WV_LOGS/$label.patch.err"; then
    wv_uncovered=$((wv_uncovered + 1))
    wv_rows+=("$code|$role|$tier|NOT-APPLIED|$(tr '\n' ' ' < "$WV_LOGS/$label.patch.err" | tail -c 60)|-")
    wv_restore_all
    return
  fi
  touch "$WV_TREE/$WV_PHASES_REL" "$WV_TREE/$WV_GOLDEN_REL"

  local log="$WV_LOGS/$label.log"
  ( cd "$WV_TREE" && bash tests/run.sh --filter "$filter" ) > "$log" 2>&1

  # A red counts only when the case that went red is one of THIS cell's own
  # cases. Coverage FAIL lines (the artefact every narrow --filter produces) and
  # any other case are not this cell's evidence.
  local ran=0 first="" fl cn
  ran="$(command grep -c '^\(PASS\|FAIL\) ' "$log" 2>/dev/null)"
  case "$ran" in ''|*[!0-9]*) ran=0 ;; esac
  while IFS= read -r fl; do
    [ -n "$fl" ] || continue
    cn="$(printf '%s' "$fl" | cut -d' ' -f2 | tr -d ':')"
    case "$cn" in
      tier-"$lc"-"$role"-*)
        # A pure coverage complaint about this very case is not a kill.
        case "$fl" in
          *'no positive case'*|*'no negative control'*)
            case "$(printf '%s' "$fl" | sed -E 's/rule W-[A-Z0-9-]+: (no positive case|no negative control)(,(no positive case|no negative control))*;?[[:space:]]*//g')" in
              'FAIL '*': '|'FAIL '*':') continue ;;
            esac
            ;;
        esac
        [ -n "$first" ] || first="$cn"
        ;;
    esac
  done < <(command grep '^FAIL ' "$log")

  if [ -z "$first" ]; then
    wv_uncovered=$((wv_uncovered + 1))
    wv_rows+=("$code|$role|$tier|UNCOVERED|$tier $direction to $newtier, $ran case(s) ran, none of this cell's red|-")
  else
    wv_rows+=("$code|$role|$tier|killed|$tier $direction to $newtier|$first")
  fi
  wv_restore_all
}

for wv_cell in "${WV_CELLS[@]}"; do
  IFS='|' read -r wv_code wv_role wv_tier <<<"$wv_cell"
  wv_run_cell "$wv_code" "$wv_role" "$wv_tier"
done

# ---- the cell -> case map -------------------------------------------------

printf '\n%-10s %-9s %-7s %-11s %-44s %s\n' PHASE ROLE TIER VERDICT EFFECT 'CASE THAT CAUGHT IT'
printf '%s\n' '--------------------------------------------------------------------------------------------------------------'
for wv_row in "${wv_rows[@]:-}"; do
  [ -z "$wv_row" ] && continue
  IFS='|' read -r wv_p wv_r wv_t wv_v wv_e wv_c <<<"$wv_row"
  printf '%-10s %-9s %-7s %-11s %-44s %s\n' "$wv_p" "$wv_r" "$wv_t" "$wv_v" "$wv_e" "$wv_c"
done
printf '%s\n' '--------------------------------------------------------------------------------------------------------------'

wv_restored=yes
for rel in "$WV_PHASES_REL" "$WV_GOLDEN_REL"; do
  if [ "$(sha256sum < "$WV_TREE/$rel" | cut -d' ' -f1)" != "${WV_SHA_OF[$rel]}" ]; then
    printf 'NOT RESTORED: %s\n' "$rel" >&2
    wv_restored=NO
  fi
done

printf 'cells=%s mutants=%s survived=%s skipped=%s restored=%s\n' \
  "$wv_cells" "$wv_mutated" "$wv_uncovered" "$wv_skipped" "$wv_restored"

[ "$wv_uncovered" -eq 0 ] && [ "$wv_restored" = "yes" ] && [ "$((wv_mutated + wv_skipped))" -eq "$wv_cells" ]
