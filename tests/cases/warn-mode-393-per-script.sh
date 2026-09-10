#!/usr/bin/env bash
# tests/cases/warn-mode-393-per-script.sh — AC-393, AC-394, AC-395, AC-396,
# AC-397: `enforce:"warn"` is the escape hatch, and it leaves a record.
#
# For one deny rule of EVERY script that can deny — pre-agent, pre-edit, pre-read,
# pre-bash, pre-commit-guard — and for subagent-stop's block, the SAME input is
# run twice against the SAME state, differing only in `enforce`:
#
#   enforce:"block"   the rule denies / blocks             (AC-397, the inverse
#                                                           control that stops the
#                                                           warn half being
#                                                           vacuous)
#   enforce:"warn"    exit 0, no permissionDecision and no decision:"block", the
#                     SAME rule id on the warn channel, and the action allowed
#                     (AC-393, AC-394, AC-396)
#
# RUNNING BOTH HALVES IS THE POINT. A warn-mode sweep on its own passes just as
# well against a plugin that denies nothing at all, which is the failure mode an
# escape hatch is most likely to hide: nobody notices that enforcement stopped.
# So every rule below is proved to deny under block mode FIRST, and only then
# proved to warn.
#
# THE WARN CHANNEL IS NOT THE SAME ON EVERY EVENT, and the difference is measured
# rather than assumed. PreToolUse carries `hookSpecificOutput.additionalContext`.
# SubagentStop has no such field at all, so its warn channel is
# `state.phases[<phase>].warned` plus `warn:[…]` on the ledger line — and the
# ledger line must stay SINGLE and keep its shape: lib.sh's wv_block has a warn
# path that appends a second, differently-shaped `{event:"warn", …}` line, which
# would break the one-line-per-agent dedupe key the scorecard and the budget gate
# both read. The `done` phase status matters too: warn mode ALLOWS the hand-off,
# so a phase recorded artifact-missing would stall the wave on a rule that was
# never going to block it.
#
# `set -u`, never `set -e`: every script's pair is measured even if one fails.
set -u

# shellcheck source=tests/lib/assert.sh
source "$(dirname "$0")/../lib/assert.sh"
# shellcheck source=tests/lib/stop.sh
source "$(dirname "$0")/../lib/stop.sh"

name="${WV_CASE_NAME:-$(basename "$0" .sh)}"
log="${WV_CASE_LOG:-$WV_RUN_TMP/logs/$name.log}"
rc=0
fail() { printf 'ASSERT FAIL: %s\n' "$*" >&2; rc=1; }
printf 'RAN multi %s decision=multi\n' "$name" >> "$log"

reason_of() {
  printf '%s' "$WV_LAST_STDOUT" | jq -r \
    '.hookSpecificOutput.permissionDecisionReason // .reason // .hookSpecificOutput.additionalContext // empty'
}

# ---------------------------------------------------------------------------
# The five PreToolUse scripts.
# ---------------------------------------------------------------------------
#
# Each entry names: label, script, rule id, the state fixture, a jq filter over
# the base case (seed files, staged paths, stdin), and a project-relative path
# whose EXISTENCE/CONTENT proves the action was allowed where that is observable.

wv_pre_pair() {
  # wv_pre_pair <label> <script> <rule> <state fixture> <case jq filter> <setup fn>
  local label="$1" script="$2" rule="$3" fixture="$4" filter="$5" setup="$6"
  local mode got

  # RESET PER PAIR. WV_BLOCK_REASON carries the deny text from this pair's block
  # run into its warn run, and leaving the previous pair's value in it meant a warn
  # run whose own block run had failed to set it would compare against ANOTHER
  # rule's text — which either passes by accident or fails with a message naming the
  # wrong pair. Cleared here so the comparison is only ever within one pair.
  WV_BLOCK_REASON=""

  for mode in block warn; do
    WV_PROJECT="$(mkproj)"
    local st="$WV_RUN_TMP/$name-$label-$mode-state.json"
    if ! jq --arg e "$mode" '.enforce = $e' "$WV_TESTS_DIR/fixtures/state/$fixture" > "$st"; then
      fail "$label/$mode: could not build the state"
      return 1
    fi
    local c="$WV_RUN_TMP/$name-$label-$mode.json"
    jq -n --arg st "$st" '{
      script: "x",
      seed: {state: $st},
      stdin: {
        session_id: "1a2b0599-4617-4e73-a9c0-2bef462b2626",
        cwd: ".",
        hook_event_name: "PreToolUse",
        tool_name: "Agent",
        tool_input: {}
      },
      expect: {}
    }' | jq --arg s "$script" '.script = $s' | jq "$filter" > "$c" \
      || { fail "$label/$mode: jq rejected the case filter"; return 1; }

    "$setup"
    run_hook "$script" "$c" || { fail "$label/$mode: run_hook: $WV_LAST_STDERR"; return 1; }

    assert_exit 0 || fail "$label/$mode: every hook exits 0"
    got="$(reason_of)"
    case "$got" in
      "[$rule] "*) : ;;
      *) fail "$label/$mode: want a rendered $rule, got '$got'"; continue ;;
    esac
    local tokens
    tokens="$(printf '%s' "$got" | command grep -oE 'W-[A-Z0-9-]+' | wc -l | tr -d ' ')"
    [ "$tokens" = "1" ] || fail "$label/$mode: the reason carries $tokens W- tokens: '$got'"

    if [ "$mode" = "block" ]; then
      if ! printf '%s' "$WV_LAST_STDOUT" | jq -e \
        '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1; then
        fail "$label/block: want permissionDecision deny, got '$WV_LAST_STDOUT'"
      fi
      WV_BLOCK_REASON="$got"
    else
      if printf '%s' "$WV_LAST_STDOUT" | jq -e \
        '.hookSpecificOutput | has("permissionDecision")' >/dev/null 2>&1; then
        fail "$label/warn: enforce=warn must not deny: '$WV_LAST_STDOUT'"
      fi
      if ! printf '%s' "$WV_LAST_STDOUT" | jq -e \
        '.hookSpecificOutput.additionalContext != null' >/dev/null 2>&1; then
        fail "$label/warn: want additionalContext, got '$WV_LAST_STDOUT'"
      fi
      # The SAME rendered text, not merely the same id: an escape hatch that
      # reworded the reason would leave a record nobody could match to the deny.
      # An EMPTY block reason is a failure of its own — it means the block half
      # never produced a reason to compare against, and silently comparing "" to ""
      # would report this pair as proved.
      [ -n "$WV_BLOCK_REASON" ] || \
        fail "$label/warn: the block half recorded no reason, so there is nothing to compare the warning against"
      [ "$got" = "${WV_BLOCK_REASON:-}" ] || \
        fail "$label/warn: the warn text differs from the deny text.
  block: ${WV_BLOCK_REASON:-}
  warn:  $got"
      local n
      n="$(printf '%s' "$WV_LAST_STDOUT" | jq -s 'length')"
      [ "$n" = "1" ] || fail "$label/warn: $n JSON object(s) on stdout, want 1"
    fi
  done
  printf '  %-18s %-18s block=deny warn=additionalContext, same text\n' "$label" "$rule"
  return 0
}

WV_BLOCK_REASON=""

setup_none() { :; }

# pre-agent.sh / W-TIER: a correctly tagged AC/lead dispatch on sonnet.
wv_pre_pair pre-agent pre-agent.sh W-TIER valid-full.json \
  '.stdin.tool_input = {subagent_type: "general-purpose", model: "sonnet", description: "[W:1 P:AC R:lead] write the criteria"}' \
  setup_none

# pre-edit.sh / W-EDIT: a Write to a git-tracked source file.
setup_edit() {
  mkdir -p "$WV_PROJECT/src"
  printf 'x\n' > "$WV_PROJECT/src/app.ts"
  git -C "$WV_PROJECT" add src/app.ts >/dev/null 2>&1
}
wv_pre_pair pre-edit pre-edit.sh W-EDIT valid-full.json \
  '.stdin.tool_name = "Write" | .stdin.tool_input = {file_path: "src/app.ts", content: "y"}' \
  setup_edit

# pre-read.sh / W-READ: a Read of a project file outside .wave/.
setup_read() {
  mkdir -p "$WV_PROJECT/src"
  printf 'x\n' > "$WV_PROJECT/src/app.ts"
}
wv_pre_pair pre-read pre-read.sh W-READ valid-full.json \
  '.stdin.tool_name = "Read" | .stdin.tool_input = {file_path: "src/app.ts"}' \
  setup_read

# pre-bash.sh / W-BASH: a build/test command from the orchestrator session.
wv_pre_pair pre-bash pre-bash.sh W-BASH valid-full.json \
  '.stdin.tool_name = "Bash" | .stdin.tool_input = {command: "npm test"}' \
  setup_none

# pre-commit-guard.sh / W-COMMIT-DOC: a staged planning document.
setup_commit() {
  mkdir -p "$WV_PROJECT/docs"
  printf 'analysis\n' > "$WV_PROJECT/docs/plan-a.md"
  git -C "$WV_PROJECT" add docs/plan-a.md >/dev/null 2>&1
}
wv_pre_pair pre-commit-guard pre-commit-guard.sh W-COMMIT-DOC full-fresh.json \
  '.stdin.tool_name = "Bash" | .stdin.tool_input = {command: "git commit -m \"wip\""}' \
  setup_commit

# ---------------------------------------------------------------------------
# subagent-stop.sh: the block, and the warn channel that has no stdout.
# ---------------------------------------------------------------------------
#
# AC-395's own fixture: the closing role of AC stops with .wave/ac.md absent, so
# the artifact check fails and W-ARTIFACT is the verdict.

wv_stop_pair() {
  local mode got ledger
  for mode in block warn; do
    WV_PROJECT="$(mkproj)"
    local st="$WV_RUN_TMP/$name-stop-$mode-state.json"
    local c="$WV_RUN_TMP/$name-stop-$mode.json"
    stop_state "$st" ".enforce = \"$mode\" | .active = {a1: $(stop_active AC reviewer opus)}" \
      || { fail "stop/$mode: could not build the state"; return 1; }
    # No .wave/ac.md is seeded: the artifact is the thing that is missing.
    stop_case "$c" "$(printf '.seed.state = "%s" | .seed.transcripts = {".wave/tr/a1.jsonl": "transcripts/all-opus.jsonl"} | .stdin.agent_transcript_path = ".wave/tr/a1.jsonl"' "$st")" \
      || { fail "stop/$mode: could not build the case"; return 1; }
    run_hook subagent-stop.sh "$c" || { fail "stop/$mode: run_hook: $WV_LAST_STDERR"; return 1; }

    assert_exit 0 || fail "stop/$mode: SubagentStop always exits 0"
    ledger="$WV_PROJECT/.wave/ledger.jsonl"

    if [ "$mode" = "block" ]; then
      if ! printf '%s' "$WV_LAST_STDOUT" | jq -e '.decision == "block"' >/dev/null 2>&1; then
        fail "stop/block: want decision block, got '$WV_LAST_STDOUT'"
        continue
      fi
      got="$(reason_of)"
      case "$got" in
        '[W-ARTIFACT] '*) WV_BLOCK_REASON="$got" ;;
        *) fail "stop/block: want a rendered W-ARTIFACT, got '$got'" ;;
      esac
      # The inverse control's other half: under block the phase is NOT done.
      [ "$(stop_phase_status AC)" != "done" ] || \
        fail "stop/block: a blocked hand-off must not record the phase done"
    else
      if printf '%s' "$WV_LAST_STDOUT" | jq -e '.decision' >/dev/null 2>&1; then
        fail "stop/warn: enforce=warn must not block: '$WV_LAST_STDOUT'"
      fi
      # Warn mode ALLOWS the hand-off, so the phase is settled done and carries
      # the record of what was allowed (AC-395).
      [ "$(stop_phase_status AC)" = "done" ] || \
        fail "stop/warn: the phase must be recorded done, got '$(stop_phase_status AC)'"
      jq -e '(.phases.AC.warned // []) | length == 1 and (.[0] | startswith("[W-ARTIFACT] "))' \
        "$WV_PROJECT/.wave/state.json" >/dev/null 2>&1 || \
        fail "stop/warn: state.phases.AC.warned must hold exactly the rendered W-ARTIFACT, got $(jq -c '.phases.AC' "$WV_PROJECT/.wave/state.json")"

      # ONE ledger line, in the closed key set plus `warn` — never a second
      # `{event:"warn"}` line from lib.sh's wv_block warn path.
      local lines
      lines="$(wc -l < "$ledger" 2>/dev/null | tr -d ' ')"
      [ "$lines" = "1" ] || \
        fail "stop/warn: the ledger holds $lines line(s), want exactly 1: $(cat "$ledger" 2>/dev/null)"
      jq -se 'length == 1
              and (.[0] | has("event") | not)
              and (.[0].agent == "a1") and (.[0].phase == "AC") and (.[0].role == "reviewer")
              and ((.[0].warn // []) | length == 1)
              and ((.[0].warn[0]) | startswith("[W-ARTIFACT] "))' \
        "$ledger" >/dev/null 2>&1 || \
        fail "stop/warn: the one ledger line must keep this script's own shape and carry warn:[…], got $(cat "$ledger" 2>/dev/null)"

      got="$(jq -sr '.[0].warn[0]' "$ledger" 2>/dev/null)"
      [ "$got" = "${WV_BLOCK_REASON:-}" ] || \
        fail "stop/warn: the recorded warning differs from the block text.
  block: ${WV_BLOCK_REASON:-}
  warn:  $got"
    fi
  done
  printf '  %-18s %-18s block=block/not-done warn=phase done + warned + one ledger line\n' \
    subagent-stop W-ARTIFACT
  return 0
}

wv_stop_pair

exit $rc
