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

make_case '.seed.files[".wave/state.json"] |= (fromjson | .bg_tasks.a1 = ["t1","t2","a1","t3"] | tojson) | .stdin.background_tasks += [{id:"t2",type:"shell",status:"running"},{id:"t3",type:"shell",status:"completed"}]'
run_stop
assert_block W-BGWAIT || rc=1
assert_reason_contains t2 || rc=1
for id in t1 t3 a1 b2emx28v6; do assert_stdout_absent "$id" || rc=1; done

# Quotes and newlines belong to a single id, including a trailing newline.
WV_PROJECT="$(mkproj)"
make_case '.seed.files[".wave/state.json"] |= (fromjson | .bg_tasks.a1 = ["quote\"x\n"] | tojson) | .stdin.background_tasks = [{id:"quote\"x\n",type:"shell",status:"running"}]'
run_stop
assert_block W-BGWAIT || rc=1
printf '%s' "$WV_LAST_STDOUT" | jq -e '.decision == "block" and (.reason | contains("quote\"x\n"))' >/dev/null || fail 'id was split or block was not valid JSON'

exit $rc
