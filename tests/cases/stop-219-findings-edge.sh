#!/usr/bin/env bash
# tests/cases/stop-219-findings-edge.sh — AC-219, the three edges of the findings
# marker:
#
#   `FINDINGS:0`  (no space)         -> block(W-MARKER); the regex is exact
#   `FINDINGS: 00`                   -> done with findings == 0, parsed base 10,
#                                       so `08` is 8 and never an octal error
#   `FINDINGS: 0` then `FINDINGS: 5` -> done with findings == 0; the FIRST
#                                       matching line is authoritative
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

if drive nospace '.seed.files = {".wave/findings/BC.md": "FINDINGS:0\n"}'; then
  assert_block W-MARKER || fail "FINDINGS:0: want block(W-MARKER)"
  [ "$(stop_phase_status BC)" != "done" ] || fail "FINDINGS:0: BC must not be done"
fi

if drive doublezero '.seed.files = {".wave/findings/BC.md": "FINDINGS: 00\n"}'; then
  assert_allow || fail "FINDINGS: 00: want no block"
  [ "$(stop_phase_status BC)" = "done" ] || fail "FINDINGS: 00: want done"
  [ "$(findings)" = "0" ] || fail "FINDINGS: 00: recorded findings is '$(findings)', want 0"
fi

if drive firstwins '.seed.files = {".wave/findings/BC.md": "FINDINGS: 0\nlater, someone appended:\nFINDINGS: 5\n"}'; then
  assert_allow || fail "first wins: want no block"
  [ "$(findings)" = "0" ] || fail "first wins: recorded findings is '$(findings)', want 0"
fi

exit $rc
