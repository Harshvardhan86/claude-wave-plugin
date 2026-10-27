#!/usr/bin/env bash
# tests/cases/init-delivery-54.sh — design 5.4 delivery table, through real
# wave-close.sh. Every row, plus: verdict on line 5 is still read; a file
# with both verdict lines takes the FIRST; bare close of an incomplete
# behaviour-changing wave records unverified.
set -u

# shellcheck source=tests/lib/assert.sh
source "$(dirname "$0")/../lib/assert.sh"

name="$(basename "$0" .sh)"
log="${WV_CASE_LOG:-$WV_RUN_TMP/logs/$name.log}"
mkdir -p "$(dirname "$log")"

rc=0
fail() { printf 'ASSERT FAIL: %s\n' "$*" >&2; rc=1; }

ALWAYS="AC ACB TDE-RED TDE-GREEN BC SEA DS BSEA OA TEET-TC TEET BTEET BTEET-X VB COMMIT CL CCP"

done_map() {
  {
    printf '%s\n' $ALWAYS
    printf '%s\n' "$@"
  } | awk 'NF && !seen[$0]++' | jq -R . | jq -s '
    map({(.): {status:"done", at:"2026-09-09T12:10:00Z", agent:"a0"}}) | add
  '
}

setup() {
  WV_PROJECT="$(mkproj)"
  : > "$WV_PROJECT/README.md"
  git -C "$WV_PROJECT" add README.md
  git -C "$WV_PROJECT" commit -q -m init
  run_cli scripts/wave-init.sh --wave 1 --mode full --feature x --force
  [ "$CLI_EXIT" = "0" ] || fail "init: exit $CLI_EXIT, stderr: $CLI_STDERR"
}

close_and_read() {
  # Sets GOT_DELIVERY. Must not run in a command substitution: that would
  # lose CLI_STDERR, which the undelivered row asserts on.
  run_cli scripts/wave-close.sh
  [ "$CLI_EXIT" = "0" ] || fail "close: exit $CLI_EXIT, stderr: $CLI_STDERR"
  GOT_DELIVERY="$(jq -r '.delivery // empty' "$WV_PROJECT/.wave/state.json")"
}

row() {
  local label="$1" want="$2" filter="$3" benclose="${4:-}"
  setup
  jq "$filter" "$WV_PROJECT/.wave/state.json" > "$WV_PROJECT/.wave/state.tmp" \
    && mv "$WV_PROJECT/.wave/state.tmp" "$WV_PROJECT/.wave/state.json"
  if [ -n "$benclose" ]; then
    printf '%s' "$benclose" > "$WV_PROJECT/.wave/ben-close.md"
  else
    rm -f "$WV_PROJECT/.wave/ben-close.md"
  fi
  close_and_read
  [ "$GOT_DELIVERY" = "$want" ] || fail "$label: delivery is '$GOT_DELIVERY', want '$want'"
}

# 5.4 table
row "BEN not done, bc false" not-applicable \
  '.behaviour_change = false | .phases = {}'
row "BEN not done, bc absent" not-applicable \
  'del(.behaviour_change) | .phases = {}'
row "BEN not done, bc true" unverified \
  '.behaviour_change = true | .phases = {}'
row "BEN not done, bc unknown" unverified \
  '.behaviour_change = "unknown" | .phases = {}'

setup
jq --argjson ph "$(done_map BEN)" '.behaviour_change = true | .phases = $ph' \
  "$WV_PROJECT/.wave/state.json" > "$WV_PROJECT/.wave/state.tmp" \
  && mv "$WV_PROJECT/.wave/state.tmp" "$WV_PROJECT/.wave/state.json"
printf 'BENEFIT: DELIVERED\n' > "$WV_PROJECT/.wave/ben-close.md"
close_and_read
[ "$GOT_DELIVERY" = "delivered" ] || fail "BEN done + DELIVERED: got '$GOT_DELIVERY'"

setup
jq --argjson ph "$(done_map BEN)" '.behaviour_change = false | .phases = $ph' \
  "$WV_PROJECT/.wave/state.json" > "$WV_PROJECT/.wave/state.tmp" \
  && mv "$WV_PROJECT/.wave/state.tmp" "$WV_PROJECT/.wave/state.json"
printf 'BENEFIT: UNDELIVERED\norphan readers: 0\n' > "$WV_PROJECT/.wave/ben-close.md"
close_and_read
[ "$GOT_DELIVERY" = "undelivered" ] || fail "BEN done + UNDELIVERED: got '$GOT_DELIVERY'"
case "$CLI_STDERR" in
  *'[W-UNDELIVERED]'*) : ;;
  *) fail "undelivered close must print W-UNDELIVERED on stderr, got '$CLI_STDERR'" ;;
esac
case "$CLI_STDERR" in
  *'.wave/ben-close.md'*) : ;;
  *) fail "the undelivered message must name .wave/ben-close.md, got '$CLI_STDERR'" ;;
esac

setup
jq --argjson ph "$(done_map BEN)" '.behaviour_change = true | .phases = $ph' \
  "$WV_PROJECT/.wave/state.json" > "$WV_PROJECT/.wave/state.tmp" \
  && mv "$WV_PROJECT/.wave/state.tmp" "$WV_PROJECT/.wave/state.json"
rm -f "$WV_PROJECT/.wave/ben-close.md"
close_and_read
[ "$GOT_DELIVERY" = "unverified" ] || fail "BEN done + absent ben-close.md: got '$GOT_DELIVERY' (absent must not read as delivered)"

setup
jq --argjson ph "$(done_map BEN)" '.behaviour_change = true | .phases = $ph' \
  "$WV_PROJECT/.wave/state.json" > "$WV_PROJECT/.wave/state.tmp" \
  && mv "$WV_PROJECT/.wave/state.tmp" "$WV_PROJECT/.wave/state.json"
printf 'prologue\nnot a verdict\n' > "$WV_PROJECT/.wave/ben-close.md"
close_and_read
[ "$GOT_DELIVERY" = "unverified" ] || fail "BEN done + no matching line: got '$GOT_DELIVERY'"

# Verdict on line 5 is still read.
setup
jq --argjson ph "$(done_map BEN)" '.behaviour_change = true | .phases = $ph' \
  "$WV_PROJECT/.wave/state.json" > "$WV_PROJECT/.wave/state.tmp" \
  && mv "$WV_PROJECT/.wave/state.tmp" "$WV_PROJECT/.wave/state.json"
printf 'line1\nline2\nline3\nline4\nBENEFIT: DELIVERED\nreasons follow\n' \
  > "$WV_PROJECT/.wave/ben-close.md"
close_and_read
[ "$GOT_DELIVERY" = "delivered" ] || fail "verdict on line 5: got '$GOT_DELIVERY', want delivered"

# Both verdict lines: the FIRST wins.
setup
jq --argjson ph "$(done_map BEN)" '.behaviour_change = true | .phases = $ph' \
  "$WV_PROJECT/.wave/state.json" > "$WV_PROJECT/.wave/state.tmp" \
  && mv "$WV_PROJECT/.wave/state.tmp" "$WV_PROJECT/.wave/state.json"
printf 'BENEFIT: UNDELIVERED\nthen later\nBENEFIT: DELIVERED\n' \
  > "$WV_PROJECT/.wave/ben-close.md"
close_and_read
[ "$GOT_DELIVERY" = "undelivered" ] || fail "first of two verdict lines: got '$GOT_DELIVERY', want undelivered"

# Bare close on incomplete behaviour-changing wave records unverified
# (also pinned by init-363; kept here so the table file is complete).
setup
jq '.behaviour_change = true | .phases = {}' \
  "$WV_PROJECT/.wave/state.json" > "$WV_PROJECT/.wave/state.tmp" \
  && mv "$WV_PROJECT/.wave/state.tmp" "$WV_PROJECT/.wave/state.json"
close_and_read
[ "$GOT_DELIVERY" = "unverified" ] || fail "incomplete bc=true: got '$GOT_DELIVERY', want unverified"
# The unverified message names the scorecard path and the file that would
# have carried the verdict (an operator on the Stop path has nothing else).
uv_line="$(printf '%s\n' "$CLI_STDERR" | command grep -m1 -F '[W-UNDELIVERED]')"
case "$uv_line" in
  *'scripts/wave-scorecard.sh'*'.wave/scorecard.md'*) : ;;
  *) fail "the unverified message must name scripts/wave-scorecard.sh and .wave/scorecard.md, got '$uv_line'" ;;
esac
case "$uv_line" in
  *'.wave/ben-close.md'*) : ;;
  *) fail "the unverified message must name .wave/ben-close.md, got '$uv_line'" ;;
esac

# Mode: the BEN row (hooks/phases.tsv) runs in full only. In a mode where it
# does not run, the benefit contract cannot apply, so the verdict is
# not-applicable WHATEVER behaviour_change says, and no W-UNDELIVERED is
# printed: its remedy ("run the BEN-CLOSE phase") would name a phase that
# mode does not have. Solo runs no phases at all, and wave-init writes
# behaviour_change "unknown" for it by default.
mode_row() {
  local label="$1" bc="$2"
  shift 2
  WV_PROJECT="$(mkproj)"
  : > "$WV_PROJECT/README.md"
  git -C "$WV_PROJECT" add README.md
  git -C "$WV_PROJECT" commit -q -m init
  run_cli scripts/wave-init.sh --wave 1 "$@" --feature x --force
  [ "$CLI_EXIT" = "0" ] || fail "$label init: exit $CLI_EXIT, stderr: $CLI_STDERR"
  if [ -n "$bc" ]; then
    jq --arg bc "$bc" '.behaviour_change = (if $bc == "true" then true elif $bc == "false" then false else $bc end)' \
      "$WV_PROJECT/.wave/state.json" > "$WV_PROJECT/.wave/state.tmp" \
      && mv "$WV_PROJECT/.wave/state.tmp" "$WV_PROJECT/.wave/state.json"
  fi
  close_and_read
  [ "$GOT_DELIVERY" = "not-applicable" ] || fail "$label: delivery is '$GOT_DELIVERY', want 'not-applicable' (BEN does not run in this mode)"
  case "$CLI_STDERR" in
    *'W-UNDELIVERED'*) fail "$label: must not print W-UNDELIVERED, got '$CLI_STDERR'" ;;
  esac
}
mode_row "demo, bc true" true --mode demo
mode_row "demo, bc unknown" unknown --mode demo
mode_row "solo, wave-init default" "" --solo
mode_row "solo, bc true" true --solo

# Same rule on the conditional close the hooks use: a COMPLETE demo wave with
# behaviour_change true closes not-applicable through --if-complete.
WV_PROJECT="$(mkproj)"
seed_state state/demo-teet-done.json
jq '.behaviour_change = true' "$WV_PROJECT/.wave/state.json" > "$WV_PROJECT/.wave/state.tmp" \
  && mv "$WV_PROJECT/.wave/state.tmp" "$WV_PROJECT/.wave/state.json"
run_cli scripts/wave-close.sh --if-complete
[ "$CLI_EXIT" = "0" ] || fail "demo --if-complete: exit $CLI_EXIT, stderr: $CLI_STDERR"
GOT_DELIVERY="$(jq -r '.status + "/" + (.delivery // "ABSENT")' "$WV_PROJECT/.wave/state.json")"
[ "$GOT_DELIVERY" = "closed/not-applicable" ] || fail "demo --if-complete, bc true: got '$GOT_DELIVERY', want closed/not-applicable"
case "$CLI_STDERR" in
  *'W-UNDELIVERED'*) fail "demo --if-complete, bc true: must not print W-UNDELIVERED, got '$CLI_STDERR'" ;;
esac

exit $rc
