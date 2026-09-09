#!/usr/bin/env bash
# tests/cases/data-reasons.sh — AC-353 (finding 4, fix round 3)
#
# data-all.sh only ever counted 31 rows. This is the full AC: every
# template begins `[<id>] `, has well-formed printf conversions, ends in a
# remedy clause, the file carries the header's declared precedence order,
# and the actual row order matches that declared order exactly — proved
# non-vacuous by a mutation (finding 4: "one reasons precedence swap").

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

  [ "${#actual_order[@]}" = "31" ] || echo "expected 31 rule rows, got ${#actual_order[@]}"
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
fi

diffs2="$(check_reasons "$TSV")"
[ -z "$diffs2" ] || fail "real reasons.tsv unexpectedly differs after mutation proof: $diffs2"

exit $rc
