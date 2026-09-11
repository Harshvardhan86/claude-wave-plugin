#!/usr/bin/env bash
# tests/cases/commit-304-amend-noedit.sh — AC-304.
#
# `git commit --amend --no-edit` carries no message text in the command
# itself, so pre-commit-guard.sh has to read `git log -1 --format=%B` to
# judge it. Two real commits in one repo: one whose message already carries
# a trailer (amend --no-edit over it denies), one that does not (allow —
# the negative control for the same rule, exercised in the SAME repo shape
# so the only variable is the previous message).
set -u
# shellcheck source=../lib/assert.sh
source "$(dirname "$0")/../lib/assert.sh"

name="$(basename "$0" .sh)"
log="${WV_CASE_LOG:-$WV_RUN_TMP/logs/$name.log}"
mkdir -p "$(dirname "$log")"
rc=0
fail() { printf 'ASSERT FAIL: %s\n' "$*" >&2; rc=1; }

run_guard() {
  # run_guard <project> -> sets GUARD_OUT / GUARD_EXIT for a
  # `git commit --amend --no-edit` fixture against <project>.
  local proj="$1"
  local stdin
  stdin="$(jq -nc --arg cwd "$proj" \
    '{hook_event_name:"PreToolUse", tool_name:"Bash", cwd:$cwd,
      tool_input:{command:"git commit --amend --no-edit"}}')"
  GUARD_OUT="$(cd "$proj" && printf '%s' "$stdin" | bash "$WV_REPO_ROOT/scripts/hooks/pre-commit-guard.sh")"
  GUARD_EXIT=$?
  printf 'RAN pre-commit-guard.sh %s decision=amend-noedit\n' "$name" >> "$log"
}

# ---- positive: a prior trailer, amend --no-edit denies -------------------
proj1="$(mkproj)"
mkdir -p "$proj1/.wave"
cp "$WV_TESTS_DIR/fixtures/state/full-fresh.json" "$proj1/.wave/state.json"
: > "$proj1/.wave/lock"
: > "$proj1/f.txt"
git -C "$proj1" add f.txt
git -C "$proj1" commit -q -m "$(printf 'add a change\n\nCo-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>\n')"

run_guard "$proj1"
[ "$GUARD_EXIT" = "0" ] || fail "positive: guard exited $GUARD_EXIT"
case "$GUARD_OUT" in
  *'"permissionDecision":"deny"'*'W-COMMIT-TRAILER'*) : ;;
  *) fail "positive: expected a W-COMMIT-TRAILER deny, got: $GUARD_OUT" ;;
esac

# ---- negative control: no prior trailer, amend --no-edit allows ----------
proj2="$(mkproj)"
mkdir -p "$proj2/.wave"
cp "$WV_TESTS_DIR/fixtures/state/full-fresh.json" "$proj2/.wave/state.json"
: > "$proj2/.wave/lock"
: > "$proj2/f.txt"
git -C "$proj2" add f.txt
git -C "$proj2" commit -q -m "add a change"

run_guard "$proj2"
[ "$GUARD_EXIT" = "0" ] || fail "negative: guard exited $GUARD_EXIT"
case "$GUARD_OUT" in
  *'"permissionDecision":"deny"'*) fail "negative: expected allow, got a deny: $GUARD_OUT" ;;
  *) : ;;
esac

exit $rc
