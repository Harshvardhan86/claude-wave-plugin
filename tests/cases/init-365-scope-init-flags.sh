#!/usr/bin/env bash
# tests/cases/init-365-scope-init-flags.sh — AC-365.
#
# wave-init.sh's two new flag pairs write boolean scope fields at init time,
# an unknown flag is still refused with nothing written, and giving both
# members of a pair follows the --ui/--no-ui rule already in the script
# (last flag wins, silently).
set -u

# shellcheck source=tests/lib/assert.sh
source "$(dirname "$0")/../lib/assert.sh"

name="$(basename "$0" .sh)"
log="${WV_CASE_LOG:-$WV_RUN_TMP/logs/$name.log}"
mkdir -p "$(dirname "$log")"

rc=0
fail() { printf 'ASSERT FAIL: %s\n' "$*" >&2; rc=1; }

fresh_proj() {
  WV_PROJECT="$(mkproj)"
  : > "$WV_PROJECT/README.md"
  git -C "$WV_PROJECT" add README.md
  git -C "$WV_PROJECT" commit -q -m init
}

# Usage text names both new pairs the same way it already names --ui|--no-ui.
init_src="$(cat "$WV_REPO_ROOT/scripts/wave-init.sh")"
case "$init_src" in
  *'[--vocabulary|--no-vocabulary]'*) : ;;
  *) fail "wave-init.sh usage does not mention [--vocabulary|--no-vocabulary]" ;;
esac
case "$init_src" in
  *'[--behaviour-change|--no-behaviour-change]'*) : ;;
  *) fail "wave-init.sh usage does not mention [--behaviour-change|--no-behaviour-change]" ;;
esac

fresh_proj
run_cli scripts/wave-init.sh --wave 1 --mode full --vocabulary --feature x
[ "$CLI_EXIT" = "0" ] || fail "--vocabulary: exit want 0, got $CLI_EXIT (stderr: $CLI_STDERR)"
assert_state '.vocabulary == true' || rc=1
assert_state '.behaviour_change == "unknown"' || rc=1

fresh_proj
run_cli scripts/wave-init.sh --wave 1 --mode full --no-vocabulary --feature x
[ "$CLI_EXIT" = "0" ] || fail "--no-vocabulary: exit want 0, got $CLI_EXIT (stderr: $CLI_STDERR)"
assert_state '.vocabulary == false' || rc=1
assert_state '.behaviour_change == "unknown"' || rc=1

fresh_proj
run_cli scripts/wave-init.sh --wave 1 --mode full --behaviour-change --feature x
[ "$CLI_EXIT" = "0" ] || fail "--behaviour-change: exit want 0, got $CLI_EXIT (stderr: $CLI_STDERR)"
assert_state '.behaviour_change == true' || rc=1
assert_state '.vocabulary == "unknown"' || rc=1

fresh_proj
run_cli scripts/wave-init.sh --wave 1 --mode full --no-behaviour-change --feature x
[ "$CLI_EXIT" = "0" ] || fail "--no-behaviour-change: exit want 0, got $CLI_EXIT (stderr: $CLI_STDERR)"
assert_state '.behaviour_change == false' || rc=1
assert_state '.vocabulary == "unknown"' || rc=1

# Both members of a pair: last flag wins, matching --ui then --no-ui.
fresh_proj
run_cli scripts/wave-init.sh --wave 1 --mode full --vocabulary --no-vocabulary --feature x
[ "$CLI_EXIT" = "0" ] || fail "--vocabulary --no-vocabulary: exit want 0, got $CLI_EXIT (stderr: $CLI_STDERR)"
assert_state '.vocabulary == false' || rc=1

fresh_proj
run_cli scripts/wave-init.sh --wave 1 --mode full --no-vocabulary --vocabulary --feature x
[ "$CLI_EXIT" = "0" ] || fail "--no-vocabulary --vocabulary: exit want 0, got $CLI_EXIT (stderr: $CLI_STDERR)"
assert_state '.vocabulary == true' || rc=1

fresh_proj
run_cli scripts/wave-init.sh --wave 1 --mode full --behaviour-change --no-behaviour-change --feature x
[ "$CLI_EXIT" = "0" ] || fail "--behaviour-change --no-behaviour-change: exit want 0, got $CLI_EXIT (stderr: $CLI_STDERR)"
assert_state '.behaviour_change == false' || rc=1

fresh_proj
run_cli scripts/wave-init.sh --wave 1 --mode full --no-behaviour-change --behaviour-change --feature x
[ "$CLI_EXIT" = "0" ] || fail "--no-behaviour-change --behaviour-change: exit want 0, got $CLI_EXIT (stderr: $CLI_STDERR)"
assert_state '.behaviour_change == true' || rc=1

# An unknown flag is still refused and writes no state — same contract as
# tests/cases/init-360-invalid-args.sh, after the new pairs exist.
fresh_proj
state_file="$WV_PROJECT/.wave/state.json"
run_cli scripts/wave-init.sh --wave 1 --mode full --feature x --not-a-real-flag
[ "$CLI_EXIT" != "0" ] || fail "unknown flag: want non-zero exit, got 0 (stdout: $CLI_STDOUT)"
case "$CLI_STDERR" in
  *'--not-a-real-flag'*) : ;;
  *) fail "unknown flag: stderr does not name '--not-a-real-flag': '$CLI_STDERR'" ;;
esac
[ ! -e "$state_file" ] || fail "unknown flag: $state_file was written despite the rejection"
[ ! -d "$WV_PROJECT/.wave" ] || fail "unknown flag: .wave/ was created despite the rejection"

exit $rc
