#!/usr/bin/env bash
# tests/cases/data-orchestrator-writable.sh — AC-352 (finding 4, fix round 3)
#
# data-all.sh only checked README.md's presence. This is the full AC: the
# exact required set (CHANGELOG.md, README.md, CONTINUE-HERE.md, docs/**),
# nothing else, and no row broad enough to exempt a source directory.
#
# "asserted by replaying AC-261 against every row": scripts/hooks/pre-edit.sh
# does not exist yet (a later task), so the dynamic replay (seed
# PROJ/src/app.ts tracked by git, run pre-edit.sh, expect deny) cannot run
# yet. What this test CAN do now, honestly, is the static half of that
# claim: none of orchestrator-writable.tsv's own glob patterns match
# AC-261's fixture path ("src/app.ts") using the same `[[ path == glob ]]`
# matching tests/cases/data-planning-paths.sh uses for the sibling file.
# The full dynamic replay is deferred to whichever task builds pre-edit.sh.

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

TSV=hooks/orchestrator-writable.tsv
[ -f "$TSV" ] || { fail "$TSV does not exist"; exit 1; }

declare -a rows=()
while IFS= read -r line; do
  [ -z "$line" ] && continue
  case "$line" in '#'*) continue ;; esac
  rows+=("$line")
done < "$TSV"

declare -A expect=( ["CHANGELOG.md"]=1 ["README.md"]=1 ["CONTINUE-HERE.md"]=1 ["docs/**"]=1 )
declare -A got=()
for r in "${rows[@]}"; do got["$r"]=1; done

for want in "${!expect[@]}"; do
  [ -n "${got[$want]:-}" ] || fail "orchestrator-writable.tsv is missing required row '$want'"
done
for r in "${rows[@]}"; do
  [ -n "${expect[$r]:-}" ] || fail "orchestrator-writable.tsv has an unexpected row '$r'"
done
[ "${#rows[@]}" = "4" ] || fail "orchestrator-writable.tsv should have exactly 4 rows, got ${#rows[@]}"

# static AC-261 proxy: no row's glob matches a real source file.
ac261_probe="src/app.ts"
for r in "${rows[@]}"; do
  # shellcheck disable=SC2053
  if [[ "$ac261_probe" == $r ]]; then
    fail "row '$r' matches AC-261's fixture '$ac261_probe' — this row would exempt a source directory"
  fi
done
# also probe one nested source path, since a bare wildcard row would only
# show up on a deeper path
ac261_probe2="src/nested/module.ts"
for r in "${rows[@]}"; do
  # shellcheck disable=SC2053
  if [[ "$ac261_probe2" == $r ]]; then
    fail "row '$r' matches nested source path '$ac261_probe2' — this row would exempt a source directory"
  fi
done

exit $rc
