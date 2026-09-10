#!/usr/bin/env bash
# tests/cases/wiring-378-plugin-validate.sh — AC-378.
#
# `claude plugin validate .` exits 0 -- necessary, and explicitly NOT
# sufficient: AC-379 (the real headless load proof, tests/e2e.sh) is what
# catches the "Duplicate hooks file detected ... Hook load failed" failure
# mode this validator does not see (Global Constraint 1).
set -u

# shellcheck source=tests/lib/assert.sh
source "$(dirname "$0")/../lib/assert.sh"

name="$(basename "$0" .sh)"
log="${WV_CASE_LOG:-$WV_RUN_TMP/logs/$name.log}"
mkdir -p "$(dirname "$log")"

rc=0
fail() { printf 'ASSERT FAIL: %s\n' "$*" >&2; rc=1; }

if ! command -v claude >/dev/null 2>&1; then
  printf 'SKIPPED wiring-378: claude is not on PATH\n' >&2
  printf 'RAN wiring-378 skipped=claude-not-on-PATH\n' >> "$log"
  exit 0
fi

out="$(cd "$WV_REPO_ROOT" && timeout 60 claude plugin validate . 2>&1)"
vrc=$?

[ "$vrc" = "0" ] || fail "claude plugin validate . exited $vrc: $out"

printf 'RAN wiring-378 exit=%s\n' "$vrc" >> "$log"
exit $rc
