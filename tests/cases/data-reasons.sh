#!/usr/bin/env bash
# tests/cases/data-reasons.sh — AC-353 (finding 4, fix round 3)
#
# data-all.sh only ever counted 31 rows. This is the full AC: every
# template begins `[<id>] `, has well-formed printf conversions, ends in a
# remedy clause, the file carries the header's declared precedence order,
# and the actual row order matches that declared order exactly — proved
# non-vacuous by a mutation (finding 4: "one reasons precedence swap").
#
# THE COMPARISON IS THREE-WAY, and the third leg is the point. Comparing
# reasons.tsv's row order against the precedence comment at the top of
# reasons.tsv is SELF-CONSISTENCY: one hand edits both, in one sitting, and a
# swap made in both places passes every check here. So the order is also
# compared against tests/golden/reasons-precedence.tsv, which is maintained
# independently, states the DESIGN BANDS the order expresses, and is the same
# kind of external reference tests/golden/phases-tiers.tsv is for the phase
# table. Row order, header comment and golden must all three agree; a drift in
# any one of them fails, and moving a rule now means arguing against a stated
# band rather than editing two copies of a list.

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

TSV=hooks/reasons.tsv
[ -f "$TSV" ] || { fail "$TSV does not exist"; exit 1; }

# check_reasons <file> -> prints nothing when the file is fully well-formed;
# otherwise prints one diagnostic line per problem. Used both against the
# real file and, in the mutation proof below, against a corrupted copy.
check_reasons() {
  local file="$1"
  local precedence_line
  precedence_line="$(command grep -m1 '^# Wave hook enforcement rule reasons\. Precedence' "$file")"
  if [ -z "$precedence_line" ]; then
    echo "no precedence header comment found"
    return
  fi
  # "Precedence (high<arrow>low): A, B, C" — the arrow is a multi-byte
  # unicode glyph, not "->", so match on "high...low" rather than the
  # literal arrow bytes.
  local declared
  declared="$(printf '%s' "$precedence_line" | sed -E 's/^.*Precedence \(high.*low\): //')"
  declared="${declared%.}"
  IFS=',' read -ra want_order <<< "$(printf '%s' "$declared" | tr -d ' ')"

  declare -a actual_order=()
  declare -A seen=()
  local id precedence text
  while IFS=$'\t' read -r id precedence text; do
    [ -z "$id" ] && continue
    case "$id" in '#'*|rule_id) continue ;; esac
    if [ -n "${seen[$id]:-}" ]; then
      echo "duplicate rule id: $id"
    fi
    seen["$id"]=1
    actual_order+=("$id")

    case "$text" in
      "[$id] "*) : ;;
      *) echo "$id: template does not start with '[$id] '" ;;
    esac
    case "$text" in
      *"; remedy: "?*) : ;;
      *) echo "$id: template does not end in a non-empty '; remedy: ...' clause" ;;
    esac
    # every literal '%' must begin a valid conversion (%s %d %% etc.), so a
    # stray '%' can never reach printf unescaped.
    local stripped
    stripped="$(printf '%s' "$text" | sed -E 's/%[sd%]//g')"
    if [[ "$stripped" == *%* ]]; then
      echo "$id: template has a malformed printf conversion"
    fi
  done < "$file"

  if [ "${#want_order[@]}" != "${#actual_order[@]}" ]; then
    echo "precedence header lists ${#want_order[@]} ids, file has ${#actual_order[@]} rows"
  else
    local i
    for i in "${!want_order[@]}"; do
      if [ "${want_order[$i]}" != "${actual_order[$i]:-}" ]; then
        echo "row order mismatch at position $i: header says '${want_order[$i]}', file has '${actual_order[$i]:-}'"
      fi
    done
  fi

  # 31 through Task 9; Task 10 added W-SESSION, W-REMINDER and W-SCORECARD.
  [ "${#actual_order[@]}" = "34" ] || echo "expected 34 rule rows, got ${#actual_order[@]}"

  # The third leg: the independent golden. Read here rather than in the caller so
  # the mutation proof below exercises it too.
  local golden="tests/golden/reasons-precedence.tsv"
  if [ ! -f "$golden" ]; then
    echo "the independent precedence golden $golden does not exist"
    return
  fi
  declare -a golden_order=()
  local g_prec g_id g_band
  while IFS=$'\t' read -r g_prec g_id g_band; do
    case "$g_prec" in ''|'#'*|precedence) continue ;; esac
    golden_order+=("$g_id")
    [ -n "$g_band" ] || echo "$g_id: the golden gives it no design band"
  done < "$golden"
  if [ "${#golden_order[@]}" = "0" ]; then
    # An empty read is a FAILED read of the golden, never a clean one.
    echo "read 0 rows out of $golden, so the independent order was not compared"
    return
  fi
  if [ "${#golden_order[@]}" != "${#actual_order[@]}" ]; then
    echo "$golden lists ${#golden_order[@]} ids, $file has ${#actual_order[@]} rows"
  else
    local j
    for j in "${!golden_order[@]}"; do
      if [ "${golden_order[$j]}" != "${actual_order[$j]:-}" ]; then
        echo "golden order mismatch at position $j: $golden says '${golden_order[$j]}', file has '${actual_order[$j]:-}'"
      fi
    done
  fi
  # And the precedence NUMBER on each row must be its 1-based position, so the
  # column a consumer sorts on cannot disagree with the order it is written in.
  local k pos=0
  while IFS=$'\t' read -r id precedence text; do
    case "$id" in ''|'#'*|rule_id) continue ;; esac
    pos=$((pos + 1))
    [ "$precedence" = "$pos" ] || echo "$id: precedence column says '$precedence', row position is $pos"
  done < "$file"
  k=0
}

diffs="$(check_reasons "$TSV")"
if [ -n "$diffs" ]; then
  fail "reasons.tsv problem(s):"
  while IFS= read -r line; do fail "  $line"; done <<< "$diffs"
fi

# ---- mutation proof: swap two rows' file order without touching the
# header's declared precedence, so the order check must catch it ---------

tmp_reasons="$(mktemp "${TMPDIR:-/tmp}/reasons-mutated.XXXXXX.tsv")"
trap 'rm -f "$tmp_reasons"' EXIT

# Simple, robust swap: exchange the two data lines whose first field is
# W-STATE and W-NESTED, leaving every other line (including the header
# comment) untouched.
awk -F'\t' '
  $1=="W-STATE"  { state_nr=NR }
  $1=="W-NESTED" { nested_nr=NR }
  { line[NR]=$0 }
  END {
    for (i=1; i<=NR; i++) {
      if (i==state_nr)       print line[nested_nr]
      else if (i==nested_nr) print line[state_nr]
      else                   print line[i]
    }
  }
' "$TSV" > "$tmp_reasons"

mutated_diff="$(check_reasons "$tmp_reasons")"
if [ -z "$mutated_diff" ]; then
  fail "MUTATION PROOF FAILED: swapping W-STATE/W-NESTED file order was not caught — the precedence-order check is vacuous"
else
  case "$mutated_diff" in
    *"row order mismatch"*) : ;;
    *) fail "mutation proof caught something, but not a row-order mismatch: $mutated_diff" ;;
  esac
  # The INDEPENDENT leg must catch it too — that is the whole reason it exists. A
  # mutation caught only by the header comparison would leave the golden untested,
  # and an untested comparison is one that has never been shown to be able to fail.
  case "$mutated_diff" in
    *"golden order mismatch"*) : ;;
    *) fail "the independent golden did not catch the swap; only the header did: $mutated_diff" ;;
  esac
fi

diffs2="$(check_reasons "$TSV")"
[ -z "$diffs2" ] || fail "real reasons.tsv unexpectedly differs after mutation proof: $diffs2"

exit $rc
