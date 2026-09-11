#!/usr/bin/env bash
# tests/cases/wiring-366-scripts-exist-executable.sh — AC-366.
#
# Every script hooks/hooks.json references resolves, with CLAUDE_PLUGIN_ROOT
# set to the repo root, to a real, executable file.
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
  printf 'RAN wiring-366 hooks.json=absent\n' >> "$log"
  exit 1
fi

# shellcheck disable=SC2034  # read by the eval'd command strings below
CLAUDE_PLUGIN_ROOT="$WV_REPO_ROOT"

commands="$(jq -r '.hooks[][]?.hooks[]?.command // empty' "$hooks_json" 2>/dev/null)"
n=0
while IFS= read -r cmd; do
  [ -z "$cmd" ] && continue
  n=$((n + 1))
  resolved="$(eval "printf '%s' $cmd" 2>/dev/null)"
  if [ -z "$resolved" ]; then
    fail "command did not resolve to a path: $cmd"
    continue
  fi
  [ -f "$resolved" ] || fail "resolved path does not exist: $resolved (from $cmd)"
  [ -x "$resolved" ] || fail "resolved path is not executable: $resolved (from $cmd)"
done <<<"$commands"

[ "$n" -ge 1 ] || fail "no hook commands found in $hooks_json"

printf 'RAN wiring-366 commands=%s\n' "$n" >> "$log"
exit $rc
