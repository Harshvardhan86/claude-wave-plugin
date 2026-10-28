#!/usr/bin/env bash
# tests/cases/init-hookspath.sh — a project that manages its git hooks with
# core.hooksPath (a hook manager's tracked directory such as `.husky`, or a
# global hooks directory) keeps that directory to itself: wave-init.sh writes
# NOTHING into it and says on stderr that the commit-msg guard is not
# installed, why, and the remedy (call the wave's commit-msg check, which it
# names by path, from the project's own hook manager). The session's
# PreToolUse commit guard keeps enforcing either way.
#
# Real git in throwaway repositories, isolated from the machine's own config
# (GIT_CONFIG_GLOBAL is a temp file, GIT_CONFIG_NOSYSTEM=1); no network.
#   local    repo-local core.hooksPath=.husky (tracked, holding a pre-commit):
#            .husky is byte-identical, `git status` shows nothing new under it,
#            no hook in .git/hooks either, state "skipped-hookspath", notice;
#            the named check exists and refuses a trailer line.
#   global   core.hooksPath set in the GIT_CONFIG_GLOBAL file to an absolute
#            directory: that directory is unchanged, same state and notice.
#   empty-local / empty-global
#            core.hooksPath set to an EMPTY value (repo config, then the
#            GIT_CONFIG_GLOBAL file). `git config --get` succeeds and prints
#            an empty line, and git still honours the key, so this is a
#            configured hooksPath like any other: same state, notice and
#            fallback check, and no install is attempted anywhere (the value
#            must not be mistaken for "unset", which once sent the install to
#            the filesystem root and recorded "installed" for a hook that was
#            never written).
#   control  no core.hooksPath: the hook is installed in .git/hooks, state
#            "installed", and no hooksPath notice.
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

dir_sum() { ( cd "$1" && find . -print0 | LC_ALL=C sort -z | xargs -0 ls -ld --time-style=+ 2>/dev/null; find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum 2>/dev/null ); }

new_project() {
  WV_PROJECT="$(realpath "$(mkproj)")"
  export CLAUDE_PROJECT_DIR="$WV_PROJECT"
  : > "$WV_PROJECT/README.md"
  git -C "$WV_PROJECT" add README.md
  git -C "$WV_PROJECT" commit -q -m init
}

skipped_ok() {
  # skipped_ok <label> <hooks dir>
  local label="$1" dir="$2" check
  assert_state '.commit_msg_hook == "skipped-hookspath"' || fail "$label: want skipped-hookspath"
  assert_state '.commit_msg_check == "written"' || fail "$label: want commit_msg_check written (the fallback check verified)"
  [ -e "$WV_PROJECT/.git/hooks/commit-msg" ] && fail "$label: a hook git does not run was written to .git/hooks"
  case "$CLI_STDERR" in
    *"core.hooksPath"*"$dir"*"not installed"*"remedy:"*) : ;;
    *) fail "$label: the notice must name core.hooksPath, the directory, 'not installed' and a remedy: '$CLI_STDERR'" ;;
  esac
  check="$WV_PROJECT/.wave/hooks/commit-msg"
  case "$CLI_STDERR" in
    *"$check"*) : ;;
    *) fail "$label: the notice must name the wave's commit-msg check by path ($check): '$CLI_STDERR'" ;;
  esac
  if [ -f "$check" ]; then
    local m="$WV_RUN_TMP/$name-$label-msg.txt"
    printf 'subject\n\nClaude-Session: https://example.invalid/s/1\n' > "$m"
    bash "$check" "$m" >/dev/null 2>&1
    [ "$?" = "1" ] || fail "$label: the named check does not refuse a trailer line"
    printf 'subject\n' > "$m"
    bash "$check" "$m" >/dev/null 2>&1 || fail "$label: the named check refuses a plain message"
  else
    fail "$label: the named check $check does not exist"
  fi
}

# ---- local: a tracked .husky ---------------------------------------------------
new_project
mkdir -p "$WV_PROJECT/.husky"
printf '#!/bin/sh\nexit 0\n' > "$WV_PROJECT/.husky/pre-commit"
chmod +x "$WV_PROJECT/.husky/pre-commit"
git -C "$WV_PROJECT" add .husky
git -C "$WV_PROJECT" commit -q -m husky
git -C "$WV_PROJECT" config core.hooksPath .husky
before="$(dir_sum "$WV_PROJECT/.husky")"
run_cli scripts/wave-init.sh --wave 1 --mode full --feature x
[ "$CLI_EXIT" = "0" ] || fail "local: exit $CLI_EXIT ($CLI_STDERR)"
[ "$(dir_sum "$WV_PROJECT/.husky")" = "$before" ] || fail "local: wave-init.sh wrote into the core.hooksPath directory"
[ -z "$(git -C "$WV_PROJECT" status --porcelain 2>/dev/null)" ] \
  || fail "local: git status shows new files: $(git -C "$WV_PROJECT" status --porcelain)"
skipped_ok local .husky

# ---- global: core.hooksPath from the global config file -----------------------
new_project
ghooks="$WV_RUN_TMP/$name-global-hooks"
mkdir -p "$ghooks"
printf '#!/bin/sh\nexit 0\n' > "$ghooks/pre-push"
git config --file "$GIT_CONFIG_GLOBAL" core.hooksPath "$ghooks"
[ "$(git -C "$WV_PROJECT" config --get core.hooksPath)" = "$ghooks" ] || fail "global: precondition: git does not read the global hooksPath"
before="$(dir_sum "$ghooks")"
run_cli scripts/wave-init.sh --wave 1 --mode full --feature x
[ "$CLI_EXIT" = "0" ] || fail "global: exit $CLI_EXIT ($CLI_STDERR)"
[ "$(dir_sum "$ghooks")" = "$before" ] || fail "global: wave-init.sh wrote into the global core.hooksPath directory"
skipped_ok global "$ghooks"
git config --file "$GIT_CONFIG_GLOBAL" --unset core.hooksPath

# ---- empty-local / empty-global: core.hooksPath set to an empty value --------
no_install_attempt() {
  # no_install_attempt <label>
  case "$CLI_STDERR" in
    *"wave-init.sh: installed"*|*"wave-init.sh: upgraded"*) fail "$1: an install was reported for a configured hooksPath: '$CLI_STDERR'" ;;
  esac
  case "$CLI_STDERR" in
    *"mktemp:"*|*"mv:"*|*"chmod:"*|*"mkdir:"*) fail "$1: an install was attempted for a configured hooksPath: '$CLI_STDERR'" ;;
  esac
}

new_project
git -C "$WV_PROJECT" config core.hooksPath ''
git -C "$WV_PROJECT" config --get core.hooksPath >/dev/null 2>&1 \
  || fail "empty-local: precondition: git does not report the empty hooksPath as configured"
run_cli scripts/wave-init.sh --wave 1 --mode full --feature x
[ "$CLI_EXIT" = "0" ] || fail "empty-local: exit $CLI_EXIT ($CLI_STDERR)"
no_install_attempt empty-local
skipped_ok empty-local ""
[ -z "$(git -C "$WV_PROJECT" status --porcelain 2>/dev/null)" ] \
  || fail "empty-local: git status shows new files: $(git -C "$WV_PROJECT" status --porcelain)"

new_project
git config --file "$GIT_CONFIG_GLOBAL" core.hooksPath ''
git -C "$WV_PROJECT" config --get core.hooksPath >/dev/null 2>&1 \
  || fail "empty-global: precondition: git does not read the empty global hooksPath"
run_cli scripts/wave-init.sh --wave 1 --mode full --feature x
[ "$CLI_EXIT" = "0" ] || fail "empty-global: exit $CLI_EXIT ($CLI_STDERR)"
no_install_attempt empty-global
skipped_ok empty-global ""
git config --file "$GIT_CONFIG_GLOBAL" --unset core.hooksPath

# ---- control: no core.hooksPath -----------------------------------------------
new_project
git -C "$WV_PROJECT" config --get core.hooksPath >/dev/null 2>&1 && fail "control: precondition: a hooksPath is still configured"
run_cli scripts/wave-init.sh --wave 1 --mode full --feature x
[ "$CLI_EXIT" = "0" ] || fail "control: exit $CLI_EXIT ($CLI_STDERR)"
[ -x "$WV_PROJECT/.git/hooks/commit-msg" ] || fail "control: the hook was not installed in .git/hooks"
assert_state '.commit_msg_hook == "installed"' || fail "control: want installed"
case "$CLI_STDERR" in *"core.hooksPath"*) fail "control: a hooksPath notice without a hooksPath: '$CLI_STDERR'" ;; esac

exit $rc
