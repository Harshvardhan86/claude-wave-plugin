#!/usr/bin/env bash
set -u
source "$(dirname "$0")/../lib/assert.sh"
name="${WV_CASE_NAME:-$(basename "$0" .sh)}"
log="${WV_CASE_LOG:-$WV_RUN_TMP/logs/$name.log}"
rc=0
fail() { printf 'ASSERT FAIL: %s\n' "$*" >&2; rc=1; }
source "$WV_TESTS_DIR/fixtures/leftover-case.sh"

WV_PROJECT="$(mkproj)"
lo_case '.'
lo_run stop.sh
assert_warn W-LEFTOVER || rc=1
lo_checkpoint
first_cp="$lo_cp"
printf '\nSTALE SECTION\n' >> "$lo_cp"
lo_case 'del(.seed)'
lo_run stop.sh
case "$WV_LAST_STDOUT" in
  *W-LEFTOVER*) fail 'leftover warning repeated on second Stop' ;;
esac
lo_checkpoint
[ "$lo_cp" = "$first_cp" ] || fail 'second Stop wrote a new leftovers checkpoint file'
command grep -q 'STALE SECTION' "$lo_cp" && fail 'checkpoint leftovers section was not replaced in place'
[ "$(command grep -c '^## Leftovers$' "$lo_cp")" = 1 ] || fail 'duplicate checkpoint section'

# .scorecard-printed must not skip inventory (leftovermarkerfirst killer).
WV_PROJECT="$(mkproj)"
lo_case '.seed.files[".wave/.scorecard-printed"] = ""'
lo_run stop.sh
assert_warn W-LEFTOVER || rc=1
lo_checkpoint
lo_contains b2

for variant in closed no-wave; do
  WV_PROJECT="$(mkproj)"
  if [ "$variant" = closed ]; then
    seed_state state/full-all-done.json
    jq '.status = "closed"' "$WV_PROJECT/.wave/state.json" > "$lo_c.state" && mv "$lo_c.state" "$WV_PROJECT/.wave/state.json"
  fi
  lo_case 'del(.seed)'
  lo_run stop.sh
  assert_silent || rc=1
  [ ! -d "$WV_PROJECT/.wave/checkpoints" ] || fail 'inactive wave wrote checkpoint'
done

exit $rc
