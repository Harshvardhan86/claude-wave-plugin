#!/usr/bin/env bash
# tests/cases/wiring-370-timeouts-and-async.sh — AC-370.
#
# No entry sets async: true, subagent-stop.sh sets timeout: 60 (it streams a
# possibly multi-MB transcript with a byte cap), and every other timeout is
# between 5 and 30 seconds inclusive.
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
  printf 'RAN wiring-370 hooks.json=absent\n' >> "$log"
  exit 1
fi

CLAUDE_PLUGIN_ROOT="$WV_REPO_ROOT"

n_async_true="$(jq '[.. | objects | select(has("async")) | select(.async == true)] | length' "$hooks_json")"
[ "$n_async_true" = "0" ] || fail "hooks.json sets async:true on $n_async_true entr(y/ies)"

rows="$(jq -r '
  .hooks | to_entries[] as $e
  | $e.value[] as $group
  | $group.hooks[] as $h
  | [$h.command, ($h.timeout // "<absent>")] | @tsv
' "$hooks_json" 2>/dev/null)"

n=0
while IFS=$'\t' read -r cmd timeout; do
  [ -z "$cmd" ] && continue
  n=$((n + 1))
  resolved="$(eval "printf '%s' $cmd" 2>/dev/null)"
  script="$(basename "$resolved" 2>/dev/null)"
  case "$timeout" in
    '<absent>') fail "$script: no explicit timeout set"; continue ;;
    ''|*[!0-9]*) fail "$script: timeout is not a plain integer: $timeout"; continue ;;
  esac
  if [ "$script" = "subagent-stop.sh" ]; then
    [ "$timeout" = "60" ] || fail "subagent-stop.sh: want timeout 60, got $timeout"
  else
    if [ "$timeout" -lt 5 ] || [ "$timeout" -gt 30 ]; then
      fail "$script: timeout $timeout is outside [5,30]"
    fi
  fi
done <<<"$rows"

[ "$n" -eq 11 ] || fail "want 11 hook entries, found $n"

printf 'RAN wiring-370 entries=%s async_true=%s\n' "$n" "$n_async_true" >> "$log"
exit $rc
