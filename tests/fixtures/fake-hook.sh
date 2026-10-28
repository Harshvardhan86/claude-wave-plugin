#!/usr/bin/env bash
# tests/fixtures/fake-hook.sh — a throwaway stand-in for a real wave hook.
#
# NOT a real hook: never referenced by hooks/hooks.json, never wired into
# the plugin. It exists only so tests/cases/_selfcheck/ can prove the
# harness's own plumbing (stdin capture, project cwd, .wave/state.json
# seeding, ledger append, deny JSON shape) works end to end, without
# depending on scripts/hooks/lib.sh.
#
# Behaviour, deliberately tiny:
#   - no .wave/state.json, or status != "active": silent, exit 0 (mirrors
#     the real "no wave, no hooks" principle).
#   - status == "active": appends one line to .wave/ledger.jsonl; if stdin's
#     last_assistant_message is exactly "SELFCHECK_DENY_ME", also prints a
#     PreToolUse deny JSON carrying rule W-FAKE; if it is exactly
#     "SELFCHECK_WARN_TWO", a warn JSON whose additionalContext carries two
#     warnings, [W-FAKE] then [W-FAKE2]; if it is exactly
#     "SELFCHECK_STDERR_TWO", the same two warnings as two lines on STDERR
#     and nothing on stdout (the SubagentStop / PreCompact channel); if it
#     is exactly "SELFCHECK_BOTH_TWO", both of the above at once (the warn
#     JSON on stdout AND the two lines on stderr), so a case can satisfy a
#     stdout list and a stderr list in the same run.
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
# Two queued warnings in one object, W-FAKE then W-FAKE2: the plant for the
# expect.rules ordered-list self-checks.
if [ "$trigger" = "SELFCHECK_WARN_TWO" ]; then
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"[W-FAKE] first planted warning; remedy: none, this is a test fixture.\\n[W-FAKE2] second planted warning; remedy: none, this is a test fixture."}}\n'
fi
# Both channels at once: the plant for the stderr_rules-beside-rules
# exclusivity self-check, which must be satisfiable on each channel alone.
if [ "$trigger" = "SELFCHECK_BOTH_TWO" ]; then
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"[W-FAKE] first planted warning; remedy: none, this is a test fixture.\\n[W-FAKE2] second planted warning; remedy: none, this is a test fixture."}}\n'
fi
# The same two warnings on stderr, the plant for the expect.stderr_rules
# ordered-list self-checks.
if [ "$trigger" = "SELFCHECK_STDERR_TWO" ] || [ "$trigger" = "SELFCHECK_BOTH_TWO" ]; then
  printf '%s\n%s\n' '[W-FAKE] first planted warning; remedy: none, this is a test fixture.' '[W-FAKE2] second planted warning; remedy: none, this is a test fixture.' >&2
fi

exit 0
