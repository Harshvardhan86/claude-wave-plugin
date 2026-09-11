#!/usr/bin/env bash
# tests/cases/bash-284-compound-deny.sh — AC-284.
#
# The `[;&|]` alternative in the runner regex must catch a runner reached
# through a real compound-command shape: `&&`, `;` and `|`.
set -u

# shellcheck source=tests/lib/assert.sh
source "$(dirname "$0")/../lib/assert.sh"

name="${WV_CASE_NAME:-$(basename "$0" .sh)}"
log="${WV_CASE_LOG:-$WV_RUN_TMP/logs/$name.log}"
rc=0
fail() { printf 'ASSERT FAIL: %s\n' "$*" >&2; rc=1; }

WV_PROJECT=""
WV_PROJECT="$(mkproj)"
seed_state state/valid-full.json

drive() {
  local cmd="$1" stdin errf
  stdin="$(jq -nc --arg c "$cmd" '{hook_event_name:"PreToolUse", tool_name:"Bash", tool_input:{command:$c}}')"
  errf="$(mktemp "$WV_RUN_TMP/$name.stderr.XXXXXX")"
  WV_LAST_STDOUT="$(cd "$WV_PROJECT" && printf '%s' "$stdin" | bash "$WV_REPO_ROOT/scripts/hooks/pre-bash.sh" 2>"$errf")"
  WV_LAST_EXIT=$?
  WV_LAST_STDERR="$(cat "$errf")"
  rm -f "$errf"
}

commands=(
  'cd sub && npm test'
  'echo hi; pytest'
  'foo | npx vitest run'
)

n=0
for cmd in "${commands[@]}"; do
  drive "$cmd"
  n=$((n + 1))
  printf 'RAN pre-bash.sh %s#%s decision=%s\n' "$name" "$n" "$(_wv_classify_decision)" >> "$log"
  assert_deny W-BASH || fail "command '$cmd': $WV_ASSERT_DIFF"
done
printf 'RAN pre-bash.sh %s decision=multi\n' "$name" >> "$log"

[ "$n" -eq "${#commands[@]}" ] || fail "ran $n of ${#commands[@]} commands"

exit $rc
