#!/usr/bin/env bash
# undelivered-close-unverified-markers.sh — the UNVERIFIED close, end to end
# at hook level, with its once-per-wave markers.
#
# Drives the two declarative cases undelivered-close-unverified.json (clean
# inventory) and leftover-436-leftover-unverified.json (an outstanding
# leftover nobody was warned of) — a behaviour-changing full wave, BEN done,
# NO .wave/ben-close.md, closed by the CL SubagentStop — and asserts what a
# JSON case cannot: the markers written in that same call, plus the ordered
# stderr composition and the closed/unverified state again.
#   clean:    W-UNDELIVERED W-SCORECARD  markers L- U+ S+
#   leftover: W-LEFTOVER W-UNDELIVERED   markers L+ U+ S+
# A second closing-style call on the now closed wave is a no-op: silent, no
# marker change.
set -u
source "$(dirname "$0")/../lib/assert.sh"
name="${WV_CASE_NAME:-$(basename "$0" .sh)}"
log="${WV_CASE_LOG:-$WV_RUN_TMP/logs/$name.log}"
rc=0
fail() { printf 'ASSERT FAIL: %s\n' "$*" >&2; rc=1; }

tokens() { printf '%s' "$1" | command grep -oE 'W-[A-Z0-9-]+' | tr '\n' ' ' | sed -E 's/ +$//'; }
markers() {
  local d="$WV_PROJECT/.wave" out="" m f
  for m in L:.leftover-warned U:.undelivered-warned S:.scorecard-printed; do
    f="${m#*:}"
    if [ -e "$d/$f" ]; then out="$out${m%%:*}+ "; else out="$out${m%%:*}- "; fi
  done
  printf '%s' "${out% }"
}

leg() {
  # leg <label> <case json> <want tokens> <want markers>
  local label="$1" c="$WV_TESTS_DIR/cases/$2" want="$3" wantm="$4" got again
  WV_PROJECT=""
  run_hook subagent-stop.sh "$c" || { fail "$label: run_hook: $WV_LAST_STDERR"; return; }
  printf 'RAN %s %s decision=%s\n' subagent-stop.sh "$name" "$(_wv_classify_decision)" >> "$log"
  [ -z "$WV_LAST_STDOUT" ] || fail "$label: stdout must stay empty, got '$WV_LAST_STDOUT'"
  got="$(tokens "$WV_LAST_STDERR")"
  [ "$got" = "$want" ] || fail "$label: want stderr rule ids [$want] in this order, got [$got] in '$WV_LAST_STDERR'"
  assert_stderr_rule_tokens "$want" || fail "$label: ordered stderr rule check"
  assert_stderr_contains 'never checked at close' || fail "$label: the unverified explanation is missing"
  assert_stderr_contains 'scripts/wave-scorecard.sh writes .wave/scorecard.md' || fail "$label: the unverified explanation must name the scorecard script and its path"
  assert_stderr_contains 'remedy: run the BEN-CLOSE phase before closing' || fail "$label: the remedy is missing"
  assert_state '.status == "closed" and .delivery == "unverified"' || fail "$label: the wave must close with delivery unverified"
  got="$(markers)"
  [ "$got" = "$wantm" ] || fail "$label: want markers [$wantm], got [$got]"

  # The same stop again (no re-seed) on the closed wave: nothing more.
  again="$WV_RUN_TMP/$name-$label-again.json"
  jq 'del(.seed)' "$c" > "$again" || { fail "$label: could not write the re-delivery"; return; }
  run_hook subagent-stop.sh "$again" || fail "$label/again: run_hook: $WV_LAST_STDERR"
  assert_silent || fail "$label/again: a stop on the closed wave must be silent"
  got="$(markers)"
  [ "$got" = "$wantm" ] || fail "$label/again: markers changed to [$got], want [$wantm]"
}

leg clean undelivered-close-unverified.json "W-UNDELIVERED W-SCORECARD" "L- U+ S+"
leg leftover leftover-436-leftover-unverified.json "W-LEFTOVER W-UNDELIVERED" "L+ U+ S+"

exit $rc
