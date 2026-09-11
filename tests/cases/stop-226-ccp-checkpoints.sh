#!/usr/bin/env bash
# tests/cases/stop-226-ccp-checkpoints.sh — AC-226: CCP's artifact cell is a GLOB
# (`.wave/checkpoints/*-ccp.md`) and its marker is `exists`. A PreCompact
# checkpoint (`*-precompact.md`) does not satisfy it: an auto-compact writes one
# of those on its own, and if it completed the phase the wave would silently skip
# the checkpoint it exists to force.
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
  # drive <step> <case filter> [<dir to plant>]
  WV_PROJECT=""
  local st="$WV_RUN_TMP/$name-$1-state.json" c="$WV_RUN_TMP/$name-$1.json"
  if [ -n "${3:-}" ]; then
    WV_PROJECT="$(mkproj)"
    mkdir -p "$WV_PROJECT/$3" || { fail "step $1: could not plant $3"; return 1; }
  fi
  stop_state "$st" ".active = {a1: $(stop_active CCP executor sonnet)}" || return 1
  stop_case "$c" "$(printf '.seed.state = "%s" | %s' "$st" "$2")" || return 1
  run_hook subagent-stop.sh "$c" || { fail "step $1: run_hook: $WV_LAST_STDERR"; return 1; }
  return 0
}

if drive present '.seed.files = {".wave/checkpoints/2026-09-09T12-05-00Z-ccp.md": "the checkpoint\n"}'; then
  assert_allow || fail "ccp present: want no block"
  [ "$(stop_phase_status CCP)" = "done" ] || fail "ccp present: want done, got '$(stop_phase_status CCP)'"
fi

if drive precompact '.seed.files = {".wave/checkpoints/2026-09-09T12-00-00Z-precompact.md": "auto-compact\n"}'; then
  assert_block W-ARTIFACT || fail "precompact only: want block(W-ARTIFACT)"
  assert_reason_contains 'precompact' || \
    fail "precompact only: the reason must say a PreCompact checkpoint does not satisfy CCP"
  [ "$(stop_phase_status CCP)" != "done" ] || fail "precompact only: CCP must not be done"
fi

if drive emptydir '.' .wave/checkpoints; then
  assert_block W-ARTIFACT || fail "empty dir: want block(W-ARTIFACT)"
  [ "$(stop_phase_status CCP)" != "done" ] || fail "empty dir: CCP must not be done"
fi

exit $rc
