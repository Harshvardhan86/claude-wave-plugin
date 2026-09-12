#!/usr/bin/env bash
set -u
source "$(dirname "$0")/../lib/assert.sh"
name="${WV_CASE_NAME:-$(basename "$0" .sh)}"
log="${WV_CASE_LOG:-$WV_RUN_TMP/logs/$name.log}"
rc=0
fail() { printf 'ASSERT FAIL: %s\n' "$*" >&2; rc=1; }
c="$WV_RUN_TMP/$name.json"
base="$WV_TESTS_DIR/cases/bgwait-405-running-block.json"
printf 'RAN subagent-stop.sh %s decision=multi\n' "$name" >> "$log"
source "$WV_TESTS_DIR/fixtures/bgwait-case.sh"

for flag in true false long; do
  WV_PROJECT="$(mkproj)"
  make_case '.'
  run_stop
  assert_block W-BGWAIT || rc=1
  assert_ledger_lines 0 || rc=1
  if [ "$flag" = long ]; then
    make_case 'del(.seed) | .stdin.stop_hook_active = false | .stdin.last_assistant_message = ("L" * 2001)'
  else
    make_case "del(.seed) | .stdin.stop_hook_active = $flag"
  fi
  run_stop
  if [ "$flag" = long ]; then assert_block W-LONG-RETURN || rc=1; else assert_allow || rc=1; fi
  assert_state '.phases.AC.status == "failed" and .bg_orphaned.a1 == {phase:"AC",ids:["b2emx28v6"]}' || rc=1
  assert_ledger_lines 1 || rc=1
  assert_ledger_line '.agent == "a1" and .bg_orphaned == ["b2emx28v6"]' || rc=1
  before="$(cat "$WV_PROJECT/.wave/state.json")"
  run_stop
  assert_allow || rc=1
  assert_ledger_lines 1 || rc=1
  [ "$before" = "$(cat "$WV_PROJECT/.wave/state.json")" ] || fail 'replay changed state'
done

# A persisted wait latch is not an orphan if the task finishes before retry.
WV_PROJECT="$(mkproj)"
make_case '.'
run_stop
assert_block W-BGWAIT || rc=1
make_case 'del(.seed) | .stdin.stop_hook_active = true | .stdin.background_tasks |= map(select(.type == "subagent"))'
run_stop
assert_allow || rc=1
assert_state '.phases.AC.status == "done" and .bg_orphaned == null' || rc=1
assert_ledger_lines 1 || rc=1
assert_ledger_line '.bg_orphaned == null' || rc=1

exit $rc
