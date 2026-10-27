#!/usr/bin/env bash
# tests/cases/data-conditions.sh — closed condition vocabulary (design 7.2)
# and the one-level rule (design 7.1).
#
# The shipped `condition` column is a closed set. An unknown keyword fails
# OPEN at run time (a table newer than the scripts must not deadlock a wave),
# so nothing but this pin stops the table carrying a typo. Every keyword that
# can make a row conditional (all but `always`) must have an arm in each of
# the three `case` statements that read it. The source of a `findings:` or
# `done:` row is never itself `findings:` or `done:` — evaluation is one
# level, and a recursive helper would clobber WV_COND_*.
#
# Non-vacuous: a temp copy of the table with a planted bad keyword, and a
# temp copy whose `findings:` source is itself `findings:`, must fail the
# same checks.

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
PRE=scripts/hooks/pre-agent.sh
LIB=scripts/hooks/lib.sh
for f in "$PHASES" "$PRE" "$LIB"; do
  [ -f "$f" ] || { fail "$f does not exist"; exit 1; }
done

# ---- closed set -----------------------------------------------------------
#
# A cell is legal when it is exactly one of: always, ui|behaviour_change, cr,
# vocabulary, behaviour_change, findings:<scanner row>, done:<any row>.

declare -A code_exists=() scanner=()
declare -a codes=() conds=()
while IFS=$'\x1f' read -r code cond findings; do
  [ -n "$code" ] || continue
  codes+=("$code")
  conds+=("$cond")
  code_exists["$code"]=1
  [ "$findings" != "-" ] && [ -n "$findings" ] && scanner["$code"]=1
done < <(awk -F'\t' 'NR==1{next} /^#/{next} {print $1"\037"$4"\037"$12}' "$PHASES")

check_closed() {
  # check_closed <phases-file> -> prints one line per illegal cell; empty is clean.
  local phases="$1" code cond findings src
  while IFS=$'\x1f' read -r code cond findings; do
    [ -n "$code" ] || continue
    case "$cond" in
      always|'ui|behaviour_change'|cr|vocabulary|behaviour_change) ;;
      findings:*)
        src="${cond#findings:}"
        if [ -z "${code_exists[$src]+set}" ]; then
          echo "$code: findings:$src names no row"
        elif [ "$findings" = "from-file" ]; then
          :
        fi
        # scanner-ness is checked against the REAL table's map, rebuilt below
        ;;
      done:*)
        src="${cond#done:}"
        if [ -z "${code_exists[$src]+set}" ]; then
          echo "$code: done:$src names no row"
        fi
        ;;
      *)
        echo "$code: condition '$cond' is not in the closed set"
        ;;
    esac
  done < <(awk -F'\t' 'NR==1{next} /^#/{next} {print $1"\037"$4"\037"$12}' "$phases")
}

# Rebuild scanner/code maps from the file under test for findings: legality.
check_closed_full() {
  local phases="$1"
  declare -A exists=() is_scanner=()
  local code cond findings src
  while IFS=$'\x1f' read -r code cond findings; do
    [ -n "$code" ] || continue
    exists["$code"]=1
    [ "$findings" != "-" ] && [ -n "$findings" ] && is_scanner["$code"]=1
  done < <(awk -F'\t' 'NR==1{next} /^#/{next} {print $1"\037"$4"\037"$12}' "$phases")
  while IFS=$'\x1f' read -r code cond findings; do
    [ -n "$code" ] || continue
    case "$cond" in
      always|'ui|behaviour_change'|cr|vocabulary|behaviour_change) ;;
      findings:*)
        src="${cond#findings:}"
        if [ -z "${exists[$src]+set}" ]; then
          echo "$code: findings:$src names no row"
        elif [ -z "${is_scanner[$src]+set}" ]; then
          echo "$code: findings:$src names a non-scanner"
        fi
        ;;
      done:*)
        src="${cond#done:}"
        if [ -z "${exists[$src]+set}" ]; then
          echo "$code: done:$src names no row"
        fi
        ;;
      *)
        echo "$code: condition '$cond' is not in the closed set"
        ;;
    esac
  done < <(awk -F'\t' 'NR==1{next} /^#/{next} {print $1"\037"$4"\037"$12}' "$phases")
}

closed_diff="$(check_closed_full "$PHASES")"
if [ -n "$closed_diff" ]; then
  fail "closed-set violations:"
  while IFS= read -r line; do fail "  $line"; done <<< "$closed_diff"
fi

# Pin the five new rows' condition cells by value.
uia_c=$(awk -F'\t' '$1=="UIA"{print $4}' "$PHASES")
ben_c=$(awk -F'\t' '$1=="BEN"{print $4}' "$PHASES")
es_c=$(awk -F'\t' '$1=="ES"{print $4}' "$PHASES")
bfes_c=$(awk -F'\t' '$1=="BF-ES"{print $4}' "$PHASES")
benc_c=$(awk -F'\t' '$1=="BEN-CLOSE"{print $4}' "$PHASES")
[ "$uia_c" = "vocabulary" ] || fail "UIA condition should be vocabulary, got '$uia_c'"
[ "$ben_c" = "behaviour_change" ] || fail "BEN condition should be behaviour_change, got '$ben_c'"
[ "$es_c" = "vocabulary" ] || fail "ES condition should be vocabulary, got '$es_c'"
[ "$bfes_c" = "findings:ES" ] || fail "BF-ES condition should be findings:ES, got '$bfes_c'"
[ "$benc_c" = "done:BEN" ] || fail "BEN-CLOSE condition should be done:BEN, got '$benc_c'"

# ---- every conditional keyword has an arm in all three case statements ----
#
# Keywords that make a row conditional (all but always). findings:* and done:*
# are prefixes; the rest are exact cells.

extract_case_arms() {
  # extract_case_arms <file> <function-name>
  # Prints the `case "$cond"` arm labels inside that function.
  local file="$1" fn="$2"
  awk -v fn="$fn" '
    $0 ~ "^" fn "\\(\\) \\{" { infn=1; next }
    infn && /^[a-zA-Z_][a-zA-Z0-9_]*\\(\\) \{/ { infn=0 }
    infn { print }
  ' "$file" | awk '
    /case "\$cond" in/ { inc=1; next }
    inc && /^[[:space:]]*esac/ { inc=0 }
    inc {
      # a case arm is a line ending in ) that is not a nested case/if
      if ($0 ~ /^[[:space:]]+('\''[^'\'']+'\''|[A-Za-z0-9_:*|]+|[A-Za-z0-9_:*|]+\))[[:space:]]*$/ \
          || $0 ~ /^[[:space:]]+('\''[^'\'']+'\''|[A-Za-z0-9_:*|]+)\)/) {
        label=$0
        sub(/^[[:space:]]+/, "", label)
        sub(/\).*$/, "", label)
        gsub(/^'\''|'\''$/, "", label)
        print label
      }
    }
  '
}

has_arm() {
  local haystack="$1" needle="$2"
  case $'\n'"$haystack"$'\n' in
    *$'\n'"$needle"$'\n'*) return 0 ;;
  esac
  return 1
}

gate_arms="$(extract_case_arms "$PRE" wv_condition_met)"
adv_arms="$(extract_case_arms "$LIB" wv_up_condition_met)"
why_arms="$(extract_case_arms "$PRE" wv_required_because)"

# Keywords collected from the shipped table (always excluded).
declare -A need_arm=()
i=0
for code in "${codes[@]}"; do
  cond="${conds[$i]}"
  i=$((i + 1))
  case "$cond" in
    ''|always) ;;
    findings:*) need_arm["findings:*"]=1 ;;
    done:*) need_arm["done:*"]=1 ;;
    *) need_arm["$cond"]=1 ;;
  esac
done

for kw in "${!need_arm[@]}"; do
  has_arm "$gate_arms" "$kw" || fail "wv_condition_met has no arm for '$kw' (arms: $(printf '%s ' $gate_arms))"
  has_arm "$adv_arms" "$kw" || fail "wv_up_condition_met has no arm for '$kw' (arms: $(printf '%s ' $adv_arms))"
  has_arm "$why_arms" "$kw" || fail "wv_required_because has no arm for '$kw' (arms: $(printf '%s ' $why_arms))"
done

# The five new keywords must be among those arms even if a future table drops a row.
for kw in vocabulary behaviour_change 'findings:*' 'done:*'; do
  has_arm "$gate_arms" "$kw" || fail "wv_condition_met missing required arm '$kw'"
  has_arm "$adv_arms" "$kw" || fail "wv_up_condition_met missing required arm '$kw'"
  has_arm "$why_arms" "$kw" || fail "wv_required_because missing required arm '$kw'"
done

# ---- one-level rule -------------------------------------------------------
#
# The source of a findings: or done: row must not itself be findings: or done:.

check_one_level() {
  local phases="$1"
  declare -A cond_of=()
  local code cond src srccond
  while IFS=$'\x1f' read -r code cond; do
    [ -n "$code" ] || continue
    cond_of["$code"]="$cond"
  done < <(awk -F'\t' 'NR==1{next} /^#/{next} {print $1"\037"$4}' "$phases")
  for code in "${!cond_of[@]}"; do
    cond="${cond_of[$code]}"
    case "$cond" in
      findings:*|done:*)
        src="${cond#*:}"
        srccond="${cond_of[$src]:-}"
        case "$srccond" in
          findings:*|done:*)
            echo "$code condition $cond sources $src whose condition is $srccond"
            ;;
        esac
        ;;
    esac
  done
}

one_diff="$(check_one_level "$PHASES")"
if [ -n "$one_diff" ]; then
  fail "one-level violations:"
  while IFS= read -r line; do fail "  $line"; done <<< "$one_diff"
fi

# ---- mutation proof -------------------------------------------------------

tmp="$(mktemp "${TMPDIR:-/tmp}/phases-cond-mutated.XXXXXX.tsv")"
wv_on_exit 'rm -f "$tmp"'

# Plant a keyword the closed set does not name.
awk -F'\t' 'BEGIN{OFS="\t"} $1=="AC"{$4="bogus_keyword"} {print}' "$PHASES" > "$tmp"
planted="$(check_closed_full "$tmp")"
case "$planted" in
  *"bogus_keyword"*) : ;;
  *) fail "MUTATION PROOF FAILED: planting condition 'bogus_keyword' on AC was not caught: '$planted'" ;;
esac

# Plant a findings: source that is itself findings: (one-level).
awk -F'\t' 'BEGIN{OFS="\t"} $1=="BC"{$4="findings:SEA"} {print}' "$PHASES" > "$tmp"
planted="$(check_one_level "$tmp")"
case "$planted" in
  *"findings:SEA"*) : ;;
  *) fail "MUTATION PROOF FAILED: nesting findings:BC -> findings:SEA was not caught: '$planted'" ;;
esac

# The real table must still be clean after the temp-copy proofs.
closed2="$(check_closed_full "$PHASES")"
[ -z "$closed2" ] || fail "real phases.tsv closed-set dirty after mutation proof: $closed2"
one2="$(check_one_level "$PHASES")"
[ -z "$one2" ] || fail "real phases.tsv one-level dirty after mutation proof: $one2"

exit $rc
