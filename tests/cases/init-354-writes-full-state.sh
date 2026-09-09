#!/usr/bin/env bash
# tests/cases/init-354-writes-full-state.sh — AC-354.
#
# A fresh repo, no .wave/: wave-init.sh must write the whole state.json
# schema (spec section 4) in one shot, plus the .wave/ directory set and the
# lock file.
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
expected_sha="$(git -C "$WV_PROJECT" rev-parse HEAD)"

run_cli scripts/wave-init.sh --wave 1 --mode full --feature "hook enforcement layer"
[ "$CLI_EXIT" = "0" ] || { fail "exit: want 0, got $CLI_EXIT (stderr: $CLI_STDERR)"; rc=1; }

state_file="$WV_PROJECT/.wave/state.json"
[ -f "$state_file" ] || { fail "$state_file was not written"; }

if [ -f "$state_file" ]; then
  assert_state '.schema == 1' || rc=1
  assert_state '.wave == "1"' || rc=1
  assert_state '.mode == "full"' || rc=1
  assert_state '.status == "active"' || rc=1
  assert_state '.ui == "unknown"' || rc=1
  assert_state '.behaviour_change == "unknown"' || rc=1
  assert_state '.cr_enabled == "unknown"' || rc=1
  assert_state '.enforce == "block"' || rc=1
  assert_state '.feature == "hook enforcement layer"' || rc=1
  assert_state '.started | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")' || rc=1
  assert_state '.ended == null' || rc=1
  got_sha="$(jq -r '.base_sha' "$state_file")"
  [ "$got_sha" = "$expected_sha" ] || fail "base_sha: want $expected_sha, got $got_sha"
  assert_state '.phases == {}' || rc=1
  assert_state '.active == {}' || rc=1
  assert_state '.pending == {}' || rc=1
  assert_state '.rounds == {}' || rc=1
fi

for d in approvals findings checkpoints screenshots reports archive; do
  [ -d "$WV_PROJECT/.wave/$d" ] || fail ".wave/$d was not created"
done
[ -e "$WV_PROJECT/.wave/lock" ] || fail ".wave/lock was not created"

exit $rc
