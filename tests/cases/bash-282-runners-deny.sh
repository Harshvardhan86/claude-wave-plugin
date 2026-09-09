#!/usr/bin/env bash
# tests/cases/bash-282-runners-deny.sh — AC-282.
#
# Every one of the 19 commands the spec section 8.3 regex names must deny
# W-BASH. One case file, one project (no filesystem state matters here),
# looped like tests/cases/data-reasons.sh and budget-178.sh loop their own
# tables — so one failing command reads as one clear diagnostic line rather
# than as 19 near-duplicate case files.
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
  'npx jest'
  'pytest -q'
  'go test ./...'
  'cargo build'
  'cargo test'
  'dotnet test'
  'make'
  'tsc -p .'
  'ng test'
  'ng build'
  'vite build'
  'pnpm build'
  'yarn test'
  'npm run e2e'
  'npm run build'
  'npx playwright test'
  'vitest run'
  'mocha'
  'py.test'
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
