#!/usr/bin/env bash
# tests/cases/init-355-git-exclude.sh — AC-355.
#
# wave-init.sh appends `.wave/` to `.git/info/exclude` (never `.gitignore`),
# reports it on stderr, and leaves exactly one such entry across repeated
# init/close/init cycles.
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

gitignore_before="pre-existing user content
node_modules/"
printf '%s\n' "$gitignore_before" > "$WV_PROJECT/.gitignore"

run_cli scripts/wave-init.sh --wave 1 --mode full --feature x
[ "$CLI_EXIT" = "0" ] || fail "first init: exit $CLI_EXIT, stderr: $CLI_STDERR"

exclude_file="$WV_PROJECT/.git/info/exclude"
[ -f "$exclude_file" ] || fail "$exclude_file was not created"
n1="$(command grep -cxF '.wave/' "$exclude_file" 2>/dev/null)"
[ "$n1" = "1" ] || fail "after one init, .git/info/exclude has $n1 '.wave/' lines, want 1"
case "$CLI_STDERR" in
  *"info/exclude"*) : ;;
  *) fail "wave-init.sh did not report the exclude addition on stderr: '$CLI_STDERR'" ;;
esac

gitignore_after1="$(cat "$WV_PROJECT/.gitignore")"
[ "$gitignore_after1" = "$gitignore_before" ] || fail ".gitignore was modified by wave-init.sh"

# Close and re-init (the closed-state path also exercises the exclude step)
run_cli scripts/wave-close.sh
[ "$CLI_EXIT" = "0" ] || fail "wave-close.sh: exit $CLI_EXIT, stderr: $CLI_STDERR"

run_cli scripts/wave-init.sh --wave 2 --mode full --feature x
[ "$CLI_EXIT" = "0" ] || fail "second init: exit $CLI_EXIT, stderr: $CLI_STDERR"

n2="$(command grep -cxF '.wave/' "$exclude_file" 2>/dev/null)"
[ "$n2" = "1" ] || fail "after a second init, .git/info/exclude has $n2 '.wave/' lines, want exactly 1"

gitignore_after2="$(cat "$WV_PROJECT/.gitignore")"
[ "$gitignore_after2" = "$gitignore_before" ] || fail ".gitignore was modified across two inits"

exit $rc
