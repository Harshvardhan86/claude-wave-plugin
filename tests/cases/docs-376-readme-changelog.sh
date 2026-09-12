#!/usr/bin/env bash
# tests/cases/docs-376-readme-changelog.sh — AC-376.
# Verify README.md and CHANGELOG.md:
# - README carries a hooks section and 0.2.1 badge
# - CHANGELOG has the current 0.2.1 rule contracts and preserves the historical
#   0.2.0 entry listing the hooks layer, three modes and data files
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

if ! command grep -F 'version-0.2.1-blue.svg' "$readme" >/dev/null 2>&1; then
  fail "README missing 0.2.1 version badge"
fi

# Check CHANGELOG
changelog="CHANGELOG.md"
if ! command grep -F '## [0.2.0]' "$changelog" >/dev/null 2>&1; then
  fail "CHANGELOG missing [0.2.0] entry"
fi

# Current release contracts live in their own entry; historical checks remain.
release="$(sed -n '/^## \[0.2.1\]/,/^## \[0.2.0\]/p' "$changelog")"
for term in '## [0.2.1] — 2026-09-12' 'W-BGWAIT' 'W-POLL' 'W-LEFTOVER' '37 rules'; do
  if ! command grep -F "$term" <<< "$release" >/dev/null 2>&1; then
    fail "CHANGELOG current release missing $term"
  fi
done
if ! command grep -F 'v0.2.1 adds' "$readme" >/dev/null 2>&1; then
  fail "README missing the current enforcement additions"
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
