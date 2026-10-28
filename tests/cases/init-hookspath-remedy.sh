#!/usr/bin/env bash
# tests/cases/init-hookspath-remedy.sh — the remedy wave-init.sh prints when a
# project sets core.hooksPath is a command the user can paste as is, even when
# the project path contains a space (or a quote).
#
# Real git in a throwaway repository whose path holds a space and a single
# quote, isolated from the machine's own config (GIT_CONFIG_GLOBAL is a temp
# file, GIT_CONFIG_NOSYSTEM=1); no network. core.hooksPath=.husky. The command
# after "remedy: ... hook: " is extracted from the notice VERBATIM and:
#   direct   run as the body of a POSIX sh hook script with a message file as
#            $1: a message carrying a trailer line exits non-zero, a plain
#            message exits 0;
#   git      installed as .husky/commit-msg (#!/bin/sh), the hook manager's
#            own hook: a real `git commit` carrying a trailer line is refused
#            and a plain commit succeeds.
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

WV_PROJECT="$(mktemp -d "$WV_RUN_TMP/space proj'q.XXXXXX")"
WV_PROJECT="$(realpath "$WV_PROJECT")"
export CLAUDE_PROJECT_DIR="$WV_PROJECT"
git -C "$WV_PROJECT" init -q
git -C "$WV_PROJECT" config user.email "wave-test@example.invalid"
git -C "$WV_PROJECT" config user.name "Wave Test Harness"
: > "$WV_PROJECT/README.md"
git -C "$WV_PROJECT" add README.md
git -C "$WV_PROJECT" commit -q -m init
mkdir -p "$WV_PROJECT/.husky"
git -C "$WV_PROJECT" config core.hooksPath .husky

run_cli scripts/wave-init.sh --wave 1 --mode full --feature x
[ "$CLI_EXIT" = "0" ] || fail "exit $CLI_EXIT ($CLI_STDERR)"
assert_state '.commit_msg_hook == "skipped-hookspath"' || fail "want skipped-hookspath"

remedy="$(printf '%s\n' "$CLI_STDERR" | sed -n 's/.*remedy: .* hook: //p' | head -n 1)"
printf 'remedy extracted: %s\n' "$remedy" >> "$log"
[ -n "$remedy" ] || fail "no remedy command found in the notice: '$CLI_STDERR'"

trailer_msg="$WV_RUN_TMP/$name-trailer.txt"
plain_msg="$WV_RUN_TMP/$name-plain.txt"
printf 'subject\n\nClaude-Session: https://example.invalid/s/1\n' > "$trailer_msg"
printf 'subject\n' > "$plain_msg"

# ---- direct: the printed command as a hook body, $1 = the message file ---------
hook_body="$WV_RUN_TMP/$name-hook.sh"
printf '#!/bin/sh\n%s\n' "$remedy" > "$hook_body"
( cd "$WV_PROJECT" && sh "$hook_body" "$trailer_msg" ) > "$WV_RUN_TMP/$name-direct.out" 2>&1
direct_rc=$?
printf 'direct trailer rc=%s: %s\n' "$direct_rc" "$(cat "$WV_RUN_TMP/$name-direct.out")" >> "$log"
[ "$direct_rc" = "1" ] || fail "direct: the printed remedy did not refuse a trailer line (rc=$direct_rc: $(cat "$WV_RUN_TMP/$name-direct.out"))"
( cd "$WV_PROJECT" && sh "$hook_body" "$plain_msg" ) > "$WV_RUN_TMP/$name-direct.out" 2>&1
direct_rc=$?
[ "$direct_rc" = "0" ] || fail "direct: the printed remedy refused a plain message (rc=$direct_rc: $(cat "$WV_RUN_TMP/$name-direct.out"))"

# ---- git: the printed command as the hook manager's commit-msg hook -----------
printf '#!/bin/sh\n%s\n' "$remedy" > "$WV_PROJECT/.husky/commit-msg"
chmod +x "$WV_PROJECT/.husky/commit-msg"
: > "$WV_PROJECT/a.txt"
git -C "$WV_PROJECT" add a.txt
if git -C "$WV_PROJECT" commit -q -F "$trailer_msg" >> "$log" 2>&1; then
  fail "git: a commit carrying a trailer line was accepted through the printed remedy"
fi
git -C "$WV_PROJECT" commit -q -F "$plain_msg" >> "$log" 2>&1 \
  || fail "git: a plain commit was refused through the printed remedy"

exit $rc
