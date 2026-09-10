#!/usr/bin/env bash
# tests/cases/docs-376-readme-changelog.sh — AC-376.
# Verify README.md and CHANGELOG.md:
# - README carries a hooks section and 0.2.0 badge
# - CHANGELOG has a 0.2.0 entry listing hooks layer, three modes, data files
set -u

name="${WV_CASE_NAME:-$(basename "$0" .sh)}"
log="${WV_CASE_LOG:-$WV_RUN_TMP/logs/$name.log}"
mkdir -p "$(dirname "$log")"
rc=0
fail() { printf 'ASSERT FAIL: %s\n' "$*" >&2; rc=1; }

# Check README
readme="README.md"
if ! command grep -F 'Hook enforcement (v0.2.0)' "$readme" >/dev/null 2>&1; then
  fail "README missing 'Hook enforcement (v0.2.0)' section"
fi

if ! command grep -F 'version-0.2.0-blue.svg' "$readme" >/dev/null 2>&1; then
  fail "README missing 0.2.0 version badge"
fi

# Check CHANGELOG
changelog="CHANGELOG.md"
if ! command grep -F '## [0.2.0]' "$changelog" >/dev/null 2>&1; then
  fail "CHANGELOG missing [0.2.0] entry"
fi

# Check for key terms in CHANGELOG 0.2.0 section
if ! command grep -A 30 '\[0.2.0\]' "$changelog" | command grep -F 'Hook enforcement' >/dev/null 2>&1; then
  fail "CHANGELOG 0.2.0 section missing 'Hook enforcement'"
fi

# Check for three modes mentioned
for mode in 'full' 'demo' 'solo'; do
  if ! command grep -A 40 '\[0.2.0\]' "$changelog" | command grep -i "$mode" >/dev/null 2>&1; then
    fail "CHANGELOG 0.2.0 section missing mention of $mode mode"
  fi
done

# Check for data files mentioned (TSV or data files references)
if ! command grep -A 40 '\[0.2.0\]' "$changelog" | command grep -i 'tsv\|data' >/dev/null 2>&1; then
  fail "CHANGELOG 0.2.0 section missing reference to data files"
fi

printf 'RAN docs-check %s decision=allow\n' "$name" >> "$log"
exit $rc
