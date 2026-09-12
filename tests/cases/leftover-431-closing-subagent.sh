#!/usr/bin/env bash
set -u
source "$(dirname "$0")/../lib/assert.sh"
name="${WV_CASE_NAME:-$(basename "$0" .sh)}"
log="${WV_CASE_LOG:-$WV_RUN_TMP/logs/$name.log}"
rc=0
fail() { printf 'ASSERT FAIL: %s\n' "$*" >&2; rc=1; }
source "$WV_TESTS_DIR/fixtures/leftover-case.sh"

source "$WV_TESTS_DIR/lib/stop.sh"
for variant in leftover self-only; do
  WV_PROJECT="$(mkproj)"
  st="$WV_RUN_TMP/$name-state.json"
  stop_state "$st" ".active = {a1: $(stop_active AD executor haiku)}" || exit 1
  stop_case "$lo_c" " .seed.state = \"$st\" " || exit 1
  if [ "$variant" = leftover ]; then
    jq '.stdin.background_tasks += [{id:"lo-shell",type:"shell",status:"running"}] | .stdin.session_crons = [{id:"lo-cron"}]' "$lo_c" > "$lo_c.tmp" && mv "$lo_c.tmp" "$lo_c"
  fi
  lo_run subagent-stop.sh
  assert_allow || rc=1
  [ -z "$WV_LAST_STDOUT" ] || fail 'closing stop wrote stdout'
  assert_state '.status == "closed" and .phases.AD.status == "done"' || rc=1
  lo_checkpoint
  lo_contains '(SubagentStop)'
  if [ "$variant" = leftover ]; then
    assert_stderr_contains W-LEFTOVER || rc=1
    lo_contains lo-shell
    lo_contains lo-cron
  else
    assert_silent || rc=1
    lo_contains 'tasks=none; crons=none; watchers=none; unavailable=none'
  fi
done

exit $rc
