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
make_case() {
  jq --rawfile state "$WV_TESTS_DIR/fixtures/state/bgwait-ac-reviewer.json" \
    '.seed.files[".wave/state.json"] //= $state | del(.seed.state)' "$base" > "$c.base" || exit 1
  jq "$1" "$c.base" > "$c" || exit 1
}
run_stop() { run_hook subagent-stop.sh "$c" || fail "hook run failed"; }

make_case '.seed.files[".wave/state.json"] |= (fromjson | .mode = "solo" | tojson)'
run_stop
assert_silent || rc=1
assert_state '.bg_blocked == null and .bg_orphaned == null' || rc=1
WV_PROJECT="$(mkproj)"
make_case '.seed.files[".wave/state.json"] |= (fromjson | .enforce = "warn" | tojson)'
run_stop
assert_allow || rc=1
assert_state '.bg_blocked == null and .phases.AC.status == "done" and .bg_orphaned.a1.ids == ["b2emx28v6"]' || rc=1
assert_ledger_lines 1 || rc=1
assert_ledger_line '.bg_orphaned == ["b2emx28v6"] and any(.warn[]; contains("[W-BGWAIT]"))' || rc=1
# No map, missing array and malformed arrays are unmeasured, not a block.
for filter in 'del(.stdin.background_tasks)' '.stdin.background_tasks = {}' '.seed.files[".wave/state.json"] |= (fromjson | del(.bg_tasks) | tojson)'; do
  WV_PROJECT="$(mkproj)"
  make_case "$filter"
  run_stop
  assert_allow || rc=1
  assert_state '.bg_blocked == null and .bg_orphaned == null' || rc=1
done

exit $rc
