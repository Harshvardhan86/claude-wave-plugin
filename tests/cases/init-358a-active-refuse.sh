#!/usr/bin/env bash
# tests/cases/init-358a-active-refuse.sh — AC-358.
#
# An existing state.json whose status is "active": wave-init.sh without
# --force exits non-zero, names the existing state file and the close
# command on stderr, and leaves the file byte-identical.
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

run_cli scripts/wave-init.sh --wave 1 --mode full --feature x
[ "$CLI_EXIT" = "0" ] || fail "setup init: exit $CLI_EXIT, stderr: $CLI_STDERR"

state_file="$WV_PROJECT/.wave/state.json"
before="$(cat "$state_file")"

run_cli scripts/wave-init.sh --wave 2 --mode full --feature y
[ "$CLI_EXIT" != "0" ] || fail "a second init over an active wave without --force must exit non-zero"

case "$CLI_STDERR" in
  *"$state_file"*) : ;;
  *) fail "stderr does not name the existing state file: '$CLI_STDERR'" ;;
esac
case "$CLI_STDERR" in
  *"wave-close"*) : ;;
  *) fail "stderr does not name the close command: '$CLI_STDERR'" ;;
esac

after="$(cat "$state_file")"
[ "$before" = "$after" ] || fail "the existing state.json was modified by the refused init"

exit $rc
