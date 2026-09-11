#!/usr/bin/env bash
# tests/cases/stop-225-teet-findings.sh — AC-225: TEET has both an artifact and a
# findings file. The count is recorded when the findings file is there, and its
# ABSENCE is not judged here — the `BF-TEET` dispatch judges that (AC-92), so
# there is one place that decides and not two that can disagree.
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

findings() { jq -r '(.phases.TEET.findings // "unset") | tostring' "$WV_PROJECT/.wave/state.json"; }

drive() {
  WV_PROJECT=""
  local st="$WV_RUN_TMP/$name-$1-state.json" c="$WV_RUN_TMP/$name-$1.json"
  stop_state "$st" ".active = {a1: $(stop_active TEET reviewer sonnet)}" || return 1
  stop_case "$c" "$(printf '.seed.state = "%s" | .seed.files = ({".wave/teet.md": "TEET-VERIFIED\\n"} + %s)' "$st" "$2")" || return 1
  run_hook subagent-stop.sh "$c" || { fail "step $1: run_hook: $WV_LAST_STDERR"; return 1; }
  return 0
}

if drive present '{".wave/findings/TEET.md": "FINDINGS: 2\n"}'; then
  assert_allow || fail "findings present: want no block"
  [ "$(stop_phase_status TEET)" = "done" ] || fail "findings present: want done"
  [ "$(findings)" = "2" ] || fail "findings present: recorded findings is '$(findings)', want 2"
fi

if drive absent '{}'; then
  assert_allow || fail "findings absent: want no block"
  [ "$(stop_phase_status TEET)" = "done" ] || fail "findings absent: want done"
  [ "$(findings)" = "unset" ] || fail "findings absent: findings is '$(findings)', want unset"
fi

exit $rc
