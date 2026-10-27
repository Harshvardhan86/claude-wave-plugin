#!/usr/bin/env bash
# tests/cases/scorecard-004-delivery.sh — ## Delivery under the title when
# state.json has `delivery`. Undelivered quotes the reason lines after the
# verdict; unverified says the benefit was never checked at close; delivered
# and not-applicable are one line. Present on an empty ledger. Absent when
# the key is unset (every 0.2.x wave).
set -u
source "$(dirname "$0")/../lib/assert.sh"

name="$(basename "$0" .sh)"
log="${WV_CASE_LOG:-$WV_RUN_TMP/logs/$name.log}"
mkdir -p "$(dirname "$log")"
rc=0
fail() { printf 'ASSERT FAIL: %s\n' "$*" >&2; rc=1; }

has_delivery_section() {
  case "$CLI_STDOUT" in
    *$'## Delivery'*) return 0 ;;
    *) return 1 ;;
  esac
}

# Absent key: no section. A ledger line is seeded so the scorecard is actually
# rendered: without one the script takes its "no ledger" early return before
# the Delivery code is reached, and this leg could not fail for any reason
# connected to that code (an unconditional Delivery section survived it). The
# title assertion proves the render happened.
WV_PROJECT="$(mkproj)"
seed_state state/valid-full.json
printf '{"agent":"a1","phase":"AC","role":"lead","output":1}\n' > "$WV_PROJECT/.wave/ledger.jsonl"
run_cli scripts/wave-scorecard.sh
[ "$CLI_EXIT" = "0" ] || fail "unset: exit $CLI_EXIT"
case "$CLI_STDOUT" in
  *'# Wave 1 scorecard'*) : ;;
  *) fail "unset delivery: the scorecard was not rendered (no title), so the absence claim is vacuous: '$CLI_STDOUT'" ;;
esac
has_delivery_section && fail "unset delivery must not print ## Delivery, got '$CLI_STDOUT'"

# Empty ledger + delivery set: title and Delivery, not the "no ledger" bail.
WV_PROJECT="$(mkproj)"
seed_state state/valid-full.json
jq '.delivery = "undelivered"' "$WV_PROJECT/.wave/state.json" > "$WV_PROJECT/.wave/state.tmp" \
  && mv "$WV_PROJECT/.wave/state.tmp" "$WV_PROJECT/.wave/state.json"
printf 'BENEFIT: UNDELIVERED\norphan readers: 0\ndefeat: existing dispatcher ignores the flag\n' \
  > "$WV_PROJECT/.wave/ben-close.md"
run_cli scripts/wave-scorecard.sh
[ "$CLI_EXIT" = "0" ] || fail "empty-ledger undelivered: exit $CLI_EXIT"
case "$CLI_STDOUT" in
  *'# Wave 1 scorecard'*) : ;;
  *) fail "empty-ledger undelivered: missing title, got '$CLI_STDOUT'" ;;
esac
has_delivery_section || fail "empty-ledger undelivered: missing ## Delivery"
case "$CLI_STDOUT" in
  *'no ledger'*) fail "empty-ledger with delivery must not take the no-ledger early return" ;;
esac
case "$CLI_STDOUT" in
  *'orphan readers: 0'*) : ;;
  *) fail "undelivered must quote reason lines after the verdict, got '$CLI_STDOUT'" ;;
esac
case "$CLI_STDOUT" in
  *'defeat: existing dispatcher ignores the flag'*) : ;;
  *) fail "undelivered must quote the second reason line, got '$CLI_STDOUT'" ;;
esac

# Undelivered with one very long reason line: each quoted line is capped at
# 200 characters of reason text (an ellipsis says it was cut), as well as the
# 20-line cap, so one runaway line cannot swamp the document.
WV_PROJECT="$(mkproj)"
seed_state state/valid-full.json
printf '{"agent":"a1","phase":"AC","role":"lead","output":1}\n' > "$WV_PROJECT/.wave/ledger.jsonl"
jq '.delivery = "undelivered"' "$WV_PROJECT/.wave/state.json" > "$WV_PROJECT/.wave/state.tmp" \
  && mv "$WV_PROJECT/.wave/state.tmp" "$WV_PROJECT/.wave/state.json"
long="LONGREASON$(printf 'x%.0s' $(seq 1 600))TAILMARK"
printf 'BENEFIT: UNDELIVERED\n%s\nshort second line\n' "$long" > "$WV_PROJECT/.wave/ben-close.md"
run_cli scripts/wave-scorecard.sh
long_line="$(printf '%s\n' "$CLI_STDOUT" | command grep -m1 'LONGREASON')"
[ -n "$long_line" ] || fail "long reason: the first reason line was not quoted at all: '$CLI_STDOUT'"
long_body="${long_line%…}"
[ "${#long_body}" -le 202 ] || fail "long reason: quoted line is ${#long_body} characters before the ellipsis, want at most 200 of reason text plus the '- ' prefix"
case "$long_line" in
  *TAILMARK*) fail "long reason: the line was not cut (its tail survived)" ;;
esac
case "$long_line" in
  '- LONGREASON'*'…') : ;;
  *) fail "long reason: want '- LONGREASON…' with a trailing ellipsis, got '${long_line:0:60}…${long_line: -10}'" ;;
esac
case "$CLI_STDOUT" in
  *'- short second line'*) : ;;
  *) fail "long reason: the line after the long one must still be quoted" ;;
esac

# Unverified.
WV_PROJECT="$(mkproj)"
seed_state state/valid-full.json
printf '{"agent":"a1","phase":"AC","role":"lead","output":1}\n' > "$WV_PROJECT/.wave/ledger.jsonl"
jq '.delivery = "unverified"' "$WV_PROJECT/.wave/state.json" > "$WV_PROJECT/.wave/state.tmp" \
  && mv "$WV_PROJECT/.wave/state.tmp" "$WV_PROJECT/.wave/state.json"
run_cli scripts/wave-scorecard.sh
has_delivery_section || fail "unverified: missing ## Delivery"
case "$CLI_STDOUT" in
  *'never checked at close'*) : ;;
  *) fail "unverified text missing, got '$CLI_STDOUT'" ;;
esac

# Delivered: one line.
WV_PROJECT="$(mkproj)"
seed_state state/valid-full.json
printf '{"agent":"a1","phase":"AC","role":"lead","output":1}\n' > "$WV_PROJECT/.wave/ledger.jsonl"
jq '.delivery = "delivered"' "$WV_PROJECT/.wave/state.json" > "$WV_PROJECT/.wave/state.tmp" \
  && mv "$WV_PROJECT/.wave/state.tmp" "$WV_PROJECT/.wave/state.json"
run_cli scripts/wave-scorecard.sh
has_delivery_section || fail "delivered: missing ## Delivery"
case "$CLI_STDOUT" in
  *'delivered'*) : ;;
  *) fail "delivered one-liner missing, got '$CLI_STDOUT'" ;;
esac

# not-applicable: one line.
WV_PROJECT="$(mkproj)"
seed_state state/valid-full.json
printf '{"agent":"a1","phase":"AC","role":"lead","output":1}\n' > "$WV_PROJECT/.wave/ledger.jsonl"
jq '.delivery = "not-applicable"' "$WV_PROJECT/.wave/state.json" > "$WV_PROJECT/.wave/state.tmp" \
  && mv "$WV_PROJECT/.wave/state.tmp" "$WV_PROJECT/.wave/state.json"
run_cli scripts/wave-scorecard.sh
has_delivery_section || fail "not-applicable: missing ## Delivery"
case "$CLI_STDOUT" in
  *'not-applicable'*) : ;;
  *) fail "not-applicable one-liner missing, got '$CLI_STDOUT'" ;;
esac

# Delivery sits directly under the title.
WV_PROJECT="$(mkproj)"
seed_state state/valid-full.json
printf '{"agent":"a1","phase":"AC","role":"lead","output":1}\n' > "$WV_PROJECT/.wave/ledger.jsonl"
jq '.delivery = "delivered"' "$WV_PROJECT/.wave/state.json" > "$WV_PROJECT/.wave/state.tmp" \
  && mv "$WV_PROJECT/.wave/state.tmp" "$WV_PROJECT/.wave/state.json"
run_cli scripts/wave-scorecard.sh
title_then_delivery="$(printf '%s' "$CLI_STDOUT" | awk 'NR==1{print} NR==2{print} NR==3{print}')"
case "$title_then_delivery" in
  *'# Wave 1 scorecard'*'## Delivery'*) : ;;
  *) fail "Delivery must sit directly under the title, got first lines: '$title_then_delivery'" ;;
esac

exit $rc
