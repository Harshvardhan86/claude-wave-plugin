#!/usr/bin/env bash
# tests/cases/wiring-368-event-keys-and-banned-strings.sh — AC-368.
#
# The .hooks object's keys are exactly PreToolUse, PostToolUse, SubagentStop,
# PreCompact, SessionStart, Stop, UserPromptSubmit (no more, no fewer), and
# the file contains none of the legacy/invented shapes: "if":, block-on-
# nonzero, claude invoke-agent, TaskCreated, ${task.id}.
set -u

# shellcheck source=tests/lib/assert.sh
source "$(dirname "$0")/../lib/assert.sh"

name="$(basename "$0" .sh)"
log="${WV_CASE_LOG:-$WV_RUN_TMP/logs/$name.log}"
mkdir -p "$(dirname "$log")"

rc=0
fail() { printf 'ASSERT FAIL: %s\n' "$*" >&2; rc=1; }

hooks_json="$WV_REPO_ROOT/hooks/hooks.json"
if [ ! -f "$hooks_json" ]; then
  fail "$hooks_json does not exist"
  printf 'RAN wiring-368 hooks.json=absent\n' >> "$log"
  exit 1
fi

want_keys="PostToolUse PreCompact PreToolUse SessionStart Stop SubagentStop UserPromptSubmit"
got_keys="$(jq -r '.hooks | keys[]' "$hooks_json" 2>/dev/null | sort | tr '\n' ' ')"
got_keys="${got_keys% }"

[ "$got_keys" = "$want_keys" ] || fail "event keys: want [$want_keys], got [$got_keys]"

for banned in '"if":' 'block-on-nonzero' 'claude invoke-agent' 'TaskCreated' '${task.id}'; do
  if command grep -qF -- "$banned" "$hooks_json"; then
    fail "hooks.json contains the banned string: $banned"
  fi
done

printf 'RAN wiring-368 keys=%s\n' "$got_keys" >> "$log"
exit $rc
