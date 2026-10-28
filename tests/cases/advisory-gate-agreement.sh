#!/usr/bin/env bash
# tests/cases/advisory-gate-agreement.sh — design 3.2.
#
# For every combination of vocabulary and behaviour_change over
# {true, false, "unknown", absent} (sixteen states, generated here, never
# hand-written as fixtures), drive the real gate (pre-agent.sh, a P:AC
# dispatch) and the real advisory (user-prompt.sh, which prints
# wv_next_allowed_phase) against the same seeded state with no phases done.
# The advisory must never name a phase the gate denies for W-SCOPE or
# W-ORDER. When the gate allows the dispatch, the advisory must name that
# same phase.
#
# Repeated at SEA with BF-BC's chain done (vocabulary over the four values)
# and at TDE-RED for the pre-existing DR disagreement (ui and
# behaviour_change unknown, AC+ACB done).
set -u

# shellcheck source=tests/lib/assert.sh
source "$(dirname "$0")/../lib/assert.sh"

name="${WV_CASE_NAME:-$(basename "$0" .sh)}"
log="${WV_CASE_LOG:-$WV_RUN_TMP/logs/$name.log}"
rc=0
fail() { printf 'ASSERT FAIL: %s\n' "$*" >&2; rc=1; }
printf 'RAN pre-agent.sh %s decision=multi\n' "$name" >> "$log"

reason_of() {
  _wv_reason_text
}

gate_verdict() {
  # Prints `allow`, `W-SCOPE`, `W-ORDER`, or another decision/rule token.
  local d
  d="$(_wv_classify_decision)"
  case "$d" in
    silent|allow) printf 'allow' ;;
    deny)
      local reason r
      reason="$(reason_of)"
      r="${reason#\[}"
      r="${r%%]*}"
      printf '%s' "$r"
      ;;
    *) printf '%s' "$d" ;;
  esac
}

advisory_next() {
  # The phase code after the reminder's arrow, stripping any parenthetical
  # suffix the hook may add when that row is unanswered.
  local reason rest
  reason="$(reason_of)"
  case "$reason" in
    *" → "*) ;;
    *) printf 'NO-ARROW'; return 0 ;;
  esac
  rest="${reason#* → }"
  rest="${rest%%.*}"
  rest="${rest%% *}"
  printf '%s' "$rest"
}

apply_flag() {
  # apply_flag <key> <true|false|unknown|absent>  — reads JSON on stdin.
  local key="$1" val="$2"
  case "$val" in
    true)    jq --arg k "$key" '.[$k] = true' ;;
    false)   jq --arg k "$key" '.[$k] = false' ;;
    unknown) jq --arg k "$key" '.[$k] = "unknown"' ;;
    absent)  jq --arg k "$key" 'del(.[$k])' ;;
    *)
      fail "apply_flag: bad value '$val' for $key"
      cat
      ;;
  esac
}

drive_gate() {
  # drive_gate <state-file> <phase> <role> <model>
  local st="$1" phase="$2" role="$3" model="$4"
  local c="$WV_RUN_TMP/$name-gate.json"
  jq -n --arg st "$st" --arg d "[W:1 P:$phase R:$role] probe" --arg m "$model" '{
    script: "pre-agent.sh",
    seed: {state: $st},
    stdin: {
      session_id: "1a2b0599-4617-4e73-a9c0-2bef462b2626",
      cwd: ".",
      hook_event_name: "PreToolUse",
      tool_name: "Agent",
      tool_input: {description: $d, subagent_type: "general-purpose", model: $m}
    },
    expect: {}
  }' > "$c" || { fail "drive_gate: could not build the case"; return 1; }
  WV_PROJECT="$(mkproj)"
  run_hook pre-agent.sh "$c" || { fail "drive_gate: run_hook: $WV_LAST_STDERR"; return 1; }
  return 0
}

drive_advisory() {
  # drive_advisory <state-file>
  local st="$1"
  local c="$WV_RUN_TMP/$name-adv.json"
  jq -n --arg st "$st" '{
    script: "user-prompt.sh",
    seed: {state: $st},
    stdin: {hook_event_name: "UserPromptSubmit", prompt: "continue"}
  }' > "$c" || { fail "drive_advisory: could not build the case"; return 1; }
  WV_PROJECT="$(mkproj)"
  run_hook user-prompt.sh "$c" || { fail "drive_advisory: run_hook: $WV_LAST_STDERR"; return 1; }
  return 0
}

check_pair() {
  # check_pair <label> <state-file> <phase> <role> <model>
  local label="$1" st="$2" phase="$3" role="$4" model="$5"
  local verdict next
  if ! drive_gate "$st" "$phase" "$role" "$model"; then
    return 1
  fi
  verdict="$(gate_verdict)"
  if ! drive_advisory "$st"; then
    return 1
  fi
  next="$(advisory_next)"
  case "$verdict" in
    W-SCOPE|W-ORDER)
      if [ "$next" = "$phase" ]; then
        fail "$label: advisory named $next, but the gate denied $phase with $verdict ($(reason_of))"
      fi
      ;;
    allow)
      if [ "$next" != "$phase" ]; then
        fail "$label: gate allowed $phase but advisory named '$next' ($(reason_of))"
      fi
      ;;
    *)
      fail "$label: unexpected gate verdict '$verdict' for $phase (stdout='$WV_LAST_STDOUT')"
      ;;
  esac
}

BASE="$WV_TESTS_DIR/fixtures/state/valid-full.json"
BFBC="$WV_TESTS_DIR/fixtures/state/p2-bfbc.json"
ACB_UNK="$WV_TESTS_DIR/fixtures/state/p2-acb-ui-bc-unknown.json"

# ---- sixteen combinations at AC, nothing done -----------------------------

for vocab in true false unknown absent; do
  for bc in true false unknown absent; do
    label="ac-vocab=$vocab,bc=$bc"
    st="$WV_RUN_TMP/$name-$label.json"
    apply_flag vocabulary "$vocab" < "$BASE" | apply_flag behaviour_change "$bc" > "$st" \
      || { fail "$label: could not build state"; continue; }
    check_pair "$label" "$st" AC lead opus
  done
done

# ---- SEA after BF-BC's chain, vocabulary over the four values -------------

for vocab in true false unknown absent; do
  label="sea-vocab=$vocab"
  st="$WV_RUN_TMP/$name-$label.json"
  apply_flag vocabulary "$vocab" < "$BFBC" > "$st" \
    || { fail "$label: could not build state"; continue; }
  check_pair "$label" "$st" SEA executor sonnet
done

# ---- TDE-RED, the pre-existing DR disagreement ----------------------------

check_pair "tde-red-dr-unknown" "$ACB_UNK" TDE-RED executor sonnet

exit "$rc"
