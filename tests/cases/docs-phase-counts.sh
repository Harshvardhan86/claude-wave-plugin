#!/usr/bin/env bash
# tests/cases/docs-phase-counts.sh
#
# The phase counts the documentation states are DERIVED here from
# hooks/phases.tsv (the table the engine reads), never typed in: total rows of
# full mode, rows whose condition is `always`, the conditional remainder and
# the demo subset. framework/SKILL.md (heading, intro, table length, the [DR]
# row's condition), commands/wave-start.md (description and usage line) and
# README.md must state exactly those numbers, and the pre-0.3.0 counts
# ("17 base phases", "max 19", DR "for UI waves" only) must be gone from the
# live docs. Historical CHANGELOG entries and design documents are not swept.
set -u

# shellcheck source=tests/lib/assert.sh
source "$(dirname "$0")/../lib/assert.sh"

name="${WV_CASE_NAME:-$(basename "$0" .sh)}"
log="${WV_CASE_LOG:-$WV_RUN_TMP/logs/$name.log}"
mkdir -p "$(dirname "$log")"
rc=0
fail() { printf 'ASSERT FAIL: %s\n' "$*" >&2; rc=1; }

root="$WV_REPO_ROOT"
tsv="$root/hooks/phases.tsv"
skill="$root/framework/SKILL.md"
cmd="$root/commands/wave-start.md"
readme="$root/README.md"

# Columns are located by header name, so a column move cannot silently
# re-point the derivation.
counts="$(awk -F'\t' '
  /^#/ { next }
  !hdr { for (i = 1; i <= NF; i++) col[$i] = i; hdr = 1; next }
  NF == 0 { next }
  {
    m = "," $col["modes"] ","
    if (m ~ /,full,/) { full++; if ($col["condition"] == "always") always++ }
    if (m ~ /,demo,/) demo++
    if ($col["code"] == "DR") dr = $col["condition"]
  }
  END { printf "%d %d %d %s\n", full, always, demo, dr }
' "$tsv")"
read -r total always demo dr_cond <<< "$counts"
cond=$((total - always))
printf 'derived total=%s always=%s conditional=%s demo=%s dr=%s\n' \
  "$total" "$always" "$cond" "$demo" "$dr_cond" >> "$log"

# A derivation that produced nothing is a failed measurement, never a pass.
if [ -z "$total" ] || [ "$total" -lt 1 ] || [ -z "$always" ] || [ "$always" -lt 1 ] \
   || [ -z "$demo" ] || [ "$demo" -lt 1 ] || [ -z "$dr_cond" ]; then
  fail "could not derive the counts from $tsv: '$counts'"
  exit 1
fi

need() { # need <file> <literal> <what>
  command grep -qF -- "$2" "$1" || fail "$3: '$2' is absent from ${1#"$root"/}"
}

# ---- framework/SKILL.md ---------------------------------------------------
need "$skill" "## Wave pipeline ($total rows — $always unconditional, $cond conditional)" "SKILL.md heading"
need "$skill" "strict pipeline of $total phase rows. $always of them run in every full-mode wave. $cond are conditional" "SKILL.md intro"
need "$skill" "Maximum surface per wave: $total phases; the smallest full-mode wave runs $always." "SKILL.md intro maximum"

rows="$(awk '/^## Wave pipeline/ { t = 1; next } t && /^## / { t = 0 } t && /^\| [0-9]/ { n++ } END { print n + 0 }' "$skill")"
[ "$rows" = "$total" ] || fail "SKILL.md phase table has $rows numbered rows, phases.tsv has $total full-mode rows"

dr_row="$(command grep -F '| 1.5 | `[DR]`' "$skill")"
[ -n "$dr_row" ] || fail "SKILL.md has no 1.5 [DR] row"
case "$dr_cond" in
  *behaviour_change*)
    case "$dr_row" in *behaviour*) : ;; *) fail "the [DR] row omits behaviour change, which phases.tsv's condition '$dr_cond' includes: $dr_row" ;; esac ;;
esac
case "$dr_cond" in
  *ui*)
    case "$dr_row" in *UI*) : ;; *) fail "the [DR] row omits UI, which phases.tsv's condition '$dr_cond' includes: $dr_row" ;; esac ;;
esac

# ---- commands/wave-start.md -----------------------------------------------
desc="$(command grep -m1 '^description:' "$cmd")"
case "$desc" in
  *"$total phase rows: $always always, $cond conditional"*) : ;;
  *) fail "wave-start.md description does not state '$total phase rows: $always always, $cond conditional': $desc" ;;
esac
case "$desc" in *"max $total"*) : ;; *) fail "wave-start.md description does not state 'max $total'" ;; esac
case "$desc" in *"$demo-phase subset"*) : ;; *) fail "wave-start.md description does not state the $demo-phase demo subset" ;; esac
need "$cmd" "# full v2 framework ($total phase rows: $always always + $cond conditional)" "wave-start.md usage line"

# ---- README.md --------------------------------------------------------------
need "$readme" "| $total rows: $always always, $cond conditional |" "README comparison row"
need "$readme" "Maximum surface per wave: $total phases; the smallest full wave runs $always." "README framework paragraph"

# ---- stale pre-0.3.0 counts are gone from the live docs ----------------------
live=("$skill" "$cmd" "$readme" "$root/skills" "$root/framework/references")
for stale in '17 base phases' '17 phases +' 'max 19' 'mandatory for UI waves**' '17 base + 2 conditional'; do
  hits="$(command grep -rnF -- "$stale" "${live[@]}")"
  st=$?
  if [ "$st" -ge 2 ]; then
    fail "stale-count scan did not run for '$stale' (grep exit $st)"
  elif [ -n "$hits" ]; then
    fail "stale count '$stale' remains: $(printf '%s' "$hits" | head -3 | tr '\n' ' ')"
  fi
done

printf 'RAN docs-check %s decision=allow\n' "$name" >> "$log"
exit $rc
