#!/usr/bin/env bash
# tests/cases/stop-blockonce-three-stops.sh — fix round 1, item 1.
#
# THE MEASURED SEQUENCE. ~/WAVE_PLUGIN_ANALYSIS/probe2-worktree-stopblock.log
# records three SubagentStop events for ONE agent (abe831e9837f3dcee):
#
#   line 16   stop_hook_active=false     <- blocked here
#   line 20   stop_hook_active=true      <- the agent obeyed and stopped again
#   line 27   stop_hook_active=false     <- and a THIRD stop, flag FALSE again
#
# So `stop_hook_active` alone is not the block-once key: it is false on the third
# stop, and a hook keyed only on it blocks the same agent for the same reason
# again (and again, up to the harness's block cap). The key is a RECORD —
# `active[<id>].blocked` — written under the lock beside the block.
#
# What this case pins: exactly ONE block object across the three stops, the phase
# recorded `failed` once the agent has been blocked and has still not produced the
# artifact, and exactly one ledger line for the agent.
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

AGENT=abe831e9837f3dcee
blocks=0

WV_PROJECT="$(mkproj)"
st="$WV_RUN_TMP/$name-state.json"
stop_state "$st" ".active = {\"$AGENT\": $(stop_active AC reviewer opus)}" || exit 1

stop() {
  # stop <step> <stop_hook_active> [seed]
  local c="$WV_RUN_TMP/$name-$1.json"
  if [ "${3:-}" = "seed" ]; then
    stop_case "$c" "$(printf '.seed.state = "%s" | .stdin.agent_id = "%s" | .stdin.stop_hook_active = %s' \
      "$st" "$AGENT" "$2")" || return 1
  else
    stop_case "$c" "$(printf '.stdin.agent_id = "%s" | .stdin.stop_hook_active = %s' "$AGENT" "$2")" || return 1
  fi
  run_hook subagent-stop.sh "$c" || { fail "step $1: run_hook: $WV_LAST_STDERR"; return 1; }
  case "$WV_LAST_STDOUT" in
    *'"decision":"block"'*) blocks=$((blocks + 1)) ;;
  esac
  return 0
}

# Stop 1 (flag false): the artifact is absent, so this is the block.
if stop one false seed; then
  assert_block W-ARTIFACT || fail "stop 1: want block(W-ARTIFACT)"
  [ "$(stop_phase_status AC)" = "artifact-missing" ] || \
    fail "stop 1: status is '$(stop_phase_status AC)', want artifact-missing"
fi

# Stop 2 (flag true): never block on this flag, and the phase is now FAILED —
# the agent was told what to produce, stopped again, and still has not.
if stop two true; then
  [ -z "$WV_LAST_STDOUT" ] || fail "stop 2: stdout must be empty, got '$WV_LAST_STDOUT'"
  [ "$(stop_phase_status AC)" = "failed" ] || \
    fail "stop 2: status is '$(stop_phase_status AC)', want failed"
fi

sha_after_two="$(sha256sum < "$WV_PROJECT/.wave/state.json" | cut -d' ' -f1)"

# Stop 3 (flag FALSE again — the measured third event): still no block.
if stop three false; then
  [ -z "$WV_LAST_STDOUT" ] || \
    fail "stop 3: stdout must be empty — the flag is false again, so the block-once key must be the record, got '$WV_LAST_STDOUT'"
  [ "$(stop_phase_status AC)" = "failed" ] || \
    fail "stop 3: status is '$(stop_phase_status AC)', want failed"
  [ "$(sha256sum < "$WV_PROJECT/.wave/state.json" | cut -d' ' -f1)" = "$sha_after_two" ] || \
    fail "stop 3: state.json changed again; a settled failure must be idempotent"
fi

[ "$blocks" = "1" ] || fail "the three stops produced $blocks block object(s), want exactly 1"
[ "$(stop_ledger_count)" = "1" ] || fail "ledger has $(stop_ledger_count) line(s), want 1"
[ "$(jq -r '.active["'"$AGENT"'"].blocked | join(",")' "$WV_PROJECT/.wave/state.json" 2>/dev/null)" = "W-ARTIFACT" ] || \
  fail "active[$AGENT].blocked must record the rule that was emitted, got '$(jq -c '.active["'"$AGENT"'"].blocked // "unset"' "$WV_PROJECT/.wave/state.json" 2>/dev/null)'"

exit $rc
