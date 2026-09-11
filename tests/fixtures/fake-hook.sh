#!/usr/bin/env bash
# tests/fixtures/fake-hook.sh — a throwaway stand-in for a real wave hook.
#
# NOT a real hook: never referenced by hooks/hooks.json, never wired into
# the plugin. It exists only so tests/cases/_selfcheck/ can prove the
# harness's own plumbing (stdin capture, project cwd, .wave/state.json
# seeding, ledger append, deny JSON shape) works end to end, without
# depending on scripts/hooks/lib.sh, which does not exist until Task 2.
#
# Behaviour, deliberately tiny:
#   - no .wave/state.json, or status != "active": silent, exit 0 (mirrors
#     the real "no wave, no hooks" principle).
#   - status == "active": appends one line to .wave/ledger.jsonl; if stdin's
#     last_assistant_message is exactly "SELFCHECK_DENY_ME", also prints a
#     PreToolUse deny JSON carrying rule W-FAKE.
set -u

input="$(cat)"
state_file=".wave/state.json"

[ -f "$state_file" ] || exit 0

status="$(command grep -o '"status" *: *"[^"]*"' "$state_file" | head -n1 | sed -E 's/.*"([^"]+)"$/\1/')"
[ "$status" = "active" ] || exit 0

mkdir -p .wave
printf '{"event":"fake-hook-ran"}\n' >> .wave/ledger.jsonl

trigger="$(printf '%s' "$input" | command grep -o '"last_assistant_message" *: *"[^"]*"' | head -n1 | sed -E 's/.*"([^"]+)"$/\1/')"
if [ "$trigger" = "SELFCHECK_DENY_ME" ]; then
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"[W-FAKE] planted for the harness smoke test; remedy: none, this is a test fixture."}}\n'
fi

exit 0
