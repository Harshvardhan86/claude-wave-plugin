#!/usr/bin/env bash
# tests/cases/stop-218-bc-findings.sh — AC-218: a scan phase's artifact IS its
# findings file, and the count on its first `^FINDINGS: [0-9]+$` line is recorded
# on the phase. `FINDINGS: 0` is a real, complete scan (and the reason the
# skip rule exists), not a missing one; a file with no matching line at all is a
# W-MARKER block quoting the regex.
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

findings() { jq -r '(.phases.BC.findings // "unset") | tostring' "$WV_PROJECT/.wave/state.json"; }

drive() {
  WV_PROJECT=""
  local st="$WV_RUN_TMP/$name-$1-state.json" c="$WV_RUN_TMP/$name-$1.json"
  stop_state "$st" ".active = {a1: $(stop_active BC executor sonnet)}" || return 1
  stop_case "$c" "$(printf '.seed.state = "%s" | %s' "$st" "$2")" || return 1
  run_hook subagent-stop.sh "$c" || { fail "step $1: run_hook: $WV_LAST_STDERR"; return 1; }
  return 0
}

if drive zero '.seed.files = {".wave/findings/BC.md": "FINDINGS: 0\nnothing to report\n"}'; then
  assert_allow || fail "FINDINGS: 0: want no block"
  [ "$(stop_phase_status BC)" = "done" ] || fail "FINDINGS: 0: want done, got '$(stop_phase_status BC)'"
  [ "$(findings)" = "0" ] || fail "FINDINGS: 0: recorded findings is '$(findings)', want 0"
fi

if drive four '.seed.files = {".wave/findings/BC.md": "FINDINGS: 4\n- one\n- two\n"}'; then
  assert_allow || fail "FINDINGS: 4: want no block"
  [ "$(stop_phase_status BC)" = "done" ] || fail "FINDINGS: 4: want done"
  [ "$(findings)" = "4" ] || fail "FINDINGS: 4: recorded findings is '$(findings)', want 4"
fi

if drive nomarker '.seed.files = {".wave/findings/BC.md": "four findings, see below\n"}'; then
  assert_block W-MARKER || fail "no marker: want block(W-MARKER)"
  assert_reason_contains '^FINDINGS: [0-9]+$' || fail "no marker: the reason must quote the regex"
  [ "$(stop_phase_status BC)" != "done" ] || fail "no marker: BC must not be done"
fi

exit $rc
