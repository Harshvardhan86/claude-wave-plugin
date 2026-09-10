#!/usr/bin/env bash
# tests/cases/commit-308-notrepo-allow.sh — AC-308.
#
# An active wave (found via CLAUDE_PROJECT_DIR, which pre-commit-guard.sh's
# wv_project_root walk consults ahead of `cwd`) but a `cwd` that is NOT a git
# repository at all: `git -C <cwd> rev-parse --show-toplevel` fails, so
# there is nothing to inspect and the guard must exit 0 with no deny —
# never a false NO-GO just because the directory happens not to be a repo.
set -u
# shellcheck source=../lib/assert.sh
source "$(dirname "$0")/../lib/assert.sh"

name="$(basename "$0" .sh)"
log="${WV_CASE_LOG:-$WV_RUN_TMP/logs/$name.log}"
mkdir -p "$(dirname "$log")"
rc=0
fail() { printf 'ASSERT FAIL: %s\n' "$*" >&2; rc=1; }

WV_PROJECT="$(mkproj)"
seed_state state/full-fresh.json

plainDir="$(mktemp -d "$WV_RUN_TMP/notrepo.XXXXXX")"

stdin="$(jq -nc --arg cwd "$plainDir" \
  '{hook_event_name:"PreToolUse", tool_name:"Bash", cwd:$cwd,
    tool_input:{command:"git commit -m wip"}}')"
out="$(cd "$plainDir" && printf '%s' "$stdin" | \
  CLAUDE_PROJECT_DIR="$WV_PROJECT" bash "$WV_REPO_ROOT/scripts/hooks/pre-commit-guard.sh")"
ec=$?
printf 'RAN pre-commit-guard.sh %s decision=notrepo\n' "$name" >> "$log"

[ "$ec" = "0" ] || fail "exit $ec, expected 0"
[ -z "$out" ] || fail "expected silent/allow output, got: $out"

exit $rc
