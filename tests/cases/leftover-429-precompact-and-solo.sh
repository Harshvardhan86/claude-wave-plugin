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
wv_on_exit 'kill "$watcher" 2>/dev/null; wait 2>/dev/null'
lo_run pre-compact.sh
assert_allow || rc=1
[ -z "$WV_LAST_STDOUT" ] || fail 'PreCompact wrote stdout'
assert_stderr_contains W-LEFTOVER || rc=1
lo_checkpoint
lo_contains "watcher: $watcher "
kill -0 "$watcher" 2>/dev/null || fail 'PreCompact killed watcher'
# Solo Stop uses its existing nonempty-ledger eligibility; warn mode is
# unchanged: a full-mode Stop on a complete wave that is not closed says
# W-STATE whatever `enforce` is (a Stop never closes a wave; the leftover warning waits for the
# close), and the inventory still lands.
for mode in solo warn; do
  WV_PROJECT="$(mkproj)"
  seed_state state/full-all-done.json
  if [ "$mode" = solo ]; then filter='.mode = "solo"'; else filter='.enforce = "warn"'; fi
  jq "$filter" "$WV_PROJECT/.wave/state.json" > "$lo_c.state" && mv "$lo_c.state" "$WV_PROJECT/.wave/state.json"
  lo_case 'del(.seed.state)'
  lo_run stop.sh
  if [ "$mode" = solo ]; then
    assert_warn W-LEFTOVER || rc=1
  else
    assert_warn W-STATE || rc=1
    assert_reason_contains 'leftovers found' || rc=1
    [ ! -e "$WV_PROJECT/.wave/.leftover-warned" ] || fail 'warn-mode Stop on an unclosed wave wrote .leftover-warned'
  fi
  lo_checkpoint
  lo_contains b2
done

exit $rc
