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

make_case '.stdin.agent_id = "a1"'
run_hook post-bash.sh "$c" || rc=1
assert_silent || rc=1
assert_state '.bg_tasks.a1 == ["b2emx28v6"]' || rc=1
make_case 'del(.seed) | .stdin.agent_id = "a1"'
run_hook post-bash.sh "$c" || rc=1
assert_state '.bg_tasks.a1 == ["b2emx28v6"]' || rc=1
make_case 'del(.seed) | .stdin.agent_id = "a1" | .stdin.tool_response.backgroundTaskId = "quote\"x\n"'
run_hook post-bash.sh "$c" || rc=1
assert_state '.bg_tasks.a1 == ["b2emx28v6","quote\"x\n"]' || rc=1
# Literal true only, plus event/tool/mode guards.
for filter in '.stdin.tool_input.run_in_background = "true"' '.stdin.tool_input.run_in_background = false' '.stdin.tool_name = "Read"' '.stdin.hook_event_name = "PreToolUse"' '.seed.files[".wave/state.json"] |= (fromjson | .mode = "solo" | tojson)'; do
  WV_PROJECT="$(mkproj)"
  make_case ".stdin.agent_id = \"a1\" | $filter"
  run_hook post-bash.sh "$c" || rc=1
  assert_silent || rc=1
  assert_state '.bg_tasks == null' || rc=1
done

# A closed wave must not rewrite state or acquire a lock.
WV_PROJECT="$(mkproj)"
make_case '.stdin.agent_id = "a1" | .seed.files[".wave/state.json"] |= (fromjson | .status = "closed" | tojson)'
run_hook post-bash.sh "$c" || rc=1
assert_silent || rc=1
touch -t 202001010000 "$WV_PROJECT/.wave/state.json"
before="$(stat -c '%y' "$WV_PROJECT/.wave/state.json")"
jq 'del(.seed)' "$c" > "$c.tmp" && mv "$c.tmp" "$c"
run_hook post-bash.sh "$c" || rc=1
assert_silent || rc=1
[ "$before" = "$(stat -c '%y' "$WV_PROJECT/.wave/state.json")" ] || fail 'closed state mtime changed'
[ ! -e "$WV_PROJECT/.wave/lock" ] || fail 'closed wave took a lock'

exit $rc
