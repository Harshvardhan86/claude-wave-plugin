#!/usr/bin/env bash
# tests/cases/stop-168-fanout-rounds.sh — the stop half of AC-168.
#
# `TEET-TC` has `fanout` 3. Three concurrent writers are ONE round: the counter
# moves once, when the last of the group stops, so
# `state.rounds["TEET-TC/writer"] == 1` afterwards. A second group of three takes
# it to 2, which is the point at which pre-agent.sh's round ceiling starts
# denying a third group (AC-161, already covered there) — rounds, not dispatches,
# so the framework's PDT fan-out is never falsely denied.
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

rounds() { jq -r '(.rounds["TEET-TC/writer"] // 0) | tostring' "$WV_PROJECT/.wave/state.json"; }

WV_PROJECT="$(mkproj)"
st="$WV_RUN_TMP/$name-state.json"
stop_state "$st" ".active = {a1: $(stop_active TEET-TC writer sonnet),
                             a2: $(stop_active TEET-TC writer sonnet),
                             a3: $(stop_active TEET-TC writer sonnet)}" || exit 1

group() {
  # group <seed|live> <agent>...
  local mode="$1"; shift
  local first="$mode" a c
  for a in "$@"; do
    c="$WV_RUN_TMP/$name-$a.json"
    if [ "$first" = "seed" ]; then
      stop_case "$c" "$(printf '.seed.state = "%s" | .stdin.agent_id = "%s"' "$st" "$a")" || return 1
      first=live
    else
      stop_case "$c" "$(printf '.stdin.agent_id = "%s"' "$a")" || return 1
    fi
    run_hook subagent-stop.sh "$c" || { fail "$a: run_hook: $WV_LAST_STDERR"; return 1; }
    assert_allow || fail "$a: want no block"
  done
  return 0
}

group seed a1 a2 a3
[ "$(rounds)" = "1" ] || fail "after the first group of three, rounds is $(rounds), want 1"
[ "$(stop_ledger_count)" = "3" ] || fail "three writers, $(stop_ledger_count) ledger line(s), want 3"

# The second group: three fresh agents launched into the live state.
jq ".active = (.active + {a4: $(stop_active TEET-TC writer sonnet),
                          a5: $(stop_active TEET-TC writer sonnet),
                          a6: $(stop_active TEET-TC writer sonnet)})" \
  "$WV_PROJECT/.wave/state.json" > "$WV_RUN_TMP/$name-live.json" && \
  mv "$WV_RUN_TMP/$name-live.json" "$WV_PROJECT/.wave/state.json" || \
  { fail "could not launch the second group"; exit 1; }

group live a4 a5 a6
[ "$(rounds)" = "2" ] || fail "after the second group of three, rounds is $(rounds), want 2"
[ "$(stop_ledger_count)" = "6" ] || fail "six writers, $(stop_ledger_count) ledger line(s), want 6"

exit $rc
