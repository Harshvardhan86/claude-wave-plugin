#!/usr/bin/env bash
# tests/cases/lock-252-two-concurrent.sh — AC-252: two subagent-stop processes
# started at the same time against one state file and one ledger.
#
# Started as real concurrent processes, not driven one after the other: the
# property under test is that the lock serialises a read-modify-write whose
# temp-file rename REPLACES the state inode, and a sequential driver cannot
# observe that at all.
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

WV_PROJECT="$(mkproj)"
mkdir -p "$WV_PROJECT/.wave"
: > "$WV_PROJECT/.wave/lock"
st="$WV_RUN_TMP/$name-state.json"
stop_state "$st" ".active = {a1: $(stop_active AC reviewer opus),
                             a2: $(stop_active TDE-RED reviewer sonnet)}" || exit 1
cp "$st" "$WV_PROJECT/.wave/state.json"
printf 'AC-1 records the spend\n' > "$WV_PROJECT/.wave/ac.md"
printf 'RED-VERIFIED failing=7\n' > "$WV_PROJECT/.wave/red.md"

fire() {
  # fire <agent> — one real, concurrent invocation of the hook.
  local a="$1"
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
}

fire a1
fire a2
wait

for a in a1 a2; do
  [ "$(cat "$WV_RUN_TMP/$name-$a.rc" 2>/dev/null)" = "0" ] || \
    fail "$a: exit $(cat "$WV_RUN_TMP/$name-$a.rc" 2>/dev/null), want 0"
done

lines="$(stop_ledger_count)"
[ "$lines" = "2" ] || fail "ledger has $lines line(s), want 2"
n=0
while IFS= read -r l; do
  printf '%s' "$l" | jq -e 'type == "object" and has("agent")' >/dev/null 2>&1 || \
    fail "a torn or unparseable ledger line: $l"
  n=$((n + 1))
done < "$WV_PROJECT/.wave/ledger.jsonl"
[ "$n" = "2" ] || fail "read $n well-formed line(s), want 2"

jq -e 'type == "object"' "$WV_PROJECT/.wave/state.json" >/dev/null 2>&1 || \
  fail "state.json does not parse after two concurrent writers"
[ "$(stop_phase_status AC)" = "done" ] || fail "AC is '$(stop_phase_status AC)', want done"
[ "$(stop_phase_status TDE-RED)" = "done" ] || \
  fail "TDE-RED is '$(stop_phase_status TDE-RED)', want done — a lost update drops one of the two"

exit $rc
