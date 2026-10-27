#!/usr/bin/env bash
# undelivered-close-matrix.sh — the close-time warning composition, cell by
# cell, with every once-per-wave marker asserted after every call (the Stop rows
# never close a wave).
#
# Three facts are kept apart:
#   - leftover warning QUEUED THIS CALL (inventory dirty and .leftover-warned
#     absent before the call),
#   - leftovers EXIST (inventory dirty, whatever the marker says),
#   - warned in a PRIOR call (.leftover-warned already present).
# A newly emitted verdict always has a pointer in the SAME call: W-LEFTOVER
# when it was queued this call, otherwise W-SCORECARD. `.scorecard-printed`
# is written in that same call whichever rule carried the pointer. Order:
# W-LEFTOVER, W-UNDELIVERED, W-SCORECARD.
#
# Matrix: {fresh, prior-warned} x {clean, leftover inventory} x
#   SubagentStop that closes the wave (verdict undelivered; stderr channel),
#   Stop on a complete full-mode wave that is NOT closed (W-STATE only,
#     no verdict, no pointer, no marker — this hook never closes a wave),
#   Stop in solo mode (no close exists there; the verdict is not-applicable,
#     so the pointer composition is the whole of it; stdout channel).
# Both hooks go through the same composition function.
set -u
source "$(dirname "$0")/../lib/assert.sh"
name="${WV_CASE_NAME:-$(basename "$0" .sh)}"
log="${WV_CASE_LOG:-$WV_RUN_TMP/logs/$name.log}"
rc=0
fail() { printf 'ASSERT FAIL: %s\n' "$*" >&2; rc=1; }
source "$WV_TESTS_DIR/lib/stop.sh"

ALWAYS="AC ACB TDE-RED TDE-GREEN BC SEA DS BSEA OA TEET-TC TEET BTEET BTEET-X VB COMMIT CL CCP"
done_except() {
  local skip=" $* "
  local c
  {
    for c in $ALWAYS; do
      case "$skip" in *" $c "*) continue ;; esac
      printf '%s\n' "$c"
    done
    printf '%s\n' BEN DR BEN-CLOSE
  } | jq -R . | jq -s 'map(select(length>0) | {(.): {status:"done", at:"2026-09-09T12:10:00Z", agent:"a0"}}) | add'
}

# tokens <text> -> the W- rule ids in <text>, in order, space-separated.
tokens() { printf '%s' "$1" | command grep -oE 'W-[A-Z0-9-]+' | tr '\n' ' ' | sed -E 's/ +$//'; }
# markers -> which of the three once-per-wave markers exist: L=.leftover-warned,
# U=.undelivered-warned, S=.scorecard-printed; "+" present, "-" absent.
markers() {
  local d="$WV_PROJECT/.wave" out="" m f
  for m in L:.leftover-warned U:.undelivered-warned S:.scorecard-printed; do
    f="${m#*:}"
    if [ -e "$d/$f" ]; then out="$out${m%%:*}+ "; else out="$out${m%%:*}- "; fi
  done
  printf '%s' "${out% }"
}
check() {
  # check <cell> <channel stdout|stderr> <want tokens> <want markers>
  local cell="$1" chan="$2" want="$3" wantm="$4" text got gotm
  if [ "$chan" = stdout ]; then text="$(_wv_reason_text)"; else text="$WV_LAST_STDERR"; fi
  got="$(tokens "$text")"
  [ "$got" = "$want" ] || fail "$cell: want rule ids [$want] in this order, got [$got] in '$text'"
  gotm="$(markers)"
  [ "$gotm" = "$wantm" ] || fail "$cell: want markers [$wantm], got [$gotm]"
  case "$want" in
    "") : ;;
    *) case "$text" in "[${want%% *}] "*) : ;; *) fail "$cell: reason must start with [${want%% *}]: '$text'" ;; esac ;;
  esac
}

LEFTOVER_STDIN='.stdin.background_tasks += [{id:"lo-shell",type:"shell",status:"running"}] | .stdin.session_crons = [{id:"lo-cron"}]'

# ---- SubagentStop that closes the wave -------------------------------------
for prior in fresh prior; do
  for inv in clean leftover; do
    cell="SubagentStop/$prior/$inv"
    WV_PROJECT="$(mkproj)"
    st="$WV_RUN_TMP/$name-state.json"
    c="$WV_RUN_TMP/$name.json"
    stop_state "$st" ".behaviour_change = true | .active = {a1: $(stop_active CL executor sonnet)} | .phases = $(done_except CL)" || exit 1
    extra=""
    [ "$inv" = leftover ] && extra="| $LEFTOVER_STDIN"
    seedprior=""
    [ "$prior" = prior ] && seedprior='| .seed.files[".wave/.leftover-warned"] = ""'
    stop_case "$c" "$(printf '.seed.state = "%s" | .seed.files = {".wave/ben-close.md": "BENEFIT: UNDELIVERED\\norphan readers: 0\\n", ".wave/ledger.jsonl": "{\\"agent\\":\\"a0\\",\\"phase\\":\\"CCP\\",\\"role\\":\\"executor\\",\\"output\\":1}\\n"} %s %s' "$st" "$extra" "$seedprior") | .seed.files += $(stop_findings_zero)" || exit 1
    run_hook subagent-stop.sh "$c" || fail "$cell: run_hook: $WV_LAST_STDERR"
    [ -z "$WV_LAST_STDOUT" ] || fail "$cell: stdout must stay empty, got '$WV_LAST_STDOUT'"
    assert_state '.status == "closed" and .delivery == "undelivered"' || fail "$cell: the wave must be closed undelivered"
    case "$prior/$inv" in
      fresh/clean)    check "$cell" stderr "W-UNDELIVERED W-SCORECARD" "L- U+ S+" ;;
      fresh/leftover) check "$cell" stderr "W-LEFTOVER W-UNDELIVERED"  "L+ U+ S+" ;;
      prior/clean)    check "$cell" stderr "W-UNDELIVERED W-SCORECARD" "L+ U+ S+" ;;
      prior/leftover) check "$cell" stderr "W-UNDELIVERED W-SCORECARD" "L+ U+ S+" ;;
    esac
    # Nothing repeats afterwards: a Stop on the closed wave is silent.
    jq -n '{script:"stop.sh", stdin:{hook_event_name:"Stop", background_tasks:[{id:"lo-shell",type:"shell",status:"running"}], session_crons:[]}}' > "$c"
    run_hook stop.sh "$c" || fail "$cell: Stop after close: $WV_LAST_STDERR"
    assert_silent || fail "$cell: a Stop after the close must be silent"
  done
done

# A verdict still owed after the pointer was already given (pointer marker
# from an earlier call, verdict marker absent): the verdict carries its own
# same-call pointer again, never alone.
WV_PROJECT="$(mkproj)"
stop_state "$st" ".behaviour_change = true | .active = {a1: $(stop_active CL executor sonnet)} | .phases = $(done_except CL)" || exit 1
stop_case "$c" "$(printf '.seed.state = "%s" | .seed.files = {".wave/ben-close.md": "BENEFIT: UNDELIVERED\\norphan readers: 0\\n", ".wave/.scorecard-printed": "", ".wave/ledger.jsonl": "{\\"agent\\":\\"a0\\",\\"phase\\":\\"CCP\\",\\"role\\":\\"executor\\",\\"output\\":1}\\n"}' "$st") | .seed.files += $(stop_findings_zero)" || exit 1
run_hook subagent-stop.sh "$c" || fail "pointer-already-printed: run_hook: $WV_LAST_STDERR"
check "SubagentStop/pointer-already-printed" stderr "W-UNDELIVERED W-SCORECARD" "L- U+ S+"

# ---- Stop on a complete full-mode wave that is not closed --------------
for prior in fresh prior; do
  for inv in clean leftover; do
    cell="Stop-full/$prior/$inv"
    WV_PROJECT="$(mkproj)"
    seed_state state/full-all-done.json
    printf '{"agent":"a0","phase":"CCP","role":"executor","output":1}\n' > "$WV_PROJECT/.wave/ledger.jsonl"
    printf 'BENEFIT: UNDELIVERED\norphan readers: 0\n' > "$WV_PROJECT/.wave/ben-close.md"
    wantm="L- U- S-"
    if [ "$prior" = prior ]; then : > "$WV_PROJECT/.wave/.leftover-warned"; wantm="L+ U- S-"; fi
    if [ "$inv" = leftover ]; then
      jq -n '{script:"stop.sh", stdin:{hook_event_name:"Stop", background_tasks:[{id:"lo-shell",type:"shell",status:"running"}], session_crons:[{id:"lo-cron"}]}}' > "$c"
    else
      jq -n '{script:"stop.sh", stdin:{hook_event_name:"Stop", background_tasks:[], session_crons:[]}}' > "$c"
    fi
    run_hook stop.sh "$c" || fail "$cell: run_hook: $WV_LAST_STDERR"
    assert_warn W-STATE || fail "$cell: a complete, unclosed wave must get W-STATE at Stop"
    check "$cell" stdout "W-STATE" "$wantm"
    assert_reason_contains 'scripts/wave-close.sh' || fail "$cell: the W-STATE must name scripts/wave-close.sh"
    assert_reason_contains 'not closed' || fail "$cell: the W-STATE must say the wave is not closed"
    assert_state '.status == "active" and (has("delivery") | not)' || fail "$cell: Stop must never close the wave"
    # The inventory is still refreshed (it is not a marker).
    ls "$WV_PROJECT/.wave/checkpoints/"*.md >/dev/null 2>&1 || fail "$cell: the leftover inventory checkpoint is missing"
    # And a second Stop says the same again: nothing silenced it.
    run_hook stop.sh "$c" || fail "$cell: second Stop: $WV_LAST_STDERR"
    check "$cell/second" stdout "W-STATE" "$wantm"
  done
done

# ---- Stop in solo mode ------------------------------------------------------
for prior in fresh prior; do
  for inv in clean leftover; do
    cell="Stop-solo/$prior/$inv"
    WV_PROJECT="$(mkproj)"
    seed_state state/solo.json
    printf '{"agent":"a0","phase":"AC","role":"lead","output":1}\n' > "$WV_PROJECT/.wave/ledger.jsonl"
    [ "$prior" = prior ] && : > "$WV_PROJECT/.wave/.leftover-warned"
    if [ "$inv" = leftover ]; then
      jq -n '{script:"stop.sh", stdin:{hook_event_name:"Stop", background_tasks:[{id:"lo-shell",type:"shell",status:"running"}], session_crons:[{id:"lo-cron"}]}}' > "$c"
    else
      jq -n '{script:"stop.sh", stdin:{hook_event_name:"Stop", background_tasks:[], session_crons:[]}}' > "$c"
    fi
    run_hook stop.sh "$c" || fail "$cell: run_hook: $WV_LAST_STDERR"
    case "$prior/$inv" in
      fresh/clean)    check "$cell" stdout "W-SCORECARD" "L- U- S+" ;;
      fresh/leftover) check "$cell" stdout "W-LEFTOVER"  "L+ U- S+" ;;
      prior/clean)    check "$cell" stdout "W-SCORECARD" "L+ U- S+" ;;
      prior/leftover) check "$cell" stdout "W-SCORECARD" "L+ U- S+" ;;
    esac
    # Once per wave: the next Stop is silent in every cell.
    run_hook stop.sh "$c" || fail "$cell: second Stop: $WV_LAST_STDERR"
    assert_silent || fail "$cell: second solo Stop must be silent, got '$WV_LAST_STDOUT'"
  done
done

exit $rc
