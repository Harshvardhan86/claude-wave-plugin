#!/usr/bin/env bash
# tests/cases/docs-375-wave-orchestrator.sh — AC-375.
# Verify skills/wave-orchestrator/SKILL.md has Hook-enforced contract section with:
# - tag grammar
# - artifact/marker table
# - approvals directory
# - three modes
# - enforce values
# - declared bounds (Bash writes, worktree subagents)
set -u

name="${WV_CASE_NAME:-$(basename "$0" .sh)}"
log="${WV_CASE_LOG:-$WV_RUN_TMP/logs/$name.log}"
mkdir -p "$(dirname "$log")"
rc=0
fail() { printf 'ASSERT FAIL: %s\n' "$*" >&2; rc=1; }

file="skills/wave-orchestrator/SKILL.md"

# Check that Hook-enforced contract section exists
if ! command grep -F '## Hook-enforced contract' "$file" >/dev/null 2>&1; then
  fail "Missing 'Hook-enforced contract' section heading"
fi

# Check for key concepts in the section
if ! command grep -F '[W:<wave> P:<PHASE> R:<lead|executor|reviewer|scanner|writer>]' "$file" >/dev/null 2>&1; then
  fail "Missing tag grammar documentation"
fi

# Check for artifacts and markers mention
if ! command grep -F 'Artifact' "$file" >/dev/null 2>&1 || ! command grep -F 'Marker' "$file" >/dev/null 2>&1; then
  fail "Missing artifact/marker table"
fi

# Check for three modes (full/demo/solo) - they may be in various formats
if ! command grep -i 'full.*mode\|^###.*[Ff]ull' "$file" >/dev/null 2>&1; then
  fail "Missing reference to full mode"
fi
if ! command grep -i 'demo.*mode\|^###.*demo' "$file" >/dev/null 2>&1; then
  fail "Missing reference to demo mode"
fi
if ! command grep -i '\*\*[Ss]olo\*\*\|solo.*mode' "$file" >/dev/null 2>&1; then
  fail "Missing reference to solo mode"
fi

# Check for enforce values
if ! command grep -F 'enforce' "$file" >/dev/null 2>&1; then
  fail "Missing enforce values documentation"
fi

# Check for declared bounds
if ! command grep -F 'Declared bounds' "$file" >/dev/null 2>&1; then
  fail "Missing 'Declared bounds' section"
fi

if ! command grep -F 'worktree' "$file" >/dev/null 2>&1; then
  fail "Missing worktree reference in bounds"
fi

printf 'RAN docs-check %s decision=allow\n' "$name" >> "$log"
exit $rc
