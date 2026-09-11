#!/usr/bin/env bash
# tests/cases/lib-concurrency.sh — the counting proof for `wv_state_update`
# and `wv_ledger_append`.
#
# The design review settled the locking shape by argument (a `tmp && mv` under
# a flock on state.json loses updates, because the rename replaces the locked
# inode, so the lock must live on a separate `.wave/lock`). This case settles
# it by counting instead: N concurrent library processes each increment
# `.rounds.n` by 1, and the file must end at exactly N. A lost update is a
# count below N.
#
# It carries its own anti-vacuity control first: the same N racers doing an
# *unlocked* read-modify-write with a deliberate gap between the read and the
# write, which must lose updates (count < N). Without that control, "count ==
# N" could mean the racers never actually overlapped.
set -u

# shellcheck source=tests/lib/assert.sh
source "$(dirname "$0")/../lib/assert.sh"

name="$(basename "$0" .sh)"
DRIVER="$WV_REPO_ROOT/tests/fixtures/drive-lib.sh"

stdin_json='{"hook_event_name":"PreToolUse","tool_name":"Agent","cwd":"."}'

rc=0
fail() { printf 'ASSERT FAIL: %s\n' "$*" >&2; rc=1; }

# ---- one ordinary run: seeds the project and writes the run marker --------
case_file="$WV_RUN_TMP/$name.json"
jq -n '{
  script: "tests/fixtures/drive-lib.sh",
  env: { WV_DRIVE: "update:.rounds.n = 0" },
  seed: { state: "state/valid-full.json" },
  stdin: {
    hook_event_name: "PreToolUse",
    tool_name: "Agent",
    cwd: ".",
    tool_input: {
      description: "probe dispatch",
      prompt: "Do the thing.",
      subagent_type: "general-purpose",
      model: "sonnet"
    },
    tool_use_id: "toolu_016jDXUebmA9qCw58g1rxGuH"
  }
}' > "$case_file"

WV_PROJECT=""
if ! run_hook tests/fixtures/drive-lib.sh "$case_file"; then
  printf 'run_hook could not run the library: %s\n' "$WV_LAST_STDERR" >&2
  exit 1
fi
assert_exit 0 || rc=1
assert_state '.rounds.n == 0' || rc=1

state="$WV_PROJECT/.wave/state.json"
errlog="$WV_RUN_TMP/$name.racer-stderr"
: > "$errlog"

reset_n() {
  jq '.rounds.n = 0' "$state" > "$state.reset" && mv "$state.reset" "$state"
}
read_n() { jq -r '.rounds.n' "$state"; }

# ---- control: N unlocked racers must lose updates ------------------------
unlocked_burst() {
  local n="$1" i
  local -a pids=()
  for ((i = 0; i < n; i++)); do
    (
      cd "$WV_PROJECT" || exit 1
      # NB: the temp name is computed once, into a variable. `$BASHPID` inside a
      # redirection word expands in the process bash forks to run the command,
      # so writing it inline would name a different file in the redirect than in
      # the mv — which is exactly how an earlier version of this control wrote
      # nothing at all and "detected" a lost update it never caused.
      tmp=".wave/ctl.$BASHPID.tmp"
      v="$(jq -r '.rounds.n // 0' .wave/state.json)"
      sleep 0.05
      jq ".rounds.n = $((v + 1))" .wave/state.json > "$tmp" && mv "$tmp" .wave/state.json
    ) &
    pids+=("$!")
  done
  for i in "${pids[@]}"; do wait "$i"; done
}

# ---- the real thing: N concurrent library processes ----------------------
locked_burst() {
  local n="$1" i
  local -a pids=()
  for ((i = 0; i < n; i++)); do
    (
      cd "$WV_PROJECT" || exit 1
      printf '%s' "$stdin_json" |
        env WV_DRIVE='update:.rounds.n = ((.rounds.n // 0) + 1)' bash "$DRIVER" \
        >/dev/null 2>>"$errlog"
    ) &
    pids+=("$!")
  done
  local bad=0
  for i in "${pids[@]}"; do wait "$i" || bad=$((bad + 1)); done
  [ "$bad" = "0" ] || fail "$bad of $n concurrent library processes exited non-zero"
}

reset_n
unlocked_burst 20
control_n="$(read_n)"
printf 'concurrency: unlocked control, 20 racers -> .rounds.n = %s (must be < 20)\n' "$control_n"
case "$control_n" in
  ''|*[!0-9]*) fail "unlocked control left .rounds.n unreadable: '$control_n'" ;;
  *) [ "$control_n" -lt 20 ] || fail "the unlocked control did not lose a single update ($control_n); this case cannot detect a lost update" ;;
esac

reset_n
locked_burst 2
n2="$(read_n)"
printf 'concurrency: wv_state_update, 2 racers  -> .rounds.n = %s (want 2)\n' "$n2"
[ "$n2" = "2" ] || fail "2 concurrent wv_state_update callers left .rounds.n = $n2, want 2"

reset_n
locked_burst 20
n20="$(read_n)"
printf 'concurrency: wv_state_update, 20 racers -> .rounds.n = %s (want 20)\n' "$n20"
[ "$n20" = "20" ] || fail "20 concurrent wv_state_update callers left .rounds.n = $n20, want 20"

# ---- the ledger append shares the same lock ------------------------------
ledger_burst() {
  local n="$1" i
  local -a pids=()
  for ((i = 0; i < n; i++)); do
    (
      cd "$WV_PROJECT" || exit 1
      printf '%s' "$stdin_json" |
        env WV_DRIVE="ledger:{\"event\":\"concurrency-probe\",\"i\":$i}" bash "$DRIVER" \
        >/dev/null 2>>"$errlog"
    ) &
    pids+=("$!")
  done
  for i in "${pids[@]}"; do wait "$i"; done
}

ledger_burst 20
lines="$(wc -l < "$WV_PROJECT/.wave/ledger.jsonl" 2>/dev/null || echo 0)"
printf 'concurrency: wv_ledger_append, 20 racers -> ledger.jsonl lines = %s (want 20)\n' "$lines"
[ "$lines" = "20" ] || fail "20 concurrent wv_ledger_append callers wrote $lines ledger lines, want 20"
bad_json="$(command grep -cv '^{' "$WV_PROJECT/.wave/ledger.jsonl")"
[ "$bad_json" = "0" ] || fail "$bad_json ledger lines are torn (do not start with '{')"

# ---- the lock-timeout path: spool, then drain exactly once ---------------
#
# Driven, not hoped for: an outside holder keeps `.wave/lock` while the library
# tries to take it, so the library MUST time out. It must then allow (never
# deny), warn, and spool its ledger line — and the next successful acquisition
# must merge that line exactly once. Counted at the sink, both times.
#
# TWO THINGS ARE DELIBERATE HERE, and both were previously left to luck:
#
#   * The HANDSHAKE. This used to be `sleep 0.5` and a hope that the holder had
#     taken the lock by then. Under load it had not, the library acquired
#     immediately, and the case then asserted spool behaviour against a run that
#     never timed out — a flake that reads as a real failure of the spool. The
#     holder now announces itself by creating a file AFTER `flock` returns, and
#     this shell waits for that file. No duration decides anything.
#   * The WAIT ITSELF. The shipped timeout is 10s and the holder therefore had to
#     outlive it, which cost this one case about 14 seconds of every suite run.
#     WV_LOCK_TIMEOUT_OVERRIDE drives the library's own wait down to 1s for this
#     step only, so the TIMEOUT PATH is what is being exercised rather than the
#     particular number of seconds it waits — the shipped 10s is asserted by
#     tests/cases/lock-254-timeout-spool.sh, against the default, where the
#     duration is the claim.
ledger_before="$(wc -l < "$WV_PROJECT/.wave/ledger.jsonl")"

held="$WV_RUN_TMP/$name.lock-held"
rm -f "$held"
( flock 9 && : > "$held" && exec sleep 30 ) 9>>"$WV_PROJECT/.wave/lock" &
holder=$!
waited=0
while [ ! -f "$held" ]; do
  # A bounded wait for the HANDSHAKE, not for the lock: if the holder cannot take
  # the lock at all, this case has measured nothing and says so rather than
  # asserting spool behaviour against a run that acquired normally.
  waited=$((waited + 1))
  if [ "$waited" -gt 200 ]; then
    fail "the outside lock holder never signalled that it holds .wave/lock, so the timeout path was not exercised"
    kill "$holder" 2>/dev/null
    exit $rc
  fi
  sleep 0.05
done

timeout_case="$WV_RUN_TMP/$name-timeout.json"
jq -n '{
  script: "tests/fixtures/drive-lib.sh",
  env: { WV_DRIVE: "ledger:{\"event\":\"spooled\"}", WV_LOCK_TIMEOUT_OVERRIDE: "1" },
  stdin: {
    hook_event_name: "PreToolUse",
    tool_name: "Agent",
    agent_id: "abe831e9837f3dcee",
    cwd: "."
  }
}' > "$timeout_case"

run_hook tests/fixtures/drive-lib.sh "$timeout_case" || { printf 'run_hook failed: %s\n' "$WV_LAST_STDERR" >&2; exit 1; }
assert_exit 0 || rc=1
assert_allow || rc=1

ctx="$(printf '%s' "$WV_LAST_STDOUT" | jq -r '.hookSpecificOutput.additionalContext // ""')"
case "$ctx" in
  "[W-STATE] "*) : ;;
  *) fail "lock timeout: additionalContext does not carry a rendered W-STATE: '$ctx'" ;;
esac
spool="$WV_PROJECT/.wave/ledger.pending/abe831e9837f3dcee.json"
[ -f "$spool" ] || fail "lock timeout: the ledger line was not spooled to $spool"
after_timeout="$(wc -l < "$WV_PROJECT/.wave/ledger.jsonl")"
[ "$after_timeout" = "$ledger_before" ] || \
  fail "lock timeout: the ledger grew from $ledger_before to $after_timeout while the lock was held"

# The holder is released by killing it, not by outliving it: nothing in this case
# depends on how long anything took.
kill "$holder" 2>/dev/null
wait "$holder" 2>/dev/null

# The next acquisition drains the spool exactly once. It must be an action that
# does NOT itself append, or the sink count could not tell a drain from an
# append: a state update takes the same lock and runs the same drain.
drain_case="$WV_RUN_TMP/$name-drain.json"
jq '.env.WV_DRIVE = "update:.rounds.n = 0"' "$timeout_case" > "$drain_case"
run_hook tests/fixtures/drive-lib.sh "$drain_case" || { printf 'run_hook failed: %s\n' "$WV_LAST_STDERR" >&2; exit 1; }
drained="$(wc -l < "$WV_PROJECT/.wave/ledger.jsonl")"
printf 'concurrency: lock timeout spooled 1 line, next acquisition drained -> ledger.jsonl lines = %s (want %s)\n' \
  "$drained" "$((ledger_before + 1))"
[ "$drained" = "$((ledger_before + 1))" ] || \
  fail "the spooled line was not drained exactly once: ledger has $drained lines, want $((ledger_before + 1))"
[ -e "$spool" ] && fail "the spool file survived its drain, so it can be drained twice"
[ "$(jq -rs '[.[] | select(.event == "spooled")] | length' "$WV_PROJECT/.wave/ledger.jsonl")" = "1" ] || \
  fail "the spooled ledger line does not appear exactly once in the ledger"

if [ -s "$errlog" ]; then
  printf 'concurrency: racer stderr was not empty:\n%s\n' "$(cat "$errlog")" >&2
  rc=1
fi

exit $rc
