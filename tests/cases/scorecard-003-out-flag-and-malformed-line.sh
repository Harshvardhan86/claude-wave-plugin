#!/usr/bin/env bash
# tests/cases/scorecard-003-out-flag-and-malformed-line.sh
#
# --out <path> writes there instead of the default .wave/scorecard.md, and
# a torn/malformed ledger line (a lock defect elsewhere, never this
# script's problem) is skipped rather than crashing the render.
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

cat > "$WV_PROJECT/.wave/ledger.jsonl" <<'LEDGER'
{"agent":"a1","phase":"AC","role":"reviewer","resolved":"opus","output":100}
not even json
{"agent":"a2","phase":"AC","role":"reviewer","resolved":"opus","output":200}
LEDGER

run_cli scripts/wave-scorecard.sh --out reports/custom-scorecard.md
[ "$CLI_EXIT" = "0" ] || fail "exit: want 0, got $CLI_EXIT (stderr: $CLI_STDERR)"

[ -f "$WV_PROJECT/reports/custom-scorecard.md" ] || fail "--out path was not written"
[ -f "$WV_PROJECT/.wave/scorecard.md" ] && fail "the default .wave/scorecard.md was ALSO written when --out was given"

n_rows="$(printf '%s\n' "$CLI_STDOUT" | command grep -c '| AC | reviewer |')"
[ "$n_rows" = "2" ] || fail "want 2 AC rows (the malformed line skipped, not counted, not crashing), got $n_rows"

case "$CLI_STDERR" in
  *"unbound variable"*) fail "stderr carries an unbound-variable trace: $CLI_STDERR" ;;
esac

exit $rc
