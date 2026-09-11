#!/usr/bin/env bash
# tests/cases/lib-block-warn-ledger-ownership.sh — who owns the ledger line on
# `wv_block`'s enforce=warn path (fix round 1, item 6).
#
# SubagentStop has no `additionalContext` channel, so `wv_block` under
# enforce="warn" records the warning in state and on a ledger line instead. That
# is right for a caller with no ledger line of its own, and WRONG for
# subagent-stop.sh, which writes one line per agent with a closed key set: two
# lines for one agent break the one-line-per-agent dedupe key that both the
# scorecard and the budget gate read, and a reader cannot tell which is the record.
#
# subagent-stop.sh no longer reaches this path — it converts the verdict earlier,
# where the phase status is decided (tests/cases/warn-mode-393-per-script.sh) — so
# the library's own path became UNREACHABLE AND UNTESTED, which is the shape that
# gets resurrected by the next caller who does not know about the duplicate. So the
# contract is now explicit rather than incidental: a caller that owns its ledger
# line declares WV_LEDGER_OWNED=1 and `wv_block` records the warning in the state
# ONLY; a caller that does not gets both, as before.
#
# Both modes are driven, because the default is as much of the contract as the
# opt-out, and asserting only one of them would let a change to the other pass.
set -u

# shellcheck source=tests/lib/assert.sh
source "$(dirname "$0")/../lib/assert.sh"

name="${WV_CASE_NAME:-$(basename "$0" .sh)}"
log="${WV_CASE_LOG:-$WV_RUN_TMP/logs/$name.log}"
rc=0
fail() { printf 'ASSERT FAIL: %s\n' "$*" >&2; rc=1; }
printf 'RAN tests/fixtures/drive-lib.sh %s decision=multi\n' "$name" >> "$log"

warn_state="$WV_RUN_TMP/$name-state.json"
jq '.enforce = "warn"' "$WV_TESTS_DIR/fixtures/state/valid-full.json" > "$warn_state" \
  || { fail "could not build the enforce=warn state"; exit 1; }

drive() {
  # drive <label> <extra env jq> -> runs wv_block W-ARTIFACT on a SubagentStop
  # payload against the enforce=warn state, in a fresh project.
  local label="$1" env_filter="$2"
  WV_PROJECT=""
  local c="$WV_RUN_TMP/$name-$label.json"
  jq -n --arg f "$warn_state" '{
    script: "tests/fixtures/drive-lib.sh",
    env: { WV_DRIVE: "block:W-ARTIFACT", WV_PHASE: "AC" },
    seed: { state: $f },
    stdin: {
      hook_event_name: "SubagentStop",
      cwd: ".",
      agent_id: "a1"
    }
  }' | jq "$env_filter" > "$c" || { fail "$label: jq rejected the env filter"; return 1; }
  run_hook tests/fixtures/drive-lib.sh "$c" || { fail "$label: run_hook: $WV_LAST_STDERR"; return 1; }
  assert_exit 0 || fail "$label: exit"
  return 0
}

ledger_lines() {
  local l="$WV_PROJECT/.wave/ledger.jsonl"
  if [ -f "$l" ]; then wc -l < "$l" | tr -d ' '; else printf '0'; fi
}

# ---- the default: the caller owns no ledger line, so wv_block writes one -----
if drive unowned '.'; then
  [ "$(ledger_lines)" = "1" ] || \
    fail "unowned: want exactly 1 ledger line from wv_block's warn path, got $(ledger_lines): $(cat "$WV_PROJECT/.wave/ledger.jsonl" 2>/dev/null)"
  jq -se '.[0].event == "warn" and .[0].agent_id == "a1" and .[0].phase == "AC"
          and ((.[0].warn // []) | length == 1)
          and ((.[0].warn[0]) | startswith("[W-ARTIFACT] "))' \
    "$WV_PROJECT/.wave/ledger.jsonl" >/dev/null 2>&1 || \
    fail "unowned: the line must carry the rendered warning, got $(cat "$WV_PROJECT/.wave/ledger.jsonl" 2>/dev/null)"
  jq -e '((.phases.AC.warned // []) | length == 1)' "$WV_PROJECT/.wave/state.json" >/dev/null 2>&1 || \
    fail "unowned: the state must record the warning too, got $(jq -c '.phases.AC' "$WV_PROJECT/.wave/state.json")"
  # And no block object: enforce=warn allows.
  if printf '%s' "$WV_LAST_STDOUT" | jq -e '.decision' >/dev/null 2>&1; then
    fail "unowned: enforce=warn must not block, got '$WV_LAST_STDOUT'"
  fi
  printf '  unowned: 1 ledger line (event=warn) + state.phases.AC.warned\n'
fi

# ---- WV_LEDGER_OWNED=1: the state only, so the caller's own line stays alone --
if drive owned '.env.WV_LEDGER_OWNED = "1"'; then
  [ "$(ledger_lines)" = "0" ] || \
    fail "owned: wv_block must write NO ledger line when the caller owns one, got $(ledger_lines): $(cat "$WV_PROJECT/.wave/ledger.jsonl" 2>/dev/null)"
  jq -e '((.phases.AC.warned // []) | length == 1)
         and ((.phases.AC.warned[0]) | startswith("[W-ARTIFACT] "))' \
    "$WV_PROJECT/.wave/state.json" >/dev/null 2>&1 || \
    fail "owned: the state must still record the warning, got $(jq -c '.phases.AC' "$WV_PROJECT/.wave/state.json")"
  if printf '%s' "$WV_LAST_STDOUT" | jq -e '.decision' >/dev/null 2>&1; then
    fail "owned: enforce=warn must not block, got '$WV_LAST_STDOUT'"
  fi
  printf '  owned:   0 ledger lines + state.phases.AC.warned\n'
fi

# ---- the production caller declares ownership ------------------------------
#
# The contract is only worth anything if the one caller that owns a ledger line
# actually says so, and that is a property of the source, not of a run.
command grep -qE '^WV_LEDGER_OWNED=1' "$WV_REPO_ROOT/scripts/hooks/subagent-stop.sh" || \
  fail "scripts/hooks/subagent-stop.sh writes its own ledger line but does not declare WV_LEDGER_OWNED=1"

exit $rc
