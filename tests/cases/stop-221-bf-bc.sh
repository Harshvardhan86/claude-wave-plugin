#!/usr/bin/env bash
# tests/cases/stop-221-bf-bc.sh — AC-221: a `BF-<X>` phase completes on its own
# `BF-VERIFIED` artifact and blocks(W-ARTIFACT) naming that exact path when it is
# absent.
#
# The path is read out of `hooks/phases.tsv` rather than written here as a
# literal. AC-221's prose says `.wave/bf-BC.md` while the shipped table row says
# `.wave/bf-bc.md`, and the artifact check is table-driven by construction
# (AC-227) — so the case asserts the ROW's value and cannot be made to pass by a
# hook that hard-codes either spelling.
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

# Column 10 of the BF-BC row, read with the same US re-delimiting the hooks use.
row="$(command grep -m1 -E '^BF-BC'$'\t' "$WV_REPO_ROOT/hooks/phases.tsv")"
artifact="$(printf '%s' "${row//$'\t'/$'\x1f'}" | cut -d$'\x1f' -f10)"
[ -n "$artifact" ] || { fail "could not read the BF-BC artifact cell"; exit 1; }
printf 'BF-BC artifact cell: %s\n' "$artifact"

drive() {
  WV_PROJECT=""
  local st="$WV_RUN_TMP/$name-$1-state.json" c="$WV_RUN_TMP/$name-$1.json"
  stop_state "$st" ".active = {a1: $(stop_active BF-BC reviewer opus)}" || return 1
  stop_case "$c" "$(printf '.seed.state = "%s" | %s' "$st" "$2")" || return 1
  run_hook subagent-stop.sh "$c" || { fail "step $1: run_hook: $WV_LAST_STDERR"; return 1; }
  return 0
}

if drive present "$(printf '.seed.files = {"%s": "BF-VERIFIED\\n"}' "$artifact")"; then
  assert_allow || fail "present: want no block"
  [ "$(stop_phase_status BF-BC)" = "done" ] || \
    fail "present: status is '$(stop_phase_status BF-BC)', want done"
fi

if drive absent '.'; then
  assert_block W-ARTIFACT || fail "absent: want block(W-ARTIFACT)"
  assert_reason_contains "$artifact" || fail "absent: the reason must name $artifact"
  [ "$(stop_phase_status BF-BC)" = "artifact-missing" ] || \
    fail "absent: status is '$(stop_phase_status BF-BC)', want artifact-missing"
fi

exit $rc
