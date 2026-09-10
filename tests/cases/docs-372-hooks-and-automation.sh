#!/usr/bin/env bash
# tests/cases/docs-372-hooks-and-automation.sh — AC-372.
# Verify framework/references/11-hooks-and-automation.md has correct content:
# - Must NOT contain: "if":, block-on-nonzero, claude invoke-agent, TaskCreated
# - MUST contain: hooks/hooks.json, shipped script paths, hooks/planning-paths.tsv, .wave/approvals/commit-doc.md
set -u

name="${WV_CASE_NAME:-$(basename "$0" .sh)}"
log="${WV_CASE_LOG:-$WV_RUN_TMP/logs/$name.log}"
mkdir -p "$(dirname "$log")"
rc=0
fail() { printf 'ASSERT FAIL: %s\n' "$*" >&2; rc=1; }

file="framework/references/11-hooks-and-automation.md"

# Check for disallowed strings (must NOT be present)
for str in '"if":' 'block-on-nonzero' 'claude invoke-agent' 'TaskCreated'; do
  if command grep -F "$str" "$file" >/dev/null 2>&1; then
    fail "Found disallowed string: $str"
  fi
done

# Check for required strings (MUST be present)
for str in 'hooks/hooks.json' 'hooks/planning-paths.tsv' '.wave/approvals/commit-doc.md'; do
  if ! command grep -F "$str" "$file" >/dev/null 2>&1; then
    fail "Missing required string: $str"
  fi
done

# Check for script paths mentioned (at least some of them)
for script in 'session-start.sh' 'pre-agent.sh' 'subagent-stop.sh'; do
  if ! command grep -F "$script" "$file" >/dev/null 2>&1; then
    fail "Missing script reference: $script"
  fi
done

printf 'RAN docs-check %s decision=allow\n' "$name" >> "$log"
exit $rc
