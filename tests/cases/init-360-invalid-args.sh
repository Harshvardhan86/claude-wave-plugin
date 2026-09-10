#!/usr/bin/env bash
# tests/cases/init-360-invalid-args.sh — AC-360.
#
# Eight malformed invocations, each must exit non-zero, name the offending
# argument on stderr, and write no state.json — plus one ACCEPTED id at the
# bound, in a project of its own.
#
# THE WAVE ID IS A BOUNDED FIELD (fix round 2, item 1). It is interpolated TWICE
# into the W-SESSION banner, whose length the reason corpus holds at 400
# characters, and it was rejected only for a space or a `]` — so a 40-character id
# rendered a 458-character reason and made the "400 for any real input" claim in
# session-start.sh false. The bound belongs at CREATION, where there is one
# writer and a person to read the message, not at every render. 24 characters,
# `[A-Za-z0-9._-]`: long enough for a date-stamped or ticket-shaped id, short
# enough that the banner's own budget can be derived from it. The 24-character
# ACCEPT leg is not decoration — without it a bound of 23, or an anchored regex
# that rejects everything, would satisfy every rejection above.
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

state_file="$WV_PROJECT/.wave/state.json"

check_rejected() {
  # check_rejected <label> <needle-in-stderr> -- <args...>
  local label="$1" needle="$2"; shift 2
  [ "$1" = "--" ] && shift
  run_cli scripts/wave-init.sh "$@"
  [ "$CLI_EXIT" != "0" ] || fail "$label: want non-zero exit, got 0 (stdout: $CLI_STDOUT)"
  case "$CLI_STDERR" in
    *"$needle"*) : ;;
    *) fail "$label: stderr does not name '$needle': '$CLI_STDERR'" ;;
  esac
  [ ! -e "$state_file" ] || fail "$label: $state_file was written despite the rejection"
}

check_rejected "invalid --mode" "xyz" -- --mode xyz --wave 1 --feature x
check_rejected "missing --wave" "--wave" -- --mode full --feature x
check_rejected "wave id with a space" "1 2" -- --mode full --wave "1 2" --feature x
check_rejected "wave id with a bracket" "a]b" -- --mode full --wave "a]b" --feature x
check_rejected "invalid --enforce" "loud" -- --mode full --wave 1 --enforce loud --feature x
check_rejected "missing --feature" "--feature" -- --mode full --wave 1

# The wave id's length and character bound. 25 characters is one past the bound,
# which is where an off-by-one lives; `a/b` is a character class the tag grammar
# and every path that quotes the id are better off without.
id24="abcdefghij-klmnopqr.stuv"
id25="abcdefghij-klmnopqr.stuvw"
[ "${#id24}" = "24" ] || fail "the accept fixture is ${#id24} characters, not 24"
[ "${#id25}" = "25" ] || fail "the reject fixture is ${#id25} characters, not 25"
check_rejected "wave id one character over the bound" "$id25" -- --mode full --wave "$id25" --feature x
check_rejected "wave id with a slash" "a/b" -- --mode full --wave "a/b" --feature x

[ ! -d "$WV_PROJECT/.wave" ] || fail "no rejection should have created .wave/ at all, but it exists"

# ---- the bound itself is ACCEPTED, in a project of its own -------------------
WV_PROJECT="$(mkproj)"
: > "$WV_PROJECT/README.md"
git -C "$WV_PROJECT" add README.md
git -C "$WV_PROJECT" commit -q -m init
run_cli scripts/wave-init.sh --wave "$id24" --mode full --feature x
[ "$CLI_EXIT" = "0" ] || fail "a 24-character id is at the bound and must be accepted, got exit $CLI_EXIT (stderr: $CLI_STDERR)"
assert_state ".wave == \"$id24\"" || rc=1

exit $rc
