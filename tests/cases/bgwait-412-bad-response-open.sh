#!/usr/bin/env bash
set -u
source "$(dirname "$0")/../lib/assert.sh"
name="${WV_CASE_NAME:-$(basename "$0" .sh)}"
log="${WV_CASE_LOG:-$WV_RUN_TMP/logs/$name.log}"
rc=0
fail() { printf 'ASSERT FAIL: %s\n' "$*" >&2; rc=1; }
c="$WV_RUN_TMP/$name.json"
base="$WV_TESTS_DIR/cases/bgwait-411-no-agentid-no-record.json"
printf 'RAN post-bash.sh %s decision=multi\n' "$name" >> "$log"
source "$WV_TESTS_DIR/fixtures/bgwait-case.sh"

for response in '"text"' '{"taskId":"x"}' '{}' '{"backgroundTaskId":17}' '{"backgroundTaskId":""}' 'null'; do
  WV_PROJECT="$(mkproj)"
  make_case ".stdin.agent_id = \"a1\" | .stdin.tool_response = $response"
  run_hook post-bash.sh "$c" || rc=1
  assert_allow || rc=1
  assert_stderr_contains W-STATE || rc=1
  assert_state '.bg_tasks == null' || rc=1
done

exit $rc
