#!/usr/bin/env bash
# tests/cases/init-360-invalid-args.sh — AC-360.
#
# Six malformed invocations, each must exit non-zero, name the offending
# argument on stderr, and write no state.json.
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

[ ! -d "$WV_PROJECT/.wave" ] || fail "no rejection should have created .wave/ at all, but it exists"

exit $rc
