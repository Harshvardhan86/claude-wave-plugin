#!/usr/bin/env bash
# tests/cases/wiring-365-json-shape.sh — AC-365.
#
# hooks/hooks.json parses as valid JSON, every "command" string contains
# ${CLAUDE_PLUGIN_ROOT}, and no command contains an absolute /home/ path, a
# ~, or a bare relative script path (Global Constraint 2).
set -u

# shellcheck source=tests/lib/assert.sh
source "$(dirname "$0")/../lib/assert.sh"

name="$(basename "$0" .sh)"
log="${WV_CASE_LOG:-$WV_RUN_TMP/logs/$name.log}"
mkdir -p "$(dirname "$log")"

rc=0
fail() { printf 'ASSERT FAIL: %s\n' "$*" >&2; rc=1; }

hooks_json="$WV_REPO_ROOT/hooks/hooks.json"

if [ ! -f "$hooks_json" ]; then
  fail "$hooks_json does not exist"
  printf 'RAN wiring-365 hooks.json=absent\n' >> "$log"
  exit 1
fi

if ! jq -e . "$hooks_json" >/dev/null 2>&1; then
  fail "$hooks_json is not valid JSON"
fi

commands="$(jq -r '.hooks[][]?.hooks[]?.command // empty' "$hooks_json" 2>/dev/null)"
n=0
while IFS= read -r cmd; do
  [ -z "$cmd" ] && continue
  n=$((n + 1))
  case "$cmd" in
    *'${CLAUDE_PLUGIN_ROOT}'*) : ;;
    *) fail "command does not contain \${CLAUDE_PLUGIN_ROOT}: $cmd" ;;
  esac
  case "$cmd" in
    *'/home/'*) fail "command contains an absolute /home/ path: $cmd" ;;
  esac
  case "$cmd" in
    *'~'*) fail "command contains a ~: $cmd" ;;
  esac
  # A bare relative path: does not start with "${CLAUDE_PLUGIN_ROOT} once
  # quotes are stripped, and does not itself start with / (absolute).
  stripped="${cmd#\"}"
  case "$stripped" in
    '${CLAUDE_PLUGIN_ROOT}'*|/*) : ;;
    *) fail "command is a bare relative path: $cmd" ;;
  esac
done <<<"$commands"

[ "$n" -ge 1 ] || fail "no hook commands found in $hooks_json"

printf 'RAN wiring-365 commands=%s\n' "$n" >> "$log"
exit $rc
