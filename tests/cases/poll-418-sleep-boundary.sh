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
  10 'sleep:inf' 'sleep inf'
  19 '' 'sleep $VAR'
  21 '' 'sleep 300'
  22 '' 'sleep 300s'
  23 '' 'sleep 300.5'
  24 '' 'sleep 4m'
  25 'sleep:301' 'sleep 301'
  26 'sleep:600' 'sleep 10m'
  27 'sleep:3600' 'sleep 1h'
  28 'sleep:inf' 'sleep 2d'
  31 '' 'sleep 60'
  32 '' 'sleep 1m'
  36 'sleep:inf' 'sleep infinity'
  39 'sleep:400' 'npm test && sleep 400'
  46 '' 'sleep 5m'
  47 'sleep:600' 'sleep 5; sleep 10m'
  49 'sleep:400' "bash -c 'sleep 400'"
  51 '' 'sleep 300.9'
  52 'sleep:301' 'sleep 301.0'
  zsh-sleep 'sleep:400' "zsh -c 'sleep 400'"
  quoted-sleep '' 'echo "sleep 400"'
  subagent-sleep 'sleep:400' 'sleep 400'
  sleep-flags-bound '' 'sleep -- 500'
)
for ((i=0; i<${#vectors[@]}; i+=3)); do
  wv_poll_test_one "${vectors[i]}" "${vectors[i+1]}" "${vectors[i+2]}"
done

[ "$n" -eq 23 ] || rc=1
exit $rc
