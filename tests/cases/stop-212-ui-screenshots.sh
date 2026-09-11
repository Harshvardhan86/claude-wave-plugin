#!/usr/bin/env bash
# tests/cases/stop-212-ui-screenshots.sh — AC-212: while `ui` is true, TDE-GREEN
# needs a non-empty `.wave/screenshots/green-<name>.png` on top of a valid
# green.md, in all three data states:
#
#   empty   (no screenshots directory at all) -> block(W-ARTIFACT)
#   partial (the directory exists, no PNG)    -> block(W-ARTIFACT)
#   full    (green-home.png, non-empty)       -> done
#
# The reason names the required form `^green-.+\.png$`, because "add a
# screenshot" is not an instruction an agent can follow deterministically.
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

GREEN='.seed.files = {".wave/green.md": "GREEN-VERIFIED passing=42 failing=0\n"}'

drive() {
  # drive <step> <case filter> [<mkdir-relative-path>] — a fresh project with
  # ui:true. The optional third argument is a directory planted before the run,
  # which seed.files cannot express (it only writes regular files).
  WV_PROJECT=""
  local st="$WV_RUN_TMP/$name-$1-state.json" c="$WV_RUN_TMP/$name-$1.json"
  if [ -n "${3:-}" ]; then
    WV_PROJECT="$(mkproj)"
    mkdir -p "$WV_PROJECT/$3" || { fail "step $1: could not plant $3"; return 1; }
  fi
  stop_state "$st" ".active = {a1: $(stop_active TDE-GREEN reviewer opus)} | .ui = true" || return 1
  stop_case "$c" "$(printf '.seed.state = "%s" | %s' "$st" "$2")" || return 1
  run_hook subagent-stop.sh "$c" || { fail "step $1: run_hook: $WV_LAST_STDERR"; return 1; }
  return 0
}

if drive empty "$GREEN"; then
  assert_block W-ARTIFACT || fail "empty: want block(W-ARTIFACT)"
  assert_reason_contains '^green-.+\.png$' || fail "empty: the reason must name the required form"
  [ "$(stop_phase_status TDE-GREEN)" != "done" ] || fail "empty: TDE-GREEN must not be done"
fi

if drive partial "$GREEN" .wave/screenshots; then
  assert_block W-ARTIFACT || fail "partial: want block(W-ARTIFACT)"
  [ "$(stop_phase_status TDE-GREEN)" != "done" ] || fail "partial: TDE-GREEN must not be done"
fi

if drive full "$GREEN"' | .seed.files[".wave/screenshots/green-home.png"] = "PNGBYTES"'; then
  assert_allow || fail "full: want no block"
  [ "$(stop_phase_status TDE-GREEN)" = "done" ] || \
    fail "full: status is '$(stop_phase_status TDE-GREEN)', want done"
fi

exit $rc
