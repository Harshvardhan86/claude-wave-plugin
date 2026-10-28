#!/usr/bin/env bash
# tests/cases/init-two-wave-markers.sh — the close-time warnings are once per
# WAVE, not once per project.
#
# .wave/.undelivered-warned, .wave/.scorecard-printed and .wave/.leftover-warned
# live in the project's one .wave/ directory. wave-init.sh removes them when it
# creates a new wave, and only then:
#   wave 1  closes UNVERIFIED through the closing SubagentStop: W-UNDELIVERED
#           then W-SCORECARD, markers U+ S+ written;
#   wave 2  is initialised in the same project (wave 1's markers gone), reaches
#           the same closing stop, and is announced AGAIN with the same ordered
#           composition and its own markers;
#   refusal an init refused over an active wave (no --force) and an init
#           refused for a bad argument both leave the markers in place.
set -u

# shellcheck source=tests/lib/assert.sh
source "$(dirname "$0")/../lib/assert.sh"

name="$(basename "$0" .sh)"
log="${WV_CASE_LOG:-$WV_RUN_TMP/logs/$name.log}"
mkdir -p "$(dirname "$log")"

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

CASE="$WV_TESTS_DIR/cases/undelivered-close-unverified.json"
FIXTURE="$WV_TESTS_DIR/fixtures/state/full-closing-cl-bc.json"

close_stop() {
  # close_stop <label> <case-json> — the CL SubagentStop that closes the wave.
  local label="$1" c="$2" got
  run_hook subagent-stop.sh "$c" || { fail "$label: run_hook: $WV_LAST_STDERR"; return 1; }
  [ -z "$WV_LAST_STDOUT" ] || fail "$label: stdout must stay empty, got '$WV_LAST_STDOUT'"
  got="$(tokens "$WV_LAST_STDERR")"
  [ "$got" = "W-UNDELIVERED W-SCORECARD" ] \
    || fail "$label: want stderr rule ids [W-UNDELIVERED W-SCORECARD] in this order, got [$got] in '$WV_LAST_STDERR'"
  assert_state '.status == "closed" and .delivery == "unverified"' \
    || fail "$label: the wave must close with delivery unverified"
  got="$(markers)"
  [ "$got" = "L- U+ S+" ] || fail "$label: want markers [L- U+ S+], got [$got]"
}

# ---- wave 1 -----------------------------------------------------------------
WV_PROJECT="$(mkproj)"
: > "$WV_PROJECT/README.md"
git -C "$WV_PROJECT" add README.md
git -C "$WV_PROJECT" commit -q -m init

close_stop wave1 "$CASE"
assert_state '.wave == "1"' || fail "wave1: the closed wave must be wave 1"

# ---- refusals keep the markers -------------------------------------------------
# A refused init writes nothing, markers included. The refusal over an active
# wave needs an active state: reopen wave 1 for that one leg, then put it back.
cp "$WV_PROJECT/.wave/state.json" "$WV_RUN_TMP/$name-closed.json"
jq '.status = "active"' "$WV_RUN_TMP/$name-closed.json" > "$WV_PROJECT/.wave/state.json"
run_cli scripts/wave-init.sh --wave 2 --mode full --feature refused
[ "$CLI_EXIT" != "0" ] || fail "refusal: init over an active wave without --force must exit non-zero"
[ "$(markers)" = "L- U+ S+" ] || fail "refusal (active wave): markers changed to [$(markers)]"
cp "$WV_RUN_TMP/$name-closed.json" "$WV_PROJECT/.wave/state.json"

run_cli scripts/wave-init.sh --wave 'a/b' --mode full --feature refused
[ "$CLI_EXIT" != "0" ] || fail "refusal: an invalid --wave must exit non-zero"
[ "$(markers)" = "L- U+ S+" ] || fail "refusal (bad argument): markers changed to [$(markers)]"

# ---- wave 2 -----------------------------------------------------------------
run_cli scripts/wave-init.sh --wave 2 --mode full --no-vocabulary --behaviour-change \
  --no-ui --no-cr --feature second
[ "$CLI_EXIT" = "0" ] || fail "wave2 init: exit $CLI_EXIT, stderr: $CLI_STDERR"
[ "$(markers)" = "L- U- S-" ] \
  || fail "wave2 init: a new wave must start with no once-per-wave marker, got [$(markers)]"

# Wave 2 reaches the same closing position: its own id and start time, wave 1's
# phase map (BEN done, no .wave/ben-close.md), so the verdict is unverified again.
st="$WV_PROJECT/.wave/state.json"
jq --slurpfile f "$FIXTURE" '.phases = $f[0].phases | .active = ($f[0].active // {})' \
  "$st" > "$st.tmp" && mv "$st.tmp" "$st" || fail "wave2: could not seed the closing phase map"
rm -f "$WV_PROJECT/.wave/ben-close.md"
again="$WV_RUN_TMP/$name-wave2.json"
jq 'del(.seed.state)' "$CASE" > "$again" || fail "wave2: could not write the stop case"
close_stop wave2 "$again"
assert_state '.wave == "2"' || fail "wave2: the closed wave must be wave 2"

exit $rc
