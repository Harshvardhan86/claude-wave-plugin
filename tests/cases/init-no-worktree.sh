#!/usr/bin/env bash
# tests/cases/init-no-worktree.sh — a state must never claim an install that
# did not happen. When the project directory is not a git repository, or is a
# bare repository (no work tree, so no commit is ever made there and a hook
# would never run), wave-init.sh writes no commit-msg hook anywhere, records
# commit_msg_hook "not-a-repo" (never "installed") and prints one generic line
# saying the commit-msg guard was not installed because there is no work-tree
# repository; the session's commit guard still applies.
#   plain  a directory that is not a git repository
#   bare   a repository made with `git init --bare`; nothing under its git
#          directory (which is the project directory itself) changes, so no
#          info/exclude line either: every file and directory outside the
#          wave's own .wave/ is byte-identical before and after
# Real git, isolated from the machine's config (GIT_CONFIG_GLOBAL is a temp
# file, GIT_CONFIG_NOSYSTEM=1); no network.
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

snapshot() {
  # snapshot <dir> -> every path under <dir> except .wave/, with a content
  # hash for files, sorted
  ( cd "$1" && find . -path ./.wave -prune -o -print | LC_ALL=C sort | while IFS= read -r p; do
      if [ -f "$p" ]; then printf '%s %s\n' "$(sha256sum < "$p" | cut -d' ' -f1)" "$p"; else printf 'dir %s\n' "$p"; fi
    done )
}

check_leg() {
  # check_leg <label>
  local label="$1" hooks
  [ "$CLI_EXIT" = "0" ] || fail "$label: exit $CLI_EXIT ($CLI_STDERR)"
  assert_state '.commit_msg_hook == "not-a-repo"' || fail "$label: want not-a-repo"
  hooks="$(find "$WV_PROJECT" -name 'commit-msg*' -not -name '*.sample' 2>/dev/null | command grep -v '/\.wave/hooks/' || true)"
  [ -z "$hooks" ] || fail "$label: a commit-msg hook was written: $hooks"
  case "$CLI_STDERR" in
    *"wave-init.sh: installed"*|*"wave-init.sh: upgraded"*) fail "$label: an install was reported: '$CLI_STDERR'" ;;
  esac
  case "$CLI_STDERR" in
    *"commit-msg guard was not installed"*"no work-tree repository"*) : ;;
    *) fail "$label: the notice must say the commit-msg guard was not installed because there is no work-tree repository: '$CLI_STDERR'" ;;
  esac
}

# ---- plain: not a git repository -----------------------------------------------
WV_PROJECT="$(realpath "$(mktemp -d "$WV_RUN_TMP/plain.XXXXXX")")"
export CLAUDE_PROJECT_DIR="$WV_PROJECT"
git -C "$WV_PROJECT" rev-parse --git-dir >/dev/null 2>&1 && fail "plain: precondition: the directory is inside a repository"
run_cli scripts/wave-init.sh --wave 1 --mode full --feature x
check_leg plain

# ---- bare: git init --bare --------------------------------------------------------
WV_PROJECT="$(realpath "$(mktemp -d "$WV_RUN_TMP/bare.XXXXXX")")"
export CLAUDE_PROJECT_DIR="$WV_PROJECT"
git -C "$WV_PROJECT" init -q --bare
[ "$(git -C "$WV_PROJECT" rev-parse --is-bare-repository)" = "true" ] || fail "bare: precondition: not a bare repository"
bare_before="$(snapshot "$WV_PROJECT")"
run_cli scripts/wave-init.sh --wave 1 --mode full --feature x
check_leg bare
bare_after="$(snapshot "$WV_PROJECT")"
[ "$bare_before" = "$bare_after" ] || fail "bare: init wrote under the git directory: $(diff <(printf '%s\n' "$bare_before") <(printf '%s\n' "$bare_after") | tr '\n' ' ')"
case "$CLI_STDERR" in *"info/exclude"*) fail "bare: an exclude write was reported: '$CLI_STDERR'" ;; esac

# ---- control: a work-tree repository still installs ---------------------------------
WV_PROJECT="$(realpath "$(mkproj)")"
export CLAUDE_PROJECT_DIR="$WV_PROJECT"
run_cli scripts/wave-init.sh --wave 1 --mode full --feature x
assert_state '.commit_msg_hook == "installed"' || fail "control: want installed"
[ -x "$WV_PROJECT/.git/hooks/commit-msg" ] || fail "control: the hook was not installed"
command grep -qxF '.wave/' "$WV_PROJECT/.git/info/exclude" 2>/dev/null || fail "control: .wave/ was not added to the work-tree repository's exclude"
case "$CLI_STDERR" in *"no work-tree repository"*) fail "control: a no-repository notice in a work-tree repo: '$CLI_STDERR'" ;; esac

exit $rc
