#!/usr/bin/env bash
set -u
source "$(dirname "$0")/../lib/assert.sh"
name="${WV_CASE_NAME:-$(basename "$0" .sh)}"
log="${WV_CASE_LOG:-$WV_RUN_TMP/logs/$name.log}"
rc=0
c="$WV_RUN_TMP/$name.json"
for cmd in 'npm test' 'timeout 600 npm test' 'timeout 600s npm test' 'timeout 10m npm test' 'while true; do sleep 301; done' 'npm test; while true; do sleep 1; done' 'while true; do echo W-BASH; done'; do
  jq --arg cmd "$cmd" '.stdin.tool_input.command = $cmd' "$WV_TESTS_DIR/cases/poll-415-while-true-deny.json" > "$c" || exit 1
  run_hook pre-bash.sh "$c" || rc=1
  case "$cmd" in
    'npm test'|'timeout 600 npm test'|'timeout 600s npm test'|'timeout 10m npm test') assert_deny W-BASH || rc=1 ;;
    *) assert_deny W-POLL || rc=1 ;;
  esac
  assert_single_rule_token || rc=1
  printf 'RAN pre-bash.sh %s decision=%s\n' "$name" "$(_wv_classify_decision)" >> "$log"
done
exit $rc
