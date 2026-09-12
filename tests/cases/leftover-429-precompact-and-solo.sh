#!/usr/bin/env bash
set -u
source "$(dirname "$0")/../lib/assert.sh"
name="${WV_CASE_NAME:-$(basename "$0" .sh)}"
log="${WV_CASE_LOG:-$WV_RUN_TMP/logs/$name.log}"
rc=0
fail() { printf 'ASSERT FAIL: %s\n' "$*" >&2; rc=1; }
source "$WV_TESTS_DIR/fixtures/leftover-case.sh"

WV_PROJECT="$(mkproj)"
seed_state state/solo.json
lo_case 'del(.seed) | .stdin = {hook_event_name:"PreCompact",trigger:"manual"}'
lo_run pre-compact.sh
assert_silent || rc=1
lo_checkpoint
lo_contains 'background_tasks'
lo_contains 'session_crons'
(cd "$WV_PROJECT" && exec sleep 1000) & watcher=$!
trap 'kill "$watcher" 2>/dev/null; wait 2>/dev/null' EXIT
lo_run pre-compact.sh
assert_allow || rc=1
[ -z "$WV_LAST_STDOUT" ] || fail 'PreCompact wrote stdout'
assert_stderr_contains W-LEFTOVER || rc=1
lo_checkpoint
lo_contains "watcher: $watcher "
kill -0 "$watcher" 2>/dev/null || fail 'PreCompact killed watcher'
# Solo Stop uses its existing nonempty-ledger eligibility; warn mode is unchanged.
for mode in solo warn; do
  WV_PROJECT="$(mkproj)"
  seed_state state/full-all-done.json
  if [ "$mode" = solo ]; then filter='.mode = "solo"'; else filter='.enforce = "warn"'; fi
  jq "$filter" "$WV_PROJECT/.wave/state.json" > "$lo_c.state" && mv "$lo_c.state" "$WV_PROJECT/.wave/state.json"
  lo_case 'del(.seed.state)'
  lo_run stop.sh
  assert_warn W-LEFTOVER || rc=1
done

exit $rc
