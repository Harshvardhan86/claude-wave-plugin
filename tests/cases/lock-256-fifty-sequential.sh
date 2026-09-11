#!/usr/bin/env bash
# tests/cases/lock-256-fifty-sequential.sh — AC-256: fifty sequential state writes.
#
# `.wave/lock`'s inode must be unchanged afterwards — the lock file is dedicated
# and never replaced, which is why the lock is taken on it and not on
# `state.json` (whose inode the temp-file rename replaces on every single write,
# so a holder of that lock would be guarding a file that is no longer the state).
# And the state must be the composition of all fifty writes, not the last one:
# fifty recorded stops and fifty ledger lines.
set -u

# shellcheck source=tests/lib/assert.sh
source "$(dirname "$0")/../lib/assert.sh"
# shellcheck source=tests/lib/stop.sh
source "$(dirname "$0")/../lib/stop.sh"

name="${WV_CASE_NAME:-$(basename "$0" .sh)}"
log="${WV_CASE_LOG:-$WV_RUN_TMP/logs/$name.log}"
rc=0
fail() { printf 'ASSERT FAIL: %s\n' "$*" >&2; rc=1; }
printf 'RAN subagent-stop.sh %s decision=sequential\n' "$name" >> "$log"

N=50
WV_PROJECT="$(mkproj)"
mkdir -p "$WV_PROJECT/.wave"
: > "$WV_PROJECT/.wave/lock"
lock_inode_before="$(stat -c %i "$WV_PROJECT/.wave/lock")"

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
state_inode_before="$(stat -c %i "$WV_PROJECT/.wave/state.json")"

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
  }' > "$WV_RUN_TMP/$name.stdin"
  out="$(cd "$WV_PROJECT" && bash "$WV_REPO_ROOT/scripts/hooks/subagent-stop.sh" \
    < "$WV_RUN_TMP/$name.stdin" 2>"$WV_RUN_TMP/$name.err")"
  wrc=$?
  [ "$wrc" = "0" ] || { fail "$a: exit $wrc, want 0"; break; }
  [ -z "$out" ] || { fail "$a: stdout must be empty, got '$out'"; break; }
  i=$((i + 1))
done

[ "$(stat -c %i "$WV_PROJECT/.wave/lock")" = "$lock_inode_before" ] || \
  fail "the lock file's inode changed: it was replaced instead of being held"
[ "$(stat -c %i "$WV_PROJECT/.wave/state.json")" != "$state_inode_before" ] || \
  fail "state.json's inode never changed, so the writes did not go through the temp-file rename"
[ "$(stop_ledger_count)" = "$N" ] || fail "ledger has $(stop_ledger_count) line(s), want $N"
stopped="$(jq -r '[.active | to_entries[] | select(.value.status == "stopped")] | length' "$WV_PROJECT/.wave/state.json")"
[ "$stopped" = "$N" ] || \
  fail "$stopped recorded stops, want $N — the state must be the composition of all $N writes"
jq -e 'type == "object" and (.schema == 1) and (.status == "active")' "$WV_PROJECT/.wave/state.json" >/dev/null 2>&1 || \
  fail "state.json lost its own keys along the way"

exit $rc
