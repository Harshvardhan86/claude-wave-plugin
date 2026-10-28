#!/usr/bin/env bash
# tests/cases/init-hook-render-fault.sh — wave-init.sh never says or records
# that it installed the commit-msg hook unless the file now at the hook path
# is byte-identical to the intended template. The template is written by
# several commands; a failure of an EARLY one must not be masked by a later
# one that succeeds.
#
# The fault is injected by a test-private `cat` placed first on PATH for the
# init run only: it intercepts the FIRST stdin read whose text starts with the
# template's first heredoc line ("# Installed by wave-init.sh."), once, then
# behaves exactly like the real cat (a marker file records that it fired;
# every leg asserts it did, so a renderer that stops reading through `cat`
# makes this case red rather than vacuous).
#   exitfault    the intercepted read prints nothing and exits 73
#                (the reproduction in v030/final3-review-codex.md, finding 1)
#   silentfault  the intercepted read prints nothing and exits 0, so only a
#                byte comparison against an independently rendered reference
#                can notice it
# Each fault leg asserts: commit_msg_hook "install-failed", no installed /
# upgraded notice, a notice naming the commit-msg guard as not installed with
# a remedy naming the fallback check, no file at the hook path, no temp file
# left in .git/hooks or .wave/, a fallback check that refuses a trailer and
# accepts a plain message; then, with the fault cleared, a second init
# installs a hook byte-identical to the control's, and real git refuses a
# trailer commit and accepts a plain one through it.
#   alwaysfault  the exitfault read fails on EVERY render, so the fallback
#                check cannot be verified either: commit_msg_check "failed"
#                in the state, a notice saying so with the failed step, no
#                runnable remedy printed, and neither the hook nor the
#                fallback check left on disk
#   control      no fault: installed, commit_msg_check "none", and the hook
#                refuses a trailer commit
# The fallback's own outcome is recorded too: commit_msg_check "written" in
# both one-shot legs.
#
# Real git in throwaway repositories, isolated from the machine's own config;
# no network.
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

real_cat="$(command -v cat)"
case "$real_cat" in /*) : ;; *) printf 'ASSERT FAIL: no absolute cat on PATH (%s)\n' "$real_cat" >&2; exit 1 ;; esac

new_project() {
  WV_PROJECT="$(realpath "$(mkproj)")"
  export CLAUDE_PROJECT_DIR="$WV_PROJECT"
  : > "$WV_PROJECT/README.md"
  git -C "$WV_PROJECT" add README.md
  git -C "$WV_PROJECT" commit -q -m init
}

make_fault_bin() {
  # make_fault_bin <label> <exit status of the intercepted read> [always]
  #   -> the bin dir. With "always" the fault fires on every matching read
  #   (the marker file still records that it fired).
  local dir="$WV_RUN_TMP/$name-$1-bin" always="${3:-}"
  mkdir -p "$dir"
  {
    printf '#!/bin/bash\n'
    printf 'real=%q\nonce=%q\nfault_rc=%q\nalways=%q\n' "$real_cat" "$dir/fired" "$2" "$always"
    "$real_cat" <<'WRAP'
if [ "$#" = 0 ]; then
  data="$("$real" && printf x)"
  data="${data%x}"
  if [[ "$data" == '# Installed by wave-init.sh.'* ]] && { [ ! -e "$once" ] || [ -n "$always" ]; }; then
    : > "$once"
    exit "$fault_rc"
  fi
  printf '%s' "$data"
else
  exec "$real" "$@"
fi
WRAP
  } > "$dir/cat"
  chmod +x "$dir/cat"
  printf '%s' "$dir"
}

commit_rc() {
  # commit_rc <message text> -> git commit's exit status in $WV_PROJECT
  local m="$WV_RUN_TMP/$name-commit-msg.txt"
  printf '%s' "$1" > "$m"
  git -C "$WV_PROJECT" commit -q --allow-empty -F "$m" >/dev/null 2>&1
}

trailer_msg=$'subject\n\nClaude-Session: https://example.invalid/s/1\n'
plain_msg=$'subject\n'

# ---- control: no fault -----------------------------------------------------------
new_project
run_cli scripts/wave-init.sh --wave 1 --mode full --feature x
[ "$CLI_EXIT" = "0" ] || fail "control: exit $CLI_EXIT ($CLI_STDERR)"
assert_state '.commit_msg_hook == "installed"' || fail "control: want installed"
assert_state '.commit_msg_check == "none"' || fail "control: want commit_msg_check none"
control_hook="$WV_RUN_TMP/$name-control.hook"
cp "$WV_PROJECT/.git/hooks/commit-msg" "$control_hook" 2>/dev/null || fail "control: no hook installed"
commit_rc "$trailer_msg"; [ "$?" = "1" ] || fail "control: a trailer commit was accepted"
commit_rc "$plain_msg" || fail "control: a plain commit was refused"

fault_leg() {
  # fault_leg <label> <fault exit status>
  local label="$1" bin hook check left m
  bin="$(make_fault_bin "$label" "$2")"
  new_project
  hook="$WV_PROJECT/.git/hooks/commit-msg"
  check="$WV_PROJECT/.wave/hooks/commit-msg"
  [ ! -e "$hook" ] || fail "$label: setup: a hook existed before init"
  PATH="$bin:$PATH" run_cli scripts/wave-init.sh --wave 1 --mode full --feature x
  [ -e "$bin/fired" ] || fail "$label: the injected fault never fired (the template is no longer read through cat; re-point this case)"
  [ "$CLI_EXIT" = "0" ] || fail "$label: exit $CLI_EXIT ($CLI_STDERR)"
  assert_state '.commit_msg_hook == "install-failed"' \
    || fail "$label: want install-failed, got $(jq -c '.commit_msg_hook' "$WV_PROJECT/.wave/state.json" 2>/dev/null)"
  assert_state '.commit_msg_check == "written"' || fail "$label: want commit_msg_check written"
  case "$CLI_STDERR" in
    *"wave-init.sh: installed"*|*"wave-init.sh: upgraded"*) fail "$label: an install was reported although the render failed: '$CLI_STDERR'" ;;
  esac
  case "$CLI_STDERR" in *"commit-msg guard is not installed"*) : ;; *) fail "$label: the notice must say the commit-msg guard is not installed: '$CLI_STDERR'" ;; esac
  case "$CLI_STDERR" in *"remedy:"*"$check"*) : ;; *) fail "$label: the notice must name the fallback check ($check) in a remedy: '$CLI_STDERR'" ;; esac
  case "$CLI_STDERR" in *"reference copy"*|*"cannot write"*) : ;; *) fail "$label: the notice must name the failed render step: '$CLI_STDERR'" ;; esac
  [ -e "$hook" ] && fail "$label: a hook was left at $hook after a failed render"
  left="$(ls -A "$WV_PROJECT/.git/hooks" "$WV_PROJECT/.wave" "$WV_PROJECT/.wave/hooks" 2>/dev/null | command grep -E '^\.commit-msg' || true)"
  [ -z "$left" ] || fail "$label: temp files were left behind: $left"
  if [ -f "$check" ]; then
    cmp -s "$check" "$control_hook" || fail "$label: the fallback check is not the intended template"
    m="$WV_RUN_TMP/$name-$label-msg.txt"
    printf '%s' "$trailer_msg" > "$m"
    bash "$check" "$m" >/dev/null 2>&1
    [ "$?" = "1" ] || fail "$label: the fallback check does not refuse a trailer line"
    printf '%s' "$plain_msg" > "$m"
    bash "$check" "$m" >/dev/null 2>&1 || fail "$label: the fallback check refuses a plain message"
  else
    fail "$label: the fallback check $check does not exist"
  fi
  # The fault has cleared (it fires once): init again installs the real hook.
  run_cli scripts/wave-init.sh --wave 2 --mode full --feature y --force
  [ "$CLI_EXIT" = "0" ] || fail "$label rerun: exit $CLI_EXIT ($CLI_STDERR)"
  assert_state '.commit_msg_hook == "installed"' \
    || fail "$label rerun: want installed, got $(jq -c '.commit_msg_hook' "$WV_PROJECT/.wave/state.json" 2>/dev/null)"
  cmp -s "$hook" "$control_hook" || fail "$label rerun: the installed hook is not byte-identical to the control's"
  [ -x "$hook" ] || fail "$label rerun: the hook is not executable"
  commit_rc "$trailer_msg"; [ "$?" = "1" ] || fail "$label rerun: real git accepted a trailer commit"
  commit_rc "$plain_msg" || fail "$label rerun: real git refused a plain commit"
}

fault_leg exitfault 73
fault_leg silentfault 0

# ---- alwaysfault: the fallback cannot be verified either ----------------------------
bin="$(make_fault_bin alwaysfault 73 always)"
new_project
PATH="$bin:$PATH" run_cli scripts/wave-init.sh --wave 1 --mode full --feature x
[ -e "$bin/fired" ] || fail "alwaysfault: the injected fault never fired"
[ "$CLI_EXIT" = "0" ] || fail "alwaysfault: exit $CLI_EXIT ($CLI_STDERR)"
assert_state '.commit_msg_hook == "install-failed"' || fail "alwaysfault: want install-failed"
assert_state '.commit_msg_check == "failed"' || fail "alwaysfault: want commit_msg_check failed"
case "$CLI_STDERR" in
  *"wave-init.sh: installed"*|*"wave-init.sh: upgraded"*) fail "alwaysfault: an install was reported: '$CLI_STDERR'" ;;
esac
case "$CLI_STDERR" in *"could not be written and verified either ("*")"*) : ;; *) fail "alwaysfault: the notice must say the fallback could not be verified, with the step: '$CLI_STDERR'" ;; esac
case "$CLI_STDERR" in *"remedy:"*) fail "alwaysfault: a remedy naming an unverified check was printed: '$CLI_STDERR'" ;; esac
[ -e "$WV_PROJECT/.git/hooks/commit-msg" ] && fail "alwaysfault: a hook was left at the hook path"
[ -e "$WV_PROJECT/.wave/hooks/commit-msg" ] && fail "alwaysfault: an unverified fallback check was left on disk"
left="$(ls -A "$WV_PROJECT/.git/hooks" "$WV_PROJECT/.wave" "$WV_PROJECT/.wave/hooks" 2>/dev/null | command grep -E '^\.commit-msg' || true)"
[ -z "$left" ] || fail "alwaysfault: temp files were left behind: $left"

exit $rc
