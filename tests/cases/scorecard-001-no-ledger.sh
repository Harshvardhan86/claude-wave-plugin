#!/usr/bin/env bash
# tests/cases/scorecard-001-no-ledger.sh
#
# No .wave/ledger.jsonl at all (and, separately, a 0-byte one): the
# scorecard prints a clear "nothing to score" message and exits 0 --
# deliverable (c)'s "exits 0 with a clear message when no ledger exists".
set -u

# shellcheck source=tests/lib/assert.sh
source "$(dirname "$0")/../lib/assert.sh"

name="$(basename "$0" .sh)"
log="${WV_CASE_LOG:-$WV_RUN_TMP/logs/$name.log}"
mkdir -p "$(dirname "$log")"

rc=0
fail() { printf 'ASSERT FAIL: %s\n' "$*" >&2; rc=1; }

WV_PROJECT="$(mkproj)"
seed_state state/valid-full.json

run_cli scripts/wave-scorecard.sh
[ "$CLI_EXIT" = "0" ] || fail "exit: want 0, got $CLI_EXIT (stderr: $CLI_STDERR)"
case "$CLI_STDOUT" in
  *"no ledger"*) : ;;
  *) fail "stdout does not name the absent ledger: '$CLI_STDOUT'" ;;
esac
[ ! -f "$WV_PROJECT/.wave/scorecard.md" ] || fail "scorecard.md was written even though there is nothing to score"

# The 0-byte-ledger variant of the same claim.
: > "$WV_PROJECT/.wave/ledger.jsonl"
run_cli scripts/wave-scorecard.sh
[ "$CLI_EXIT" = "0" ] || fail "0-byte ledger exit: want 0, got $CLI_EXIT (stderr: $CLI_STDERR)"
case "$CLI_STDOUT" in
  *"no ledger"*) : ;;
  *) fail "0-byte ledger stdout does not name the absent ledger: '$CLI_STDOUT'" ;;
esac

exit $rc
