#!/usr/bin/env bash
# tests/cases/docs-373-invariant-rules.sh — AC-373.
# Verify framework/references/07-invariant-rules.md invariant 7:
# - Must NOT claim compaction is blocked when save fails
# - MUST state that checkpoint is enforced and stop is advised
set -u

name="${WV_CASE_NAME:-$(basename "$0" .sh)}"
log="${WV_CASE_LOG:-$WV_RUN_TMP/logs/$name.log}"
mkdir -p "$(dirname "$log")"
rc=0
fail() { printf 'ASSERT FAIL: %s\n' "$*" >&2; rc=1; }

file="framework/references/07-invariant-rules.md"

# Check that the old claim about blocking is gone
if command grep -F 'compaction is blocked if the save fails' "$file" >/dev/null 2>&1; then
  fail "File still contains the old claim 'compaction is blocked if the save fails'"
fi

# Check that checkpoint enforcement statement is present
if ! command grep -F 'checkpoint is enforced' "$file" >/dev/null 2>&1; then
  fail "Missing statement about checkpoint being enforced"
fi

# Check that stop is advised statement is present
if ! command grep -F 'stop is advised' "$file" >/dev/null 2>&1; then
  fail "Missing statement about stop being advised"
fi

printf 'RAN docs-check %s decision=allow\n' "$name" >> "$log"
exit $rc
