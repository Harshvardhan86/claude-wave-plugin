#!/usr/bin/env bash
# tests/cases/init-358b-force-override.sh — AC-358, the --force half.
#
# Positive control for init-358a: --force must actually let a second
# wave-init.sh succeed over an active wave, and the superseded active state
# must be archived (never silently discarded), so the refusal in 358a is not
# a permanent dead end.
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

run_cli scripts/wave-init.sh --wave 2 --mode full --feature y --force
[ "$CLI_EXIT" = "0" ] || fail "--force init: want exit 0, got $CLI_EXIT (stderr: $CLI_STDERR)"

assert_state '.wave == "2"' || rc=1
assert_state '.status == "active"' || rc=1

archived="$(find "$WV_PROJECT/.wave/archive" -maxdepth 1 -name '*-state.json' 2>/dev/null)"
n="$(printf '%s\n' "$archived" | command grep -c . || true)"
[ -n "$archived" ] && [ "$n" = "1" ] || fail "want exactly 1 archived state file after --force, found: '$archived'"
if [ -n "$archived" ]; then
  archived_wave="$(jq -r '.wave' "$archived")"
  archived_status="$(jq -r '.status' "$archived")"
  [ "$archived_wave" = "1" ] || fail "archived file is wave '$archived_wave', want '1'"
  [ "$archived_status" = "active" ] || fail "archived file has status '$archived_status', want 'active' (it was superseded while still active)"
fi

exit $rc
