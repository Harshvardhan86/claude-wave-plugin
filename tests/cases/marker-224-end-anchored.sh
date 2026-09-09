#!/usr/bin/env bash
# tests/cases/marker-224-end-anchored.sh — AC-224: every `*-VERIFIED` marker is
# END-anchored too. `TEET-VERIFIEDX` does not complete TEET, and
# `BTEET-X-VERIFIED` does not complete BTEET — the second is the collision in the
# other direction from AC-223, and the pair is what pins both anchors.
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
  # drive <label> <phase> <model> <file> <content>
  WV_PROJECT=""
  local label="$1" phase="$2" model="$3" file="$4" content="$5"
  local st="$WV_RUN_TMP/$name-$label-state.json" c="$WV_RUN_TMP/$name-$label.json"
  stop_state "$st" ".active = {a1: $(stop_active "$phase" reviewer "$model")}" || return 1
  stop_case "$c" "$(printf '.seed.state = "%s" | .seed.files = {"%s": "%s\\n"}' "$st" "$file" "$content")" || return 1
  run_hook subagent-stop.sh "$c" || { fail "$label: run_hook: $WV_LAST_STDERR"; return 1; }
  return 0
}

if drive suffix TEET sonnet .wave/teet.md 'TEET-VERIFIEDX'; then
  assert_block W-MARKER || fail "TEET-VERIFIEDX: want block(W-MARKER)"
  [ "$(stop_phase_status TEET)" != "done" ] || fail "TEET-VERIFIEDX: TEET must not be done"
fi

if drive longer BTEET opus .wave/bteet.md 'BTEET-X-VERIFIED'; then
  assert_block W-MARKER || fail "BTEET-X-VERIFIED in bteet.md: want block(W-MARKER)"
  assert_reason_contains '^BTEET-VERIFIED$' || fail "the reason must quote BTEET's own regex"
  [ "$(stop_phase_status BTEET)" != "done" ] || fail "BTEET must not be done"
fi

exit $rc
