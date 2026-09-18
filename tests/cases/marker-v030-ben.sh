#!/usr/bin/env bash
# tests/cases/marker-v030-ben.sh — BEN and BEN-CLOSE stop markers.
#
# BEN's marker requires red>=1 and authorities>=1. BEN-CLOSE accepts both
# BENEFIT: DELIVERED and BENEFIT: UNDELIVERED and rejects anything else.
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
  # drive <label> <phase> <role> <model> <files-json-object>
  local label="$1" phase="$2" role="$3" model="$4" files="$5"
  WV_PROJECT=""
  local st="$WV_RUN_TMP/$name-$label-state.json" c="$WV_RUN_TMP/$name-$label.json"
  stop_state "$st" \
    ".active = {a1: $(stop_active "$phase" "$role" "$model")} | .behaviour_change = true | .vocabulary = true" \
    || return 1
  stop_case "$c" "$(printf '.seed.state = "%s" | .seed.files = %s' "$st" "$files")" \
    || return 1
  run_hook subagent-stop.sh "$c" || { fail "step $label: run_hook: $WV_LAST_STDERR"; return 1; }
  return 0
}

drive_ben() {
  local label="$1" body="$2"
  drive "$label" BEN reviewer opus "$(jq -nc --arg b "$body" '{".wave/ben.md": $b}')"
}

if drive_ben ben-red0 $'BEN-VERIFIED red=0 authorities=3\n'; then
  assert_block W-MARKER || fail "ben-red0: want block(W-MARKER)"
  assert_reason_contains '^BEN-VERIFIED red=[1-9][0-9]* authorities=[1-9][0-9]*$' \
    || fail "ben-red0: reason must quote the regex"
  [ "$(stop_phase_status BEN)" != "done" ] || fail "ben-red0: BEN must not be done"
fi

if drive_ben ben-auth0 $'BEN-VERIFIED red=4 authorities=0\n'; then
  assert_block W-MARKER || fail "ben-auth0: want block(W-MARKER)"
  [ "$(stop_phase_status BEN)" != "done" ] || fail "ben-auth0: BEN must not be done"
fi

if drive_ben ben-ok $'BEN-VERIFIED red=2 authorities=3\n'; then
  assert_allow || fail "ben-ok: want no block"
  [ "$(stop_phase_status BEN)" = "done" ] || \
    fail "ben-ok: status is '$(stop_phase_status BEN)', want done"
fi

drive_close() {
  local label="$1" body="$2"
  drive "$label" BEN-CLOSE reviewer opus "$(jq -nc --arg b "$body" '{".wave/ben-close.md": $b}')"
}

if drive_close close-delivered $'BENEFIT: DELIVERED\n'; then
  assert_allow || fail "close-delivered: want no block"
  [ "$(stop_phase_status BEN-CLOSE)" = "done" ] || \
    fail "close-delivered: status is '$(stop_phase_status BEN-CLOSE)', want done"
fi

if drive_close close-undelivered $'BENEFIT: UNDELIVERED\nThe benefit test is still red.\n'; then
  assert_allow || fail "close-undelivered: want no block"
  [ "$(stop_phase_status BEN-CLOSE)" = "done" ] || \
    fail "close-undelivered: BEN-CLOSE must be done"
fi

if drive_close close-other $'BENEFIT: MAYBE\n'; then
  assert_block W-MARKER || fail "close-other: want block(W-MARKER)"
  assert_reason_contains '^BENEFIT: (DELIVERED|UNDELIVERED)$' \
    || fail "close-other: reason must quote the regex"
  [ "$(stop_phase_status BEN-CLOSE)" != "done" ] || fail "close-other: must not be done"
fi

if drive_close close-prose $'the benefit was delivered\n'; then
  assert_block W-MARKER || fail "close-prose: want block(W-MARKER)"
  [ "$(stop_phase_status BEN-CLOSE)" != "done" ] || fail "close-prose: must not be done"
fi

exit $rc
