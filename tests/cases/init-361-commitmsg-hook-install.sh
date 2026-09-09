#!/usr/bin/env bash
# tests/cases/init-361-commitmsg-hook-install.sh — AC-361, the "absent" half.
#
# A repo with no .git/hooks/commit-msg: wave-init.sh creates it, executable,
# and records commit_msg_hook:"installed". The refusal behaviour of the
# installed hook itself is AC-313, proved end to end by
# tests/cases/commitmsg-313-trailer-refused.sh.
set -u

# shellcheck source=tests/lib/assert.sh
source "$(dirname "$0")/../lib/assert.sh"

name="$(basename "$0" .sh)"
log="${WV_CASE_LOG:-$WV_RUN_TMP/logs/$name.log}"
mkdir -p "$(dirname "$log")"

rc=0
fail() { printf 'ASSERT FAIL: %s\n' "$*" >&2; rc=1; }

run_cli() {
  local script="$1"; shift
  local errf="$WV_RUN_TMP/$name.stderr"
  CLI_STDOUT="$(cd "$WV_PROJECT" && bash "$WV_REPO_ROOT/$script" "$@" 2>"$errf")"
  CLI_EXIT=$?
  CLI_STDERR="$(cat "$errf")"
  rm -f "$errf"
  printf 'RAN %s %s exit=%s\n' "$script" "$name" "$CLI_EXIT" >> "$log"
}

WV_PROJECT="$(mkproj)"
: > "$WV_PROJECT/README.md"
git -C "$WV_PROJECT" add README.md
git -C "$WV_PROJECT" commit -q -m init

[ ! -e "$WV_PROJECT/.git/hooks/commit-msg" ] || fail "test setup: a commit-msg hook already existed before wave-init.sh ran"

run_cli scripts/wave-init.sh --wave 1 --mode full --feature x
[ "$CLI_EXIT" = "0" ] || fail "exit: want 0, got $CLI_EXIT (stderr: $CLI_STDERR)"

hook="$WV_PROJECT/.git/hooks/commit-msg"
[ -f "$hook" ] || fail "$hook was not created"
[ -x "$hook" ] || fail "$hook was not made executable"

assert_state '.commit_msg_hook == "installed"' || rc=1

exit $rc
