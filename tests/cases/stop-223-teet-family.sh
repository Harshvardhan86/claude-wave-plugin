#!/usr/bin/env bash
# tests/cases/stop-223-teet-family.sh — AC-223: four phases whose markers share a
# prefix. Each completes on its OWN marker, and a prefix collision must not
# satisfy the wrong phase: `teet.md` carrying `BTEET-VERIFIED` while the phase is
# TEET is a block, which is exactly what an unanchored `TEET-VERIFIED` search
# would let through.
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
  # drive <label> <phase> <role> <model> <file> <content>
  WV_PROJECT=""
  local label="$1" phase="$2" role="$3" model="$4" file="$5" content="$6"
  local st="$WV_RUN_TMP/$name-$label-state.json" c="$WV_RUN_TMP/$name-$label.json"
  stop_state "$st" ".active = {a1: $(stop_active "$phase" "$role" "$model")}" || return 1
  stop_case "$c" "$(printf '.seed.state = "%s" | .seed.files = {"%s": "%s\\n"}' "$st" "$file" "$content")" || return 1
  run_hook subagent-stop.sh "$c" || { fail "$label: run_hook: $WV_LAST_STDERR"; return 1; }
  return 0
}

ok() { # ok <label> <phase>
  assert_allow || fail "$1: want no block"
  [ "$(stop_phase_status "$2")" = "done" ] || fail "$1: status is '$(stop_phase_status "$2")', want done"
}

drive teettc TEET-TC reviewer opus .wave/teet-tc.md 'TEET-TC-VERIFIED' && ok teettc TEET-TC
drive teet    TEET    reviewer sonnet .wave/teet.md    'TEET-VERIFIED'    && ok teet TEET
drive bteet   BTEET   reviewer opus  .wave/bteet.md   'BTEET-VERIFIED'   && ok bteet BTEET
drive bteetx  BTEET-X reviewer sonnet .wave/bteet-x.md 'BTEET-X-VERIFIED' && ok bteetx BTEET-X

if drive collide TEET reviewer sonnet .wave/teet.md 'BTEET-VERIFIED'; then
  assert_block W-MARKER || fail "collide: want block(W-MARKER) — BTEET-VERIFIED must not satisfy TEET"
  assert_reason_contains '^TEET-VERIFIED$' || fail "collide: the reason must quote TEET's own regex"
  [ "$(stop_phase_status TEET)" != "done" ] || fail "collide: TEET must not be done"
fi

exit $rc
