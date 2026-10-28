#!/usr/bin/env bash
# undelivered-failed-close.sh — a close that did not happen must not be
# reported as one.
#
# The closing SubagentStop hands the close to scripts/wave-close.sh
# --if-complete. When that closer fails (a lock race, an unwritable .wave/,
# a missing script), the hook must read state.json back, see the wave is
# still active, and then: print a W-STATE that says the wave is complete
# but could not be closed and names `scripts/wave-close.sh` as the remedy;
# print NO W-SCORECARD, NO W-UNDELIVERED and NO W-LEFTOVER (the pointer and
# the verdict belong to a closed wave); write NO once-per-wave marker — not
# even `.leftover-warned` when the inventory found leftovers (a call
# that attempts the close defers that marker until the close is confirmed).
#
# The Stop hook never closes a wave. On a complete wave that is not
# closed it prints W-STATE (complete but not closed; remedy
# scripts/wave-close.sh) and NO verdict, NO pointer, NO marker — every time,
# since nothing silenced it. The closing SubagentStop keeps retrying the
# close; once a retry closes the wave, THAT call prints the verdict and the
# pointer and writes the markers.
#
# Sequence, asserted after EVERY call (state.json + all three markers; the
# final no-op Stop must leave state.json byte-identical):
#   SubagentStop (closer fails) -> Stop -> SubagentStop (closer fails) ->
#   Stop -> SubagentStop (closer works) -> Stop (silent: closed).
# Run twice: a clean inventory, and one with leftovers (lo-shell / lo-cron).
# A third project proves the bare-close remedy the W-STATE names.
#
# The closer is made to fail by running the hook from a COPY of the plugin
# tree whose wave-close.sh is a stub that writes to stderr and exits 1 —
# never by editing the working tree.
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

tokens() { printf '%s' "$1" | command grep -oE 'W-[A-Z0-9-]+' | tr '\n' ' ' | sed -E 's/ +$//'; }
markers() {
  local d="$WV_PROJECT/.wave" out="" m f
  for m in L:.leftover-warned U:.undelivered-warned S:.scorecard-printed; do
    f="${m#*:}"
    if [ -e "$d/$f" ]; then out="$out${m%%:*}+ "; else out="$out${m%%:*}- "; fi
  done
  printf '%s' "${out% }"
}
want_markers() {
  local got
  got="$(markers)"
  [ "$got" = "$2" ] || fail "$1: want markers [$2], got [$got]"
}
want_tokens() {
  local got
  got="$(tokens "$3")"
  [ "$got" = "$2" ] || fail "$1: want rule ids [$2] in this order, got [$got] in '$3'"
}

# A copy of the plugin with a closer that fails.
tree="$WV_RUN_TMP/$name-tree"
rm -rf "$tree"
mkdir -p "$tree"
cp -a "$WV_REPO_ROOT/scripts" "$WV_REPO_ROOT/hooks" "$tree/" || { fail "could not copy the plugin tree"; exit 1; }
cat > "$tree/scripts/wave-close.sh" <<'STUB'
#!/usr/bin/env bash
printf 'wave-close.sh: could not write .wave/state.json\n' >&2
exit 1
STUB

real_root="$WV_REPO_ROOT"
st="$WV_RUN_TMP/$name-state.json"
c="$WV_RUN_TMP/$name.json"
again_c="$WV_RUN_TMP/$name-again.json"
stop_c="$WV_RUN_TMP/$name-stop.json"
stop_state "$st" ".behaviour_change = true | .active = {a1: $(stop_active CL executor sonnet)} | .phases = $(done_except CL)" || exit 1

sa_failing() {
  # sa_failing <step> <case> — the closing SubagentStop with the failing closer.
  WV_REPO_ROOT="$tree"
  run_hook subagent-stop.sh "$2" || fail "$1: run_hook (failing closer): $WV_LAST_STDERR"
  WV_REPO_ROOT="$real_root"
  [ -z "$WV_LAST_STDOUT" ] || fail "$1: stdout must stay empty, got '$WV_LAST_STDOUT'"
  assert_state '.status == "active" and (has("delivery") | not)' || fail "$1: the stub must have left the wave active with no delivery"
  assert_state '.phases.CL.status == "done"' || fail "$1: the closing phase itself must still be recorded done"
  want_tokens "$1" "W-STATE" "$WV_LAST_STDERR"
  assert_stderr_contains 'could not be closed' || fail "$1: W-STATE must say the close failed"
  assert_stderr_contains 'scripts/wave-close.sh' || fail "$1: W-STATE must name scripts/wave-close.sh"
  want_markers "$1" "L- U- S-"
}
stop_unclosed() {
  # stop_unclosed <step> — a Stop on the complete, unclosed wave.
  run_hook stop.sh "$stop_c" || fail "$1: Stop: $WV_LAST_STDERR"
  assert_warn W-STATE || fail "$1: Stop on a complete, unclosed wave must print W-STATE"
  want_tokens "$1" "W-STATE" "$(_wv_reason_text)"
  assert_reason_contains 'not closed' || fail "$1: W-STATE must say the wave is not closed"
  assert_reason_contains 'scripts/wave-close.sh' || fail "$1: W-STATE must name scripts/wave-close.sh"
  assert_state '.status == "active" and (has("delivery") | not)' || fail "$1: Stop must never close the wave"
  want_markers "$1" "L- U- S-"
}

for inv in clean leftover; do
  WV_PROJECT="$(mkproj)"
  extra=""
  stop_bg='[]'
  stop_cron='[]'
  if [ "$inv" = leftover ]; then
    extra='| .stdin.background_tasks += [{id:"lo-shell",type:"shell",status:"running"}] | .stdin.session_crons = [{id:"lo-cron"}]'
    stop_bg='[{"id":"lo-shell","type":"shell","status":"running"}]'
    stop_cron='[{"id":"lo-cron"}]'
  fi
  stop_case "$c" "$(printf '.seed.state = "%s" | .seed.files = {".wave/ben-close.md": "BENEFIT: UNDELIVERED\\norphan readers: 0\\n", ".wave/ledger.jsonl": "{\\"agent\\":\\"a0\\",\\"phase\\":\\"CCP\\",\\"role\\":\\"executor\\",\\"output\\":1}\\n"} %s' "$st" "$extra") | .seed.files += $(stop_findings_zero)" || exit 1
  # The retries re-deliver the same stop WITHOUT re-seeding the project.
  jq 'del(.seed)' "$c" > "$again_c" || exit 1
  jq -n --argjson bg "$stop_bg" --argjson cr "$stop_cron" '{script:"stop.sh", stdin:{hook_event_name:"Stop", background_tasks:$bg, session_crons:$cr}}' > "$stop_c" || exit 1

  sa_failing "$inv/1 SubagentStop, closer fails" "$c"
  if [ "$inv" = leftover ]; then
    ls "$WV_PROJECT/.wave/checkpoints/"*.md >/dev/null 2>&1 || fail "$inv/1: the leftover inventory checkpoint must still be written"
  fi
  stop_unclosed "$inv/2 Stop after the first failed close"
  sa_failing "$inv/3 SubagentStop, closer fails again" "$again_c"
  stop_unclosed "$inv/4 Stop after the second failed close"

  # The retry that works (real tree): THIS call closes, prints the verdict
  # with its same-call pointer, and writes the markers.
  run_hook subagent-stop.sh "$again_c" || fail "$inv/5: run_hook (real closer): $WV_LAST_STDERR"
  [ -z "$WV_LAST_STDOUT" ] || fail "$inv/5: stdout must stay empty, got '$WV_LAST_STDOUT'"
  assert_state '.status == "closed" and .delivery == "undelivered"' || fail "$inv/5: the successful retry must close the wave undelivered"
  if [ "$inv" = leftover ]; then
    want_tokens "$inv/5 SubagentStop, closer works" "W-LEFTOVER W-UNDELIVERED" "$WV_LAST_STDERR"
    want_markers "$inv/5 SubagentStop, closer works" "L+ U+ S+"
  else
    want_tokens "$inv/5 SubagentStop, closer works" "W-UNDELIVERED W-SCORECARD" "$WV_LAST_STDERR"
    want_markers "$inv/5 SubagentStop, closer works" "L- U+ S+"
  fi

  # Closed: the next Stop is silent, changes no marker and leaves state.json
  # byte-identical (a silent Stop that rewrote the closed state would
  # otherwise pass on markers alone).
  before="$(markers)"
  st_before="$WV_RUN_TMP/$name-$inv-state-before-6.json"
  cp "$WV_PROJECT/.wave/state.json" "$st_before" || fail "$inv/6: could not snapshot state.json"
  run_hook stop.sh "$stop_c" || fail "$inv/6: Stop after the close: $WV_LAST_STDERR"
  assert_silent || fail "$inv/6: Stop on the closed wave must be silent, got '$WV_LAST_STDOUT'"
  cmp -s "$st_before" "$WV_PROJECT/.wave/state.json" || fail "$inv/6: Stop on the closed wave must leave state.json byte-identical"
  assert_state '.status == "closed" and .delivery == "undelivered"' || fail "$inv/6: Stop on the closed wave must keep it closed undelivered"
  want_markers "$inv/6 Stop after the close" "$before"
done

# The remedy the W-STATE names: a bare wave-close.sh closes the wave and
# records the honest verdict.
WV_PROJECT="$(mkproj)"
stop_case "$c" "$(printf '.seed.state = "%s" | .seed.files = {".wave/ben-close.md": "BENEFIT: UNDELIVERED\\norphan readers: 0\\n"}' "$st") | .seed.files += $(stop_findings_zero)" || exit 1
WV_REPO_ROOT="$tree"
run_hook subagent-stop.sh "$c" || fail "remedy: run_hook (failing closer): $WV_LAST_STDERR"
WV_REPO_ROOT="$real_root"
assert_state '.status == "active"' || fail "remedy: the failing closer must leave the wave active"
run_cli scripts/wave-close.sh
[ "$CLI_EXIT" = "0" ] || fail "remedy close: exit $CLI_EXIT, stderr: $CLI_STDERR"
assert_state '.status == "closed" and .delivery == "undelivered"' || fail "remedy close must record the verdict"

exit $rc
