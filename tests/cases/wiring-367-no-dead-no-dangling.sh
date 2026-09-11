#!/usr/bin/env bash
# tests/cases/wiring-367-no-dead-no-dangling.sh — AC-367.
#
# Every scripts/hooks/*.sh (excluding lib.sh, which is a library, never a
# hook entry point) is referenced by at least one hooks.json entry (no dead
# script), and every hooks.json entry resolves to a real script under
# scripts/hooks/ (no dangling entry).
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
  printf 'RAN wiring-367 hooks.json=absent\n' >> "$log"
  exit 1
fi

CLAUDE_PLUGIN_ROOT="$WV_REPO_ROOT"

declare -A referenced=()
commands="$(jq -r '.hooks[][]?.hooks[]?.command // empty' "$hooks_json" 2>/dev/null)"
n_entries=0
while IFS= read -r cmd; do
  [ -z "$cmd" ] && continue
  n_entries=$((n_entries + 1))
  resolved="$(eval "printf '%s' $cmd" 2>/dev/null)"
  case "$resolved" in
    "$WV_REPO_ROOT/scripts/hooks/"*.sh)
      referenced["$(basename "$resolved")"]=1
      ;;
    *)
      fail "dangling entry, does not resolve under scripts/hooks/: $cmd -> $resolved"
      ;;
  esac
done <<<"$commands"

declare -a dead=()
for f in "$WV_REPO_ROOT"/scripts/hooks/*.sh; do
  b="$(basename "$f")"
  [ "$b" = "lib.sh" ] && continue
  if [ -z "${referenced[$b]:-}" ]; then
    dead+=("$b")
  fi
done

if [ ${#dead[@]} -gt 0 ]; then
  fail "dead script(s), never referenced by hooks.json: ${dead[*]}"
fi

printf 'RAN wiring-367 entries=%s referenced=%s dead=%s\n' \
  "$n_entries" "${#referenced[@]}" "${#dead[@]}" >> "$log"
exit $rc
