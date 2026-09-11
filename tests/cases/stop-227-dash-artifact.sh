#!/usr/bin/env bash
# tests/cases/stop-227-dash-artifact.sh — AC-227: a row whose `artifact` cell is
# `-` has NO artifact check. VB, COMMIT, CL and AD are marked done on the closing
# role's stop with one ledger line and nothing read from disk, which is what
# makes the check table-driven rather than a list of phase codes in the script.
#
# AD is also the full-mode TERMINAL phase, so its stop closes the wave — the one
# place subagent-stop.sh hands over to scripts/wave-close.sh --if-terminal, and
# the one place it must prove that call put nothing on its own stdout.
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

drive() {
  # drive <phase> <model> <expected wave status afterwards>
  WV_PROJECT=""
  local phase="$1" model="$2" want_wave="$3"
  local st="$WV_RUN_TMP/$name-$phase-state.json" c="$WV_RUN_TMP/$name-$phase.json"
  stop_state "$st" ".active = {a1: $(stop_active "$phase" executor "$model")}" || return 1
  stop_case "$c" "$(printf '.seed.state = "%s"' "$st")" || return 1
  run_hook subagent-stop.sh "$c" || { fail "$phase: run_hook: $WV_LAST_STDERR"; return 1; }
  assert_allow || fail "$phase: want no block"
  [ -z "$WV_LAST_STDOUT" ] || fail "$phase: stdout must be empty, got '$WV_LAST_STDOUT'"
  [ "$(stop_phase_status "$phase")" = "done" ] || \
    fail "$phase: status is '$(stop_phase_status "$phase")', want done"
  [ "$(stop_ledger_count)" = "1" ] || fail "$phase: ledger has $(stop_ledger_count) line(s), want 1"
  local got_wave
  got_wave="$(jq -r '.status' "$WV_PROJECT/.wave/state.json")"
  [ "$got_wave" = "$want_wave" ] || \
    fail "$phase: wave status is '$got_wave', want $want_wave"
  return 0
}

# VB, COMMIT and CL are not terminal: completing one of them must leave the wave
# ACTIVE. That is the negative control that stops the terminal-phase close from
# degenerating into "close whenever a phase is done".
drive VB haiku active
drive COMMIT sonnet active
drive CL sonnet active

# AD: the terminal phase of a full wave. Its completion closes the wave, and the
# close must not leak a single byte onto the hook's stdout channel (asserted by
# the empty-stdout check inside drive).
if drive AD haiku closed; then
  [ "$(jq -r '(.ended // "null")' "$WV_PROJECT/.wave/state.json")" != "null" ] || \
    fail "AD: .ended must be set when the wave closes"
fi

exit $rc
