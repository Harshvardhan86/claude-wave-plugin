#!/usr/bin/env bash
# tests/cases/docs-371-plugin-json.sh — AC-371.
# Verify that .claude-plugin/plugin.json has version == "0.2.0" and no "hooks" key.
set -u

name="${WV_CASE_NAME:-$(basename "$0" .sh)}"
log="${WV_CASE_LOG:-$WV_RUN_TMP/logs/$name.log}"
mkdir -p "$(dirname "$log")"
rc=0
fail() { printf 'ASSERT FAIL: %s\n' "$*" >&2; rc=1; }

# Check version is 0.2.0
if ! jq -e '.version == "0.2.0"' .claude-plugin/plugin.json >/dev/null 2>&1; then
  fail "plugin.json version is not 0.2.0"
fi

# Check hooks key does not exist
if jq -e 'has("hooks")' .claude-plugin/plugin.json >/dev/null 2>&1; then
  fail "plugin.json has a hooks key (must not be present)"
fi

printf 'RAN docs-check %s decision=allow\n' "$name" >> "$log"
exit $rc
