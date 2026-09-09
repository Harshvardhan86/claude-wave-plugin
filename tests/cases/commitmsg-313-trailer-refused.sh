#!/usr/bin/env bash
# tests/cases/commitmsg-313-trailer-refused.sh — AC-313.
#
# A real `git commit` (not a dry run) whose message carries an AI-attribution
# trailer is refused by the `.git/hooks/commit-msg` wave-init.sh installs,
# non-zero exit, offending line on stderr; a message with no trailer commits
# normally. The hook's own detection uses `command grep`, so this is proved
# under git's own system grep regardless of anything wrapping `grep` in this
# harness's shell.
set -u

# shellcheck source=tests/lib/assert.sh
source "$(dirname "$0")/../lib/assert.sh"

name="$(basename "$0" .sh)"
log="${WV_CASE_LOG:-$WV_RUN_TMP/logs/$name.log}"
mkdir -p "$(dirname "$log")"

rc=0
fail() { printf 'ASSERT FAIL: %s\n' "$*" >&2; rc=1; }

WV_PROJECT="$(mkproj)"
: > "$WV_PROJECT/README.md"
git -C "$WV_PROJECT" add README.md
git -C "$WV_PROJECT" commit -q -m init

run_cli scripts/wave-init.sh --wave 1 --mode full --feature x
[ "$CLI_EXIT" = "0" ] || fail "setup init: exit $CLI_EXIT, stderr: $CLI_STDERR"
[ -x "$WV_PROJECT/.git/hooks/commit-msg" ] || fail "setup: commit-msg hook was not installed"

# ---- the offending commit: refused ----------------------------------------
: > "$WV_PROJECT/change.txt"
git -C "$WV_PROJECT" add change.txt
msgfile="$WV_RUN_TMP/$name-trailer.txt"
printf 'add a change\n\nCo-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>\n' > "$msgfile"

commit_err="$WV_RUN_TMP/$name-commit.stderr"
if git -C "$WV_PROJECT" commit -q -F "$msgfile" 2>"$commit_err"; then
  fail "a commit carrying a Co-Authored-By: Claude trailer must be refused, but git exited 0"
fi
commit_stderr="$(cat "$commit_err")"
case "$commit_stderr" in
  *"Co-Authored-By"*) : ;;
  *) fail "refused commit's stderr does not name the offending line: '$commit_stderr'" ;;
esac
git -C "$WV_PROJECT" log --oneline 2>/dev/null | command grep -q 'add a change' && \
  fail "the refused commit landed in history anyway"

# ---- a clean message: commits normally ------------------------------------
clean_msgfile="$WV_RUN_TMP/$name-clean.txt"
printf 'add a change\n' > "$clean_msgfile"
if ! git -C "$WV_PROJECT" commit -q -F "$clean_msgfile" 2>"$commit_err"; then
  fail "a commit with no trailer must succeed, stderr: $(cat "$commit_err")"
fi
git -C "$WV_PROJECT" log --oneline 2>/dev/null | command grep -q 'add a change' || \
  fail "the clean commit did not land in history"

rm -f "$commit_err"
exit $rc
