#!/usr/bin/env bash
# Each numbered vector is exercised through the real hook in a subagent.
# Main-session build/test precedence is separately pinned by poll-421.
set -u
source "$(dirname "$0")/../lib/assert.sh"
name="${WV_CASE_NAME:-$(basename "$0" .sh)}"
log="${WV_CASE_LOG:-$WV_RUN_TMP/logs/$name.log}"
rc=0
n=0
c="$WV_RUN_TMP/$name.json"
WV_PROJECT="$(mkproj)"
seed_state state/valid-full.json
# Load matcher definitions only; the hook entry point is still driven below.
source <(sed -n '/^WV_POLL_LOOP_RE=/,/^wv_bash_matched_runner()/p' "$WV_REPO_ROOT/scripts/hooks/pre-bash.sh" | sed '$d')
wv_poll_test_one() {
  local id="$1" expected="$2" cmd="$3" got
  got="$(wv_poll_check "$cmd")"
  [ "$got" = "$expected" ] || { printf 'ASSERT FAIL: vector %s detail: expected %s, got %s\n' "$id" "$expected" "$got" >&2; rc=1; }
  jq -nc --arg cmd "$cmd" '{stdin:{hook_event_name:"PreToolUse",tool_name:"Bash",agent_id:"a1",tool_input:{command:$cmd}}}' > "$c" || exit 1
  run_hook pre-bash.sh "$c" || rc=1
  if [ -n "$expected" ]; then
    assert_deny W-POLL || { printf 'ASSERT FAIL: vector %s expected %s: %s\n' "$id" "$expected" "$cmd" >&2; rc=1; }
    assert_single_rule_token || rc=1
  else
    assert_silent || { printf 'ASSERT FAIL: vector %s expected silence: %s\n' "$id" "$cmd" >&2; rc=1; }
  fi
  n=$((n + 1))
  printf 'RAN pre-bash.sh %s#%s decision=%s\n' "$name" "$id" "$(_wv_classify_decision)" >> "$log"
}

vectors=(
  03 'loop' 'while :; do sleep 1; done'
  04 'loop' 'true && while :; do sleep 1; done'
  05 'loop' 'until false; do sleep 1; done'
  06 'loop' 'while true; do sleep 1; done; timeout 1 true'
  07 'loop' "timeout 0 bash -c 'while true; do sleep 1; done'"
  08 '' "timeout --foreground 600 bash -c 'while true; do sleep 1; done'"
  09 'loop' 'timeout $N bash -c '\''while true; do sleep 1; done'\'''
  11 '' 'echo "while true"'
  12 '' 'until false; do :; done'
  13 '' 'while:; do sleep 1; done'
  14 '' 'for i in $(seq 1 999); do sleep 1; done'
  15 '' 'watch -n 1 date'
  16 '' 'tail -f x.log'
  17 '' 'inotifywait -m .'
  18 '' 'yes | cat'
  20 '' "python -c 'time.sleep(999)'"
  29 'loop' 'while true'
  30 '' "timeout 600 bash -c 'until false; do sleep 5; done'"
  33 'loop' 'while :;'
  34 '' 'for i in 1 2 3; do sleep 1; done'
  35 '' 'until [ -f x ]; do true; done'
  37 '' 'tail -f log'
  38 '' 'watch -n1 ls'
  40 'loop' $'cat <<EOS\nwhile true\nEOS'
  41 '' 'yes | head'
  42 '' 'while [ ! -f x ]; do sleep 1; done'
  43 '' 'timeout 600 npm test'
  44 'loop' 'while true; do sleep 301; done'
  45 '' "timeout --preserve-status --foreground 600 bash -c 'while true; do sleep 1; done'"
  48 '' "echo 'while :'"
  50 'loop' 'true | while true; do sleep 1; done'
  pipe-true 'loop' 'while true|cat'
  pipe-colon 'loop' 'while :|cat'
  sh-code 'loop' "sh -c 'while true; do sleep 1; done'"
  inner-quote '' "bash -c 'echo \"while true\"'"
  nested-code 'loop' "bash -c 'sh -c \"while true; do sleep 1; done\"'"
  other-shell 'loop' "dash -c 'while true; do sleep 1; done'"
  timeout-seconds '' "timeout 600s bash -c 'while true; do sleep 1; done'"
  timeout-minutes '' "timeout 10m bash -c 'while true; do sleep 1; done'"
  timeout-hours '' "timeout 1h bash -c 'while true; do sleep 1; done'"
  timeout-days '' "timeout 1d bash -c 'while true; do sleep 1; done'"
  timeout-zero-seconds 'loop' "timeout 0s bash -c 'while true; do sleep 1; done'"
  timeout-zero-minutes 'loop' "timeout 0m bash -c 'while true; do sleep 1; done'"
  timeout-later 'loop' "cd /x && timeout 600 bash -c 'while true; do sleep 1; done'"
  shell-flags-bound '' "bash --norc -c 'while true; do sleep 1; done'"
)
for ((i=0; i<${#vectors[@]}; i+=3)); do
  wv_poll_test_one "${vectors[i]}" "${vectors[i+1]}" "${vectors[i+2]}"
done

# Build valid nested double-quoted shell arguments to pin both sides of depth 3.
nested='sleep 400'
for depth in 1 2 3 4; do
  escaped="${nested//\\/\\\\}"
  escaped="${escaped//\"/\\\"}"
  nested="bash -c \"$escaped\""
  expected='sleep:400'
  [ "$depth" -lt 4 ] || expected=''
  wv_poll_test_one "depth-$depth" "$expected" "$nested"
done
[ "$n" -eq 49 ] || rc=1
exit $rc
