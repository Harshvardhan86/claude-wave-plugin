#!/usr/bin/env bash
# tests/cases/init-scope-audit.sh — an answer given to wave-init.sh is recorded
# in .wave/approvals/scope.md exactly as scripts/wave-set.sh records one
# (`<ts> <key>=<value>`, the key wave-set.sh takes), so the scope record of a
# wave started by /wave-start holds every answer. A flag not given (still
# "unknown") writes no line, and a refused init writes none.
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
audit="$WV_PROJECT/.wave/approvals/scope.md"

run_cli scripts/wave-init.sh --wave 1 --mode full --vocabulary --no-behaviour-change --ui --feature x
[ "$CLI_EXIT" = "0" ] || fail "init: exit $CLI_EXIT ($CLI_STDERR)"
TS='[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z'
for want in 'ui=true' 'vocabulary=true' 'behaviour-change=false'; do
  command grep -qxE "$TS $want" "$audit" 2>/dev/null || fail "scope.md has no '<ts> $want' line: '$(cat "$audit" 2>/dev/null)'"
done
command grep -qE ' cr=' "$audit" 2>/dev/null && fail "cr was not given, so it must not be recorded: '$(cat "$audit")'"
n="$(wc -l < "$audit" 2>/dev/null)"
[ "$n" = "3" ] || fail "want exactly 3 audit lines, got ${n:-none}"

# A refused init (active wave, no --force) records nothing.
run_cli scripts/wave-init.sh --wave 2 --mode full --cr --feature y
[ "$CLI_EXIT" != "0" ] || fail "the second init must be refused"
[ "$(wc -l < "$audit")" = "3" ] || fail "a refused init appended to scope.md: '$(cat "$audit")'"

# The record matches wave-set.sh's own line for the same answer.
run_cli scripts/wave-set.sh cr false
[ "$CLI_EXIT" = "0" ] || fail "wave-set: exit $CLI_EXIT ($CLI_STDERR)"
command grep -qxE "$TS cr=false" "$audit" || fail "wave-set.sh's line has a different shape: '$(cat "$audit")'"

exit $rc
