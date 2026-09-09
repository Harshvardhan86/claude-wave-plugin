#!/usr/bin/env bash
# tests/cases/budget-178-unbudgeted-phase-allow.sh — AC-178.
#
# A phase present in `hooks/phases.tsv` but absent from `hooks/budgets.tsv` must
# fail OPEN: no `W-BUDGET`, whatever the ledger says. (AC-350 separately fails
# the build when a row is missing, so this is the runtime half of that pair.)
#
# Every one of the 26 shipped phases HAS a budget row, so the state AC-178
# describes cannot be reached with the shipped data. The case therefore runs the
# hook out of a copy of the tree whose `budgets.tsv` has the `TDE-GREEN` row
# removed — and, so the assertion is not vacuous, drives the IDENTICAL ledger
# and stdin through the unmodified tree first and requires that one to deny. A
# case that only asserted "no W-BUDGET" would pass just as happily against a
# budget gate that never ran at all.
set -u

# shellcheck source=tests/lib/assert.sh
source "$(dirname "$0")/../lib/assert.sh"

name="${WV_CASE_NAME:-$(basename "$0" .sh)}"
log="${WV_CASE_LOG:-$WV_RUN_TMP/logs/$name.log}"
rc=0
fail() { printf 'ASSERT FAIL: %s\n' "$*" >&2; rc=1; }

printf 'RAN pre-agent.sh %s decision=multi\n' "$name" >> "$log"

# --- a ledger far above every budget in the file ---------------------------
ledger=""
for out in 40000 40000; do
  ledger="$ledger$(jq -nc --argjson o "$out" '{
    agent: "agent-unbudgeted", phase: "TDE-GREEN", role: "executor",
    requested: "sonnet", resolved: "claude-sonnet-4-5-20250929",
    tier_ok: true, tier_verified: true, input: 1234, output: $o,
    cache_read: 0, cache_create: 0, turns: 7, stopped: "2026-09-09T12:30:00Z"
  }')
"
done

STDIN_JSON="$(jq -nc '{
  session_id: "1a2b0599-4617-4e73-a9c0-2bef462b2626",
  transcript_path: "/tmp/wave-plugin-tests/transcript.jsonl",
  cwd: ".",
  permission_mode: "bypassPermissions",
  hook_event_name: "PreToolUse",
  tool_name: "Agent",
  tool_use_id: "toolu_01RXAwe6jcU5LBKHd9geD6sE",
  tool_input: {
    description: "[W:1 P:TDE-GREEN R:executor] make the tests pass",
    prompt: "Do the thing.",
    subagent_type: "general-purpose",
    model: "sonnet"
  }
}')"

mkproject() {
  # mkproject -> a fresh temp project seeded with p2-red.json and the ledger.
  WV_PROJECT=""
  WV_PROJECT="$(mkproj)"
  seed_state state/p2-red.json
  printf '%s' "$ledger" > "$WV_PROJECT/.wave/ledger.jsonl"
}

drive() {
  # drive <hook-script-abs> -> sets OUT / EXIT for one invocation.
  local script="$1" errf="$WV_RUN_TMP/$name.stderr"
  OUT="$(cd "$WV_PROJECT" && printf '%s' "$STDIN_JSON" | bash "$script" 2>"$errf")"
  EXIT=$?
  ERR="$(cat "$errf")"
  rm -f "$errf"
}

# --- positive control: the shipped tree, which HAS the row, must deny -------
mkproject
drive "$WV_REPO_ROOT/scripts/hooks/pre-agent.sh"
[ "$EXIT" = "0" ] || fail "control: want exit 0, got $EXIT (stderr: $ERR)"
case "$OUT" in
  *W-BUDGET*) : ;;
  *) fail "control: the shipped budgets.tsv row must make this ledger deny W-BUDGET, got: '$OUT'" ;;
esac

# --- the case itself: the same ledger against a tree with the row removed ---
tree="$WV_RUN_TMP/$name-tree"
rm -rf "$tree"
mkdir -p "$tree" || exit 1
cp -a "$WV_REPO_ROOT/scripts" "$WV_REPO_ROOT/hooks" "$tree/" || exit 1
command grep -v $'^TDE-GREEN\t' "$WV_REPO_ROOT/hooks/budgets.tsv" > "$tree/hooks/budgets.tsv"
before="$(command grep -c . "$WV_REPO_ROOT/hooks/budgets.tsv")"
after="$(command grep -c . "$tree/hooks/budgets.tsv")"
[ "$after" = "$((before - 1))" ] || \
  fail "the mutation removed $((before - after)) line(s) from budgets.tsv, want exactly 1"

mkproject
drive "$tree/scripts/hooks/pre-agent.sh"
[ "$EXIT" = "0" ] || fail "want exit 0, got $EXIT (stderr: $ERR)"
case "$OUT" in
  *W-BUDGET*) fail "an unbudgeted phase must not produce W-BUDGET, got: '$OUT'" ;;
esac
case "$OUT" in
  *'"permissionDecision"'*) fail "an unbudgeted phase must not deny at all, got: '$OUT'" ;;
esac

exit $rc
