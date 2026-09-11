#!/usr/bin/env bash
# tests/cases/commit-310-worktree.sh — AC-310.
#
# A real `git worktree`, its own index separate from the main project's:
# staging a planning doc IN the worktree denies (the guard runs
# `git -C "<stdin cwd>"`, so it inspects the worktree's own index); staging
# the same path only in the main project's index, with the Bash call's `cwd`
# still pointed at the worktree, allows — the worktree's index genuinely has
# nothing staged.
set -u
# shellcheck source=../lib/assert.sh
source "$(dirname "$0")/../lib/assert.sh"

name="$(basename "$0" .sh)"
log="${WV_CASE_LOG:-$WV_RUN_TMP/logs/$name.log}"
mkdir -p "$(dirname "$log")"
rc=0
fail() { printf 'ASSERT FAIL: %s\n' "$*" >&2; rc=1; }

main="$(mkproj)"
: > "$main/f.txt"
git -C "$main" add f.txt
git -C "$main" commit -q -m init

wt="$WV_RUN_TMP/$name-wt"
git -C "$main" worktree add -q "$wt" -b "$name-branch" >/dev/null 2>&1
[ -d "$wt" ] || { fail "git worktree add did not create $wt"; exit 1; }

mkdir -p "$main/.wave"
cp "$WV_TESTS_DIR/fixtures/state/full-fresh.json" "$main/.wave/state.json"
: > "$main/.wave/lock"

run_guard() {
  local cwd="$1"
  local stdin
  stdin="$(jq -nc --arg cwd "$cwd" \
    '{hook_event_name:"PreToolUse", tool_name:"Bash", cwd:$cwd,
      tool_input:{command:"git commit -m wip"}}')"
  GUARD_OUT="$(cd "$cwd" && CLAUDE_PROJECT_DIR="$main" printf '%s' "$stdin" | \
    CLAUDE_PROJECT_DIR="$main" bash "$WV_REPO_ROOT/scripts/hooks/pre-commit-guard.sh")"
  GUARD_EXIT=$?
  printf 'RAN pre-commit-guard.sh %s decision=worktree\n' "$name" >> "$log"
}

# ---- staged IN the worktree: deny ------------------------------------------
mkdir -p "$wt/tasks"
: > "$wt/tasks/todo.md"
git -C "$wt" add tasks/todo.md

run_guard "$wt"
case "$GUARD_OUT" in
  *'"permissionDecision":"deny"'*'W-COMMIT-DOC'*) : ;;
  *) fail "worktree-staged: expected a W-COMMIT-DOC deny, got: $GUARD_OUT" ;;
esac

git -C "$wt" reset -q tasks/todo.md

# ---- staged only in the MAIN project's index, cwd still the worktree: allow
mkdir -p "$main/tasks"
: > "$main/tasks/todo.md"
git -C "$main" add tasks/todo.md

run_guard "$wt"
case "$GUARD_OUT" in
  *'"permissionDecision":"deny"'*) fail "main-only-staged: expected allow (worktree index is clean), got a deny: $GUARD_OUT" ;;
  *) : ;;
esac

exit $rc
