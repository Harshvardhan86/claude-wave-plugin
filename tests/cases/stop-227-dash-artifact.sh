#!/usr/bin/env bash
# tests/cases/stop-227-dash-artifact.sh — AC-227: a row whose `artifact` cell is
# `-` has NO artifact check. VB, COMMIT, CL and AD are marked done on the closing
# role's stop with one ledger line and nothing read from disk, which is what
# makes the check table-driven rather than a list of phase codes in the script.
#
# AD is anytime, not a close trigger: an AD stop with nothing else done leaves
# the wave ACTIVE, and later hooks still enforce (a denied dispatch proves it).
# The wave closes when the LAST of VB, COMMIT, CL, CCP is recorded done, in any
# order, and not before.
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

ALWAYS="AC ACB TDE-RED TDE-GREEN BC SEA DS BSEA OA TEET-TC TEET BTEET BTEET-X VB COMMIT CL CCP"

done_map() {
  local skip=" $1 "
  local c
  {
    for c in $ALWAYS; do
      case "$skip" in *" $c "*) continue ;; esac
      printf '%s\n' "$c"
    done
  } | jq -R . | jq -s 'map(select(length>0) | {(.): {status:"done", at:"2026-09-09T12:10:00Z", agent:"a0"}}) | add'
}

drive() {
  # drive <phase> <model> <expected wave status afterwards>
  WV_PROJECT=""
  local phase="$1" model="$2" want_wave="$3"
  local st="$WV_RUN_TMP/$name-$phase-state.json" c="$WV_RUN_TMP/$name-$phase.json"
  stop_state "$st" ".active = {a1: $(stop_active "$phase" executor "$model")}" || return 1
  stop_case "$c" "$(printf '.seed.state = "%s"' "$st")" || return 1
  run_hook subagent-stop.sh "$c" || { fail "$phase: run_hook: $WV_LAST_STDERR"; return 1; }
  assert_allow || fail "$phase: want no block"
  [ -z "$WV_LAST_STDOUT" ] || fail "$phase: stdout must be empty, got '$WV_LAST_STDOUT'"
  [ "$(stop_phase_status "$phase")" = "done" ] || \
    fail "$phase: status is '$(stop_phase_status "$phase")', want done"
  [ "$(stop_ledger_count)" = "1" ] || fail "$phase: ledger has $(stop_ledger_count) line(s), want 1"
  local got_wave
  got_wave="$(jq -r '.status' "$WV_PROJECT/.wave/state.json")"
  [ "$got_wave" = "$want_wave" ] || \
    fail "$phase: wave status is '$got_wave', want $want_wave"
  return 0
}

# VB, COMMIT and CL completing in isolation must leave the wave ACTIVE. That
# is the negative control that stops the close from degenerating into "close
# whenever a phase is done".
drive VB haiku active
drive COMMIT sonnet active
drive CL sonnet active

# AD: anytime, artifact `-`. Completing it must NOT close the wave, and hooks
# must still enforce afterwards.
if drive AD haiku active; then
  [ "$(jq -r '.status' "$WV_PROJECT/.wave/state.json")" = "active" ] || \
    fail "AD: wave must stay active"
  [ "$(jq -r '(.ended // "null")' "$WV_PROJECT/.wave/state.json")" = "null" ] || \
    fail "AD: .ended must stay null; an AD stop must not close the wave"

  # Drive one denied dispatch against the same project to prove hooks did not
  # go silent (the released defect: the first AD stop closed the wave and
  # every later hook returned without judging).
  gate="$WV_RUN_TMP/$name-commit-deny.json"
  jq -n '{
    script: "pre-agent.sh",
    stdin: {
      session_id: "1a2b0599-4617-4e73-a9c0-2bef462b2626",
      transcript_path: "/tmp/wave-plugin-tests/transcript.jsonl",
      cwd: ".",
      prompt_id: "c1f033ea-e4ee-4474-88ec-3913700ae39d",
      permission_mode: "bypassPermissions",
      hook_event_name: "PreToolUse",
      tool_name: "Agent",
      tool_use_id: "toolu_01RXAwe6jcU5LBKHd9geD6sE",
      tool_input: {
        description: "[W:1 P:COMMIT R:executor] bump the version",
        prompt: "Do the thing.",
        subagent_type: "general-purpose",
        model: "sonnet"
      }
    }
  }' > "$gate" || exit 1
  run_hook pre-agent.sh "$gate" || fail "post-AD dispatch: run_hook: $WV_LAST_STDERR"
  assert_deny W-ORDER || fail "post-AD dispatch: want W-ORDER, hooks must still enforce"
fi

# The wave closes when the LAST of VB, COMMIT, CL, CCP is recorded done, in
# any order, and not before. Other when=phase rows of full mode are already
# done or skipped (flags false; every scan's findings file reads FINDINGS: 0,
# since a done scan with no findings file is the gate's W-ARTIFACT case and
# does not settle its BF- row).
drive_tail() {
  local order="$1"
  WV_PROJECT=""
  local model st c phase got i n
  local -a seq=()
  read -ra seq <<<"$order"
  n="${#seq[@]}"
  st="$WV_RUN_TMP/$name-tail-state.json"
  c="$WV_RUN_TMP/$name-tail.json"
  i=0

  for phase in "${seq[@]}"; do
    i=$((i + 1))
    case "$phase" in
      VB) model=haiku ;;
      *) model=sonnet ;;
    esac
    if [ -z "${WV_PROJECT:-}" ]; then
      stop_state "$st" ".active = {a1: $(stop_active "$phase" executor "$model")} | .phases = $(done_map "$order")" || return 1
    else
      jq --argjson act "$(stop_active "$phase" executor "$model")" \
        '.active = {a1: $act}' "$WV_PROJECT/.wave/state.json" > "$st" || return 1
    fi
    # CCP's artifact is a glob; plant one file so a CCP stop can reach done.
    stop_case "$c" "$(printf '.seed.state = "%s" | .seed.files = {".wave/checkpoints/1-ccp.md": "ccp\\n"}' "$st") | .seed.files += $(stop_findings_zero)" || return 1
    run_hook subagent-stop.sh "$c" || { fail "tail $order / $phase: run_hook: $WV_LAST_STDERR"; return 1; }
    assert_allow || fail "tail $order / $phase: want no block"
    [ -z "$WV_LAST_STDOUT" ] || fail "tail $order / $phase: stdout must be empty, got '$WV_LAST_STDOUT'"
    [ "$(stop_phase_status "$phase")" = "done" ] || \
      fail "tail $order / $phase: status is '$(stop_phase_status "$phase")', want done"
    got="$(jq -r '.status' "$WV_PROJECT/.wave/state.json")"
    if [ "$i" -lt "$n" ]; then
      [ "$got" = "active" ] || fail "tail $order after $phase ($i/$n): wave is '$got', want active"
    else
      [ "$got" = "closed" ] || fail "tail $order after last phase $phase: wave is '$got', want closed"
      [ "$(jq -r '(.ended // "null")' "$WV_PROJECT/.wave/state.json")" != "null" ] || \
        fail "tail $order: .ended must be set when the wave closes"
    fi
  done
  return 0
}

# Four permutations so the last of VB/COMMIT/CL/CCP is a different code each
# time; closing must not be pinned to one of them.
drive_tail "VB COMMIT CL CCP"
drive_tail "CCP VB CL COMMIT"
drive_tail "COMMIT CCP VB CL"
drive_tail "CL CCP COMMIT VB"

exit $rc
