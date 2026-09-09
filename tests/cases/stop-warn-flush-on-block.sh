#!/usr/bin/env bash
# tests/cases/stop-warn-flush-on-block.sh — fix round 1, item 7.
#
# A block is one JSON object on stdout, and SubagentStop has no
# additionalContext channel to carry anything else — so `wv_block` used to
# DISCARD every warning queued before it. The warnings it discarded are the ones
# that say the hook could not measure something, which is exactly what a reader
# needs to know when a block arrives.
#
# The construction: `ui` is true and `.wave/green.md` exists, is non-empty, and
# is UNREADABLE. Its marker scan returns no count, which is a FAILED scan and
# therefore a queued W-STATE (never a marker failure — a scan that did not run
# has measured nothing). The screenshot requirement then fails on its own, so the
# stop blocks W-ARTIFACT. Both must reach the operator: the block object on
# stdout, the W-STATE line on stderr.
set -u

# shellcheck source=tests/lib/assert.sh
source "$(dirname "$0")/../lib/assert.sh"
# shellcheck source=tests/lib/stop.sh
source "$(dirname "$0")/../lib/stop.sh"

name="${WV_CASE_NAME:-$(basename "$0" .sh)}"
log="${WV_CASE_LOG:-$WV_RUN_TMP/logs/$name.log}"
rc=0
fail() { printf 'ASSERT FAIL: %s\n' "$*" >&2; rc=1; }
printf 'RAN subagent-stop.sh %s decision=block\n' "$name" >> "$log"

if [ "$(id -u)" = "0" ]; then
  printf 'SKIPPED %s: running as root, so an unreadable file is still readable\n' "$name" >&2
  # A skip must never read as a pass: fail the case loudly instead of exiting 0.
  fail "this case cannot measure anything as root"
  exit $rc
fi

WV_PROJECT="$(mkproj)"
mkdir -p "$WV_PROJECT/.wave/screenshots" || exit 1
printf 'GREEN-VERIFIED passing=42 failing=0\n' > "$WV_PROJECT/.wave/green.md"
chmod 000 "$WV_PROJECT/.wave/green.md" || exit 1

st="$WV_RUN_TMP/$name-state.json"
c="$WV_RUN_TMP/$name.json"
stop_state "$st" ".active = {a1: $(stop_active TDE-GREEN reviewer opus)} | .ui = true" || exit 1
stop_case "$c" "$(printf '.seed.state = "%s"' "$st")" || exit 1
run_hook subagent-stop.sh "$c" || { fail "run_hook: $WV_LAST_STDERR"; exit 1; }

assert_block W-ARTIFACT || fail "want block(W-ARTIFACT) from the screenshot requirement"
assert_single_rule_token || fail "the block object still carries exactly one rule id"
case "$WV_LAST_STDERR" in
  *W-STATE*) : ;;
  *) fail "the queued W-STATE (the failed marker scan) must reach stderr, got '$WV_LAST_STDERR'" ;;
esac
case "$WV_LAST_STDERR" in
  *green.md*) : ;;
  *) fail "the W-STATE line must name the file whose scan did not run, got '$WV_LAST_STDERR'" ;;
esac
[ "$(stop_phase_status TDE-GREEN)" != "done" ] || fail "TDE-GREEN must not be done"

chmod 644 "$WV_PROJECT/.wave/green.md" 2>/dev/null
exit $rc
