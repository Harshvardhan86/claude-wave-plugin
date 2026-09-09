#!/usr/bin/env bash
# tests/cases/init-362a-scope-set.sh — AC-362, the positive half.
#
# wave-set.sh ui true, then behaviour-change false, then cr true: each sets
# its state field and appends one dated line to .wave/approvals/scope.md.
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

scope="$WV_PROJECT/.wave/approvals/scope.md"

run_cli scripts/wave-set.sh ui true
[ "$CLI_EXIT" = "0" ] || fail "wave-set.sh ui true: exit $CLI_EXIT, stderr: $CLI_STDERR"
assert_state '.ui == true' || rc=1
[ -f "$scope" ] || fail "$scope was not created"
[ "$(wc -l < "$scope" | tr -d ' ')" = "1" ] || fail "scope.md has $(wc -l < "$scope") lines after 1 set, want 1"
command grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z .*ui=true$' "$scope" || \
  fail "scope.md line 1 is not a dated 'ui=true' entry: $(cat "$scope")"

run_cli scripts/wave-set.sh behaviour-change false
[ "$CLI_EXIT" = "0" ] || fail "wave-set.sh behaviour-change false: exit $CLI_EXIT, stderr: $CLI_STDERR"
assert_state '.behaviour_change == false' || rc=1
[ "$(wc -l < "$scope" | tr -d ' ')" = "2" ] || fail "scope.md has $(wc -l < "$scope") lines after 2 sets, want 2"
command grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z .*behaviour-change=false$' "$scope" || \
  fail "scope.md does not carry a dated 'behaviour-change=false' entry: $(cat "$scope")"

run_cli scripts/wave-set.sh cr true
[ "$CLI_EXIT" = "0" ] || fail "wave-set.sh cr true: exit $CLI_EXIT, stderr: $CLI_STDERR"
assert_state '.cr_enabled == true' || rc=1
[ "$(wc -l < "$scope" | tr -d ' ')" = "3" ] || fail "scope.md has $(wc -l < "$scope") lines after 3 sets, want 3"
command grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z .*cr=true$' "$scope" || \
  fail "scope.md does not carry a dated 'cr=true' entry: $(cat "$scope")"

exit $rc
