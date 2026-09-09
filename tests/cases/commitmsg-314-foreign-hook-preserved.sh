#!/usr/bin/env bash
# tests/cases/commitmsg-314-foreign-hook-preserved.sh — AC-314.
#
# A repo that already has a .git/hooks/commit-msg not written by this
# plugin: wave-init.sh leaves it byte-identical, reports the fact on stderr,
# and records commit_msg_hook:"skipped-existing".
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

foreign_hook="$WV_PROJECT/.git/hooks/commit-msg"
mkdir -p "$(dirname "$foreign_hook")"
printf '#!/bin/sh\n# a foreign, non-plugin commit-msg hook\nexit 0\n' > "$foreign_hook"
chmod +x "$foreign_hook"
before_sum="$(sha256sum "$foreign_hook" | awk '{print $1}')"

run_cli scripts/wave-init.sh --wave 1 --mode full --feature x
[ "$CLI_EXIT" = "0" ] || fail "exit: want 0, got $CLI_EXIT (stderr: $CLI_STDERR)"

after_sum="$(sha256sum "$foreign_hook" | awk '{print $1}')"
[ "$before_sum" = "$after_sum" ] || fail "the foreign commit-msg hook was modified (sha256 $before_sum -> $after_sum)"

case "$CLI_STDERR" in
  *"$foreign_hook"*) : ;;
  *) fail "wave-init.sh did not report the pre-existing hook on stderr: '$CLI_STDERR'" ;;
esac

assert_state '.commit_msg_hook == "skipped-existing"' || rc=1

exit $rc
