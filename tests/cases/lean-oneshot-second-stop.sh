#!/usr/bin/env bash
# tests/cases/lean-oneshot-second-stop.sh — fix round 1, item 2.
#
# The lean-return block is a ONE-SHOT keyed on `active[<id>].long_return`, not on
# `stop_hook_active`. Two sequences, each with the flag FALSE on both stops
# (which is what the measured three-stop log shows really happens):
#
#   2,001 then 1,999 -> one block, and the SECOND stop writes the ledger line
#                       the first one deferred, carrying long_return:true.
#   2,001 then 2,001 -> one block, same outcome.
#
# Before the fix the second stop was blocked again ("has 1999") and, because the
# block defers the ledger line, the line was never written at all: the agent's
# whole spend vanished from the ledger.
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

rep() { # rep <char> <n>
  local c="$1" n="$2" out=""
  while [ "${#out}" -lt "$n" ]; do out="$out$c$c$c$c$c$c$c$c$c$c"; done
  printf '%s' "${out:0:$n}"
}
LONG="$(rep L 2001)"
SHORT="$(rep S 1999)"

sequence() {
  # sequence <label> <first message> <second message>
  local label="$1" first="$2" second="$3" blocks=0
  WV_PROJECT="$(mkproj)"
  local st="$WV_RUN_TMP/$name-$label-state.json"
  stop_state "$st" ".active = {a1: $(stop_active AC reviewer opus)}" || return 1

  local c1="$WV_RUN_TMP/$name-$label-1.json" c2="$WV_RUN_TMP/$name-$label-2.json"
  stop_case "$c1" "$(printf '.seed.state = "%s" | .seed.files = {".wave/ac.md": "AC-1 records the spend\\n"} | .stdin.last_assistant_message = "%s"' "$st" "$first")" || return 1
  run_hook subagent-stop.sh "$c1" || { fail "$label stop 1: $WV_LAST_STDERR"; return 1; }
  assert_block W-LONG-RETURN || fail "$label stop 1: want block(W-LONG-RETURN)"
  case "$WV_LAST_STDOUT" in *'"decision":"block"'*) blocks=$((blocks + 1)) ;; esac
  [ "$(stop_ledger_count)" = "0" ] || \
    fail "$label stop 1: the ledger line is deferred, so the ledger must be empty, got $(stop_ledger_count)"

  stop_case "$c2" "$(printf '.stdin.last_assistant_message = "%s"' "$second")" || return 1
  run_hook subagent-stop.sh "$c2" || { fail "$label stop 2: $WV_LAST_STDERR"; return 1; }
  case "$WV_LAST_STDOUT" in *'"decision":"block"'*) blocks=$((blocks + 1)) ;; esac
  [ -z "$WV_LAST_STDOUT" ] || \
    fail "$label stop 2: stdout must be empty — the block is a one-shot, got '$WV_LAST_STDOUT'"
  [ "$blocks" = "1" ] || fail "$label: $blocks block(s) across the two stops, want 1"
  [ "$(stop_ledger_count)" = "1" ] || \
    fail "$label stop 2: the deferred ledger line must be written now, got $(stop_ledger_count) line(s)"
  jq -e '.long_return == true and .agent == "a1"' < "$WV_PROJECT/.wave/ledger.jsonl" >/dev/null 2>&1 || \
    fail "$label stop 2: the ledger line must carry long_return:true, got $(cat "$WV_PROJECT/.wave/ledger.jsonl")"
  return 0
}

sequence longthenshort "$LONG" "$SHORT"
sequence longthenlong  "$LONG" "$LONG"

exit $rc
