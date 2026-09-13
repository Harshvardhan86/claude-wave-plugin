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

make_case '.stdin.stop_hook_active = true'
run_stop
assert_allow || rc=1
assert_state '.bg_blocked == null and .bg_orphaned == null' || rc=1
for collision in lean artifact; do
  WV_PROJECT="$(mkproj)"
  if [ "$collision" = lean ]; then
    make_case '.stdin.last_assistant_message = ("L" * 2001)'
    wanted=W-LONG-RETURN
  else
    make_case 'del(.seed.files[".wave/ac.md"])'
    wanted=W-ARTIFACT
  fi
  run_stop
  assert_block "$wanted" || rc=1
  assert_state '.bg_blocked == null' || rc=1
  jq 'del(.seed) | .stdin.stop_hook_active = true' "$c" > "$c.next"; mv "$c.next" "$c"
  run_stop
  assert_allow || rc=1
  assert_state '.bg_blocked == null and .bg_orphaned == null' || rc=1
done

exit $rc
