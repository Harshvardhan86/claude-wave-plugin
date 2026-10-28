#!/usr/bin/env bash
# tests/cases/init-linked-worktree.sh — wave-init.sh run in a LINKED worktree
# writes the commit-msg hook and the .wave/ exclude entry where git reads
# them: the repository's common hooks directory and common info/exclude.
# `git rev-parse --git-path` prints an ABSOLUTE path there (a relative one in
# the main worktree), so a path joined onto the project root lands in a nested
# directory git never reads.
#
# Real git in throwaway repositories, isolated from the machine's own config
# (GIT_CONFIG_GLOBAL is an empty file, GIT_CONFIG_NOSYSTEM=1); no network.
#   1. the hook is in <main>/.git/hooks/commit-msg, executable, and no nested
#      copy exists inside the worktree;
#   2. git RUNS it: a commit in the worktree whose message carries a trailer
#      line is refused, a plain commit succeeds;
#   3. `.wave/` is in <main>/.git/info/exclude and `git status --porcelain`
#      in the worktree does not list it;
#   4. the state records "installed".
set -u

# shellcheck source=tests/lib/assert.sh
source "$(dirname "$0")/../lib/assert.sh"

name="$(basename "$0" .sh)"
log="${WV_CASE_LOG:-$WV_RUN_TMP/logs/$name.log}"
mkdir -p "$(dirname "$log")"
rc=0
fail() { printf 'ASSERT FAIL: %s\n' "$*" >&2; rc=1; }

GIT_CONFIG_GLOBAL="$WV_RUN_TMP/$name-gitconfig"
: > "$GIT_CONFIG_GLOBAL"
GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL GIT_CONFIG_NOSYSTEM

main="$(realpath "$(mkproj)")"
: > "$main/README.md"
git -C "$main" add README.md
git -C "$main" commit -q -m init
wt="$WV_RUN_TMP/$name-wt"
git -C "$main" worktree add -q "$wt" -b "$name-branch" >/dev/null 2>&1
[ -d "$wt" ] || { fail "setup: git worktree add did not create $wt"; exit 1; }
wt="$(realpath "$wt")"
case "$(git -C "$wt" rev-parse --git-path hooks/commit-msg)" in
  /*) : ;;
  *) fail "setup: precondition: --git-path is not absolute in a linked worktree" ;;
esac

WV_PROJECT="$wt"
export CLAUDE_PROJECT_DIR="$wt"
run_cli scripts/wave-init.sh --wave 1 --mode full --feature x
[ "$CLI_EXIT" = "0" ] || fail "exit $CLI_EXIT ($CLI_STDERR)"

# 1. the hook location
HOOK="$main/.git/hooks/commit-msg"
[ -f "$HOOK" ] || fail "the hook is not in the common hooks directory $HOOK"
[ -x "$HOOK" ] || fail "the hook in the common hooks directory is not executable"
nested="$(find "$wt" -path "$wt/.git" -prune -o -name commit-msg -print 2>/dev/null)"
[ -z "$nested" ] || fail "a nested hook copy was written inside the worktree: $nested"

# 2. git runs it
printf 'x\n' > "$wt/a.txt"
git -C "$wt" add a.txt
msg="$WV_RUN_TMP/$name-msg.txt"
printf 'add a\n\nClaude-Session: https://example.invalid/s/1\n' > "$msg"
git -C "$wt" commit -q -F "$msg" >/dev/null 2>&1 \
  && fail "git did not run the hook: a commit carrying a trailer line was accepted"
git -C "$wt" commit -q -m "add a" >/dev/null 2>&1 || fail "a plain commit in the worktree was refused"
[ "$(git -C "$wt" log -1 --format=%s 2>/dev/null)" = "add a" ] || fail "the plain commit is not the worktree's HEAD"

# 3. the exclude
command grep -qxF '.wave/' "$main/.git/info/exclude" 2>/dev/null \
  || fail "the .wave/ entry is not in the common info/exclude"
[ -d "$wt/.wave" ] || fail "setup: wave-init did not create $wt/.wave"
case "$(git -C "$wt" status --porcelain 2>/dev/null)" in
  *".wave"*) fail "git status in the worktree lists .wave/: $(git -C "$wt" status --porcelain)" ;;
esac

# 4. the state
assert_state '.commit_msg_hook == "installed"' || fail "want installed"

git -C "$main" worktree remove --force "$wt" >/dev/null 2>&1
exit $rc
