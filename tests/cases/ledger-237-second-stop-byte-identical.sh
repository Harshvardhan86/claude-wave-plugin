#!/usr/bin/env bash
# tests/cases/ledger-237-second-stop-byte-identical.sh — AC-237: after the agent
# has been ledgered, a second SubagentStop carrying stop_hook_active:true must
# leave `state.json` BYTE-IDENTICAL and append no second ledger line.
#
# That is what makes the block-and-restop loop safe: the platform re-runs this
# hook after every block, and a hook that rewrote a timestamp on each pass would
# turn one completed phase into an unbounded stream of state writes.
set -u

# shellcheck source=tests/lib/assert.sh
source "$(dirname "$0")/../lib/assert.sh"
# shellcheck source=tests/lib/stop.sh
source "$(dirname "$0")/../lib/stop.sh"

name="${WV_CASE_NAME:-$(basename "$0" .sh)}"
log="${WV_CASE_LOG:-$WV_RUN_TMP/logs/$name.log}"
rc=0
fail() { printf 'ASSERT FAIL: %s\n' "$*" >&2; rc=1; }
printf 'RAN subagent-stop.sh %s decision=multi\n' "$name" >> "$log"

WV_PROJECT="$(mkproj)"
st="$WV_RUN_TMP/$name-state.json"
stop_state "$st" ".active = {a1: $(stop_active AC reviewer opus)}" || exit 1

c="$WV_RUN_TMP/$name-1.json"
stop_case "$c" "$(printf '.seed.state = "%s" | .seed.files = {".wave/ac.md": "AC-1 records the spend\\n"}' "$st")" || exit 1
run_hook subagent-stop.sh "$c" || { fail "run 1: $WV_LAST_STDERR"; exit 1; }
[ "$(stop_ledger_count)" = "1" ] || fail "run 1: ledger has $(stop_ledger_count) line(s), want 1"

before="$(sha256sum < "$WV_PROJECT/.wave/state.json" | cut -d' ' -f1)"

c2="$WV_RUN_TMP/$name-2.json"
stop_case "$c2" '.stdin.stop_hook_active = true' || exit 1
run_hook subagent-stop.sh "$c2" || { fail "run 2: $WV_LAST_STDERR"; exit 1; }

assert_allow || fail "run 2: want no block"
[ -z "$WV_LAST_STDOUT" ] || fail "run 2: stdout must be empty, got '$WV_LAST_STDOUT'"
[ "$(stop_ledger_count)" = "1" ] || fail "run 2: ledger has $(stop_ledger_count) line(s), want 1"
after="$(sha256sum < "$WV_PROJECT/.wave/state.json" | cut -d' ' -f1)"
[ "$before" = "$after" ] || fail "run 2: state.json changed ($before -> $after), want byte-identical"

exit $rc
