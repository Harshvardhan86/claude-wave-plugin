#!/usr/bin/env bash
# tests/cases/lock-253-twenty-concurrent.sh — AC-253: twenty concurrent stops.
# Twenty ledger lines, a state file that still parses, twenty recorded stops, and
# every process exiting 0 with no lock timeout (the spool directory must stay
# empty — a spooled line means someone waited out the full ten seconds).
#
# All twenty are TDE-GREEN executors: the executor is not that phase's closing
# role, so no artifact check runs and the case measures the lock and nothing
# else. The round counter still moves exactly once, when the last of the twenty
# stops.
set -u

# shellcheck source=tests/lib/assert.sh
source "$(dirname "$0")/../lib/assert.sh"
# shellcheck source=tests/lib/stop.sh
source "$(dirname "$0")/../lib/stop.sh"

name="${WV_CASE_NAME:-$(basename "$0" .sh)}"
log="${WV_CASE_LOG:-$WV_RUN_TMP/logs/$name.log}"
rc=0
fail() { printf 'ASSERT FAIL: %s\n' "$*" >&2; rc=1; }
printf 'RAN subagent-stop.sh %s decision=concurrent\n' "$name" >> "$log"

N=20
WV_PROJECT="$(mkproj)"
mkdir -p "$WV_PROJECT/.wave"
: > "$WV_PROJECT/.wave/lock"

filter='.active = {'
i=1
while [ "$i" -le "$N" ]; do
  filter="$filter a$i: $(stop_active TDE-GREEN executor sonnet),"
  i=$((i + 1))
done
filter="${filter%,} }"
st="$WV_RUN_TMP/$name-state.json"
stop_state "$st" "$filter" || exit 1
cp "$st" "$WV_PROJECT/.wave/state.json"

i=1
while [ "$i" -le "$N" ]; do
  a="a$i"
  jq -nc --arg a "$a" '{
    session_id: "1a2b0599-4617-4e73-a9c0-2bef462b2626",
    transcript_path: "/tmp/wave-plugin-tests/transcript.jsonl",
    cwd: ".", prompt_id: "c1f033ea-e4ee-4474-88ec-3913700ae39d",
    permission_mode: "bypassPermissions", agent_id: $a, agent_type: "general-purpose",
    hook_event_name: "SubagentStop", stop_hook_active: false,
    last_assistant_message: "done", background_tasks: [], session_crons: []
  }' > "$WV_RUN_TMP/$name-$a.stdin"
  ( cd "$WV_PROJECT" && bash "$WV_REPO_ROOT/scripts/hooks/subagent-stop.sh" \
      < "$WV_RUN_TMP/$name-$a.stdin" > "$WV_RUN_TMP/$name-$a.out" 2> "$WV_RUN_TMP/$name-$a.err"
    printf '%s' "$?" > "$WV_RUN_TMP/$name-$a.rc" ) &
  i=$((i + 1))
done
wait

i=1
while [ "$i" -le "$N" ]; do
  a="a$i"
  [ "$(cat "$WV_RUN_TMP/$name-$a.rc" 2>/dev/null)" = "0" ] || \
    fail "$a: exit $(cat "$WV_RUN_TMP/$name-$a.rc" 2>/dev/null), want 0"
  [ -z "$(cat "$WV_RUN_TMP/$name-$a.out" 2>/dev/null)" ] || \
    fail "$a: stdout must be empty, got '$(cat "$WV_RUN_TMP/$name-$a.out")'"
  i=$((i + 1))
done

printf 'ledger_lines=%s\n' "$(stop_ledger_count)"
[ "$(stop_ledger_count)" = "$N" ] || fail "ledger has $(stop_ledger_count) line(s), want $N"
jq -e 'type == "object"' "$WV_PROJECT/.wave/state.json" >/dev/null 2>&1 || \
  fail "state.json does not parse after $N concurrent writers"

bad=0
while IFS= read -r l; do
  printf '%s' "$l" | jq -e 'has("agent")' >/dev/null 2>&1 || bad=$((bad + 1))
done < "$WV_PROJECT/.wave/ledger.jsonl"
[ "$bad" = "0" ] || fail "$bad ledger line(s) are torn or unparseable"

uniq_agents="$(jq -r '.agent' "$WV_PROJECT/.wave/ledger.jsonl" 2>/dev/null | sort -u | wc -l | tr -d ' ')"
[ "$uniq_agents" = "$N" ] || fail "$uniq_agents distinct agents in the ledger, want $N"

stopped="$(jq -r '[.active | to_entries[] | select(.value.status == "stopped")] | length' "$WV_PROJECT/.wave/state.json")"
[ "$stopped" = "$N" ] || fail "$stopped recorded stops in state.active, want $N"

[ ! -e "$WV_PROJECT/.wave/ledger.pending" ] || \
  [ -z "$(ls -A "$WV_PROJECT/.wave/ledger.pending" 2>/dev/null)" ] || \
  fail "ledger.pending is not empty: someone waited out the full lock timeout"

rounds="$(jq -r '(.rounds["TDE-GREEN/executor"] // 0) | tostring' "$WV_PROJECT/.wave/state.json")"
[ "$rounds" = "1" ] || fail "rounds is $rounds, want 1 — one concurrent group is one round"

exit $rc
