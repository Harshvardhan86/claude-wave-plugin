#!/usr/bin/env bash
# tests/cases/init-hook-install-failed.sh — wave-init.sh never says or records
# that it installed the commit-msg hook unless every step (mkdir, mktemp,
# write, mv, chmod) succeeded. On a failed install it records
# commit_msg_hook "install-failed", prints a notice naming the cause and the
# fallback, and renders the fallback check to .wave/hooks/commit-msg, which
# refuses a trailer line.
#
# Real git in throwaway repositories, isolated from the machine's own config;
# no network.
#   notdir     .git/hooks is a regular FILE, so neither mkdir nor mktemp can
#              create anything under it. Fails for every user, root included.
#   readonly   .git/hooks is a directory with mode 555, so mktemp cannot
#              create the temp file. Root ignores the mode, so this leg is
#              SKIPPED (printed, and logged) when running as root; the notdir
#              leg still runs.
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

new_project() {
  WV_PROJECT="$(realpath "$(mkproj)")"
  export CLAUDE_PROJECT_DIR="$WV_PROJECT"
  : > "$WV_PROJECT/README.md"
  git -C "$WV_PROJECT" add README.md
  git -C "$WV_PROJECT" commit -q -m init
}

failed_ok() {
  # failed_ok <label> <cause fragment>
  local label="$1" cause="$2" check m
  assert_state '.commit_msg_hook == "install-failed"' \
    || fail "$label: want install-failed, got $(jq -c '.commit_msg_hook' "$WV_PROJECT/.wave/state.json" 2>/dev/null)"
  assert_state '.commit_msg_check == "written"' || fail "$label: want commit_msg_check written (the fallback check verified)"
  case "$CLI_STDERR" in
    *"wave-init.sh: installed"*|*"wave-init.sh: upgraded"*) fail "$label: an install was reported although it failed: '$CLI_STDERR'" ;;
  esac
  check="$WV_PROJECT/.wave/hooks/commit-msg"
  case "$CLI_STDERR" in *"commit-msg guard is not installed"*) : ;; *) fail "$label: the notice must say the commit-msg guard is not installed: '$CLI_STDERR'" ;; esac
  case "$CLI_STDERR" in *"$cause"*) : ;; *) fail "$label: the notice must name the cause ($cause): '$CLI_STDERR'" ;; esac
  case "$CLI_STDERR" in *"remedy:"*"$check"*) : ;; *) fail "$label: the notice must name the fallback check ($check) in a remedy: '$CLI_STDERR'" ;; esac
  if [ -f "$check" ]; then
    m="$WV_RUN_TMP/$name-$label-msg.txt"
    printf 'subject\n\nClaude-Session: https://example.invalid/s/1\n' > "$m"
    bash "$check" "$m" >/dev/null 2>&1
    [ "$?" = "1" ] || fail "$label: the fallback check does not refuse a trailer line"
    printf 'subject\n' > "$m"
    bash "$check" "$m" >/dev/null 2>&1 || fail "$label: the fallback check refuses a plain message"
  else
    fail "$label: the fallback check $check does not exist"
  fi
}

# ---- notdir: .git/hooks is a file ---------------------------------------------
new_project
rm -rf "$WV_PROJECT/.git/hooks"
printf 'not a directory\n' > "$WV_PROJECT/.git/hooks"
run_cli scripts/wave-init.sh --wave 1 --mode full --feature x
[ "$CLI_EXIT" = "0" ] || fail "notdir: exit $CLI_EXIT ($CLI_STDERR)"
failed_ok notdir "$WV_PROJECT/.git/hooks"
[ "$(cat "$WV_PROJECT/.git/hooks")" = "not a directory" ] || fail "notdir: the file at .git/hooks was changed"

# ---- readonly: .git/hooks is mode 555 -----------------------------------------
if [ "$(id -u)" = "0" ]; then
  printf 'SKIPPED readonly leg: running as root, which ignores directory modes\n' | tee -a "$log" >&2
else
  new_project
  mkdir -p "$WV_PROJECT/.git/hooks"
  rm -f "$WV_PROJECT/.git/hooks/commit-msg"
  chmod 555 "$WV_PROJECT/.git/hooks"
  wv_on_exit "chmod 755 '$WV_PROJECT/.git/hooks' 2>/dev/null"
  run_cli scripts/wave-init.sh --wave 1 --mode full --feature x
  chmod 755 "$WV_PROJECT/.git/hooks"
  [ "$CLI_EXIT" = "0" ] || fail "readonly: exit $CLI_EXIT ($CLI_STDERR)"
  failed_ok readonly "$WV_PROJECT/.git/hooks"
  [ -e "$WV_PROJECT/.git/hooks/commit-msg" ] && fail "readonly: a hook appeared in the read-only directory"
  # nothing was left behind by a half-done install
  ls -A "$WV_PROJECT/.git/hooks" | command grep -q '^\.commit-msg\.' && fail "readonly: a temp file was left in .git/hooks"
fi

exit $rc
