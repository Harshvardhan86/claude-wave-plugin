#!/usr/bin/env bash
# tests/cases/lock-254-timeout-spool.sh — AC-254: the lock is held by a LIVE
# process for longer than the ten-second timeout.
#
# The hook must exit 0 inside timeout + 1s, emit no block, and write its ledger
# line to `.wave/ledger.pending/<agent_id>.json` so no spend is lost; the timeout
# itself is recorded as W-STATE. The next successful acquisition drains the spool
# into `ledger.jsonl` exactly once.
#
# This case deliberately spends ~11 seconds of wall clock: a lock timeout cannot
# be observed faster than the timeout, and a shorter fake would test a different
# mechanism.
set -u

# shellcheck source=tests/lib/assert.sh
source "$(dirname "$0")/../lib/assert.sh"
# shellcheck source=tests/lib/stop.sh
source "$(dirname "$0")/../lib/stop.sh"

name="${WV_CASE_NAME:-$(basename "$0" .sh)}"
log="${WV_CASE_LOG:-$WV_RUN_TMP/logs/$name.log}"
rc=0
fail() { printf 'ASSERT FAIL: %s\n' "$*" >&2; rc=1; }
printf 'RAN subagent-stop.sh %s decision=multi\n' "$name" >> "$log"

WV_PROJECT="$(mkproj)"
mkdir -p "$WV_PROJECT/.wave"
: > "$WV_PROJECT/.wave/lock"
st="$WV_RUN_TMP/$name-state.json"
stop_state "$st" ".active = {a1: $(stop_active TDE-GREEN executor sonnet),
                             a2: $(stop_active TDE-GREEN executor sonnet)}" || exit 1
cp "$st" "$WV_PROJECT/.wave/state.json"

# A live holder. `flock -x` on the dedicated lock file, held for longer than the
# hook's own `flock -w 10`, with its pid recorded in the file the way lib.sh
# records it — so the stale-lock steal correctly refuses to fire here.
flock -x "$WV_PROJECT/.wave/lock" -c 'printf "%s\n" $PPID > /dev/null; sleep 13' &
holder=$!
sleep 1

fire() { # fire <agent>
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
      < "$WV_RUN_TMP/$name-$a.stdin" > "$WV_RUN_TMP/$name-$a.out" 2> "$WV_RUN_TMP/$name-$a.err" )
  printf '%s' "$?"
}

start="$SECONDS"
got_rc="$(fire a1)"
elapsed=$((SECONDS - start))

[ "$got_rc" = "0" ] || fail "a1: exit $got_rc, want 0 — a lock timeout never fails the hook"
[ "$elapsed" -le 11 ] || fail "a1 took ${elapsed}s, want no more than 11 (timeout + 1)"
[ "$elapsed" -ge 9 ] || fail "a1 took only ${elapsed}s, so it did not actually wait on the lock"
[ -z "$(cat "$WV_RUN_TMP/$name-a1.out")" ] || \
  fail "a1: stdout must be empty (no block), got '$(cat "$WV_RUN_TMP/$name-a1.out")'"
[ -f "$WV_PROJECT/.wave/ledger.pending/a1.json" ] || \
  fail "a1: the ledger line must be spooled to .wave/ledger.pending/a1.json"
jq -e 'has("agent") and .agent == "a1"' < "$WV_PROJECT/.wave/ledger.pending/a1.json" >/dev/null 2>&1 || \
  fail "a1: the spooled line is not the agent's own ledger line"
case "$(cat "$WV_RUN_TMP/$name-a1.err")" in
  *W-STATE*) : ;;
  *) fail "a1: the timeout must be recorded as W-STATE, got '$(cat "$WV_RUN_TMP/$name-a1.err")'" ;;
esac
[ "$(stop_ledger_count)" = "0" ] || fail "a1: nothing may reach ledger.jsonl while the lock is held"

# Release the lock. Now a1 stops AGAIN — the platform's own second stop after the
# first one produced no result. It is already spooled, so it must not write a
# second line; and the drain must run anyway, on a stop that appends nothing of
# its own, or the spooled spend sits there until some unrelated agent happens to
# stop.
kill "$holder" 2>/dev/null
wait "$holder" 2>/dev/null
got_rc="$(fire a1)"
[ "$got_rc" = "0" ] || fail "a1 replay: exit $got_rc, want 0"
[ "$(stop_ledger_count)" = "1" ] || \
  fail "a1 replay: the ledger has $(stop_ledger_count) line(s), want 1 — the spooled line drained, and no second line for a1"
[ ! -f "$WV_PROJECT/.wave/ledger.pending/a1.json" ] || \
  fail "a1 replay: the spooled line must be removed once drained, or it drains twice"
jq -e '.agent == "a1"' < "$WV_PROJECT/.wave/ledger.jsonl" >/dev/null 2>&1 || \
  fail "a1 replay: the drained line is not a1's"

# And a2 appends its own on top.
got_rc="$(fire a2)"
[ "$got_rc" = "0" ] || fail "a2: exit $got_rc, want 0"
[ "$(stop_ledger_count)" = "2" ] || \
  fail "after a2 the ledger has $(stop_ledger_count) line(s), want 2"
[ "$(jq -r '.agent' "$WV_PROJECT/.wave/ledger.jsonl" | sort -u | tr '\n' ' ')" = "a1 a2 " ] || \
  fail "the ledger must hold a1 and a2 exactly once each, got $(jq -r '.agent' "$WV_PROJECT/.wave/ledger.jsonl" | tr '\n' ' ')"

exit $rc
