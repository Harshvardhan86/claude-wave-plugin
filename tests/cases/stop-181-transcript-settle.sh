#!/usr/bin/env bash
# tests/cases/stop-181-transcript-settle.sh — the SubagentStop-vs-transcript-flush
# race, driven deterministically.
#
# The defect (progress ledger line 181, measured ~1 in 5 live runs while building
# tests/e2e.sh scenario (c)): SubagentStop fires and subagent-stop.sh reads the
# subagent's OWN transcript before the client has flushed its assistant turn(s).
# `jq` over an empty-but-existing file returns a well-formed zero header, so the
# hook records `turns:0`, `tier_ok:null`, `tier_verified:false` for an agent that
# demonstrably ran on the right model — a correct wave scored as an unverifiable
# one, and (because `tainted` is keyed on tier_ok == false, not null) silently.
#
# It is driven here with a BACKGROUND WRITER rather than by hoping: the
# transcript file is created empty, a writer appends one complete assistant turn
# 600 ms after the hook starts, and the hook must still read that turn. 600 ms is
# comfortably past one settle sample (200 ms) and comfortably inside the cap
# (~2.4 s), so the case fails against a hook that reads immediately and passes
# against one that waits for the file to hold a complete assistant turn and stop
# growing. No `sleep` in the assertion path decides anything: every step asserts
# the CONTENT the hook recorded, never a duration.
#
# Four steps, because a settle that always waits the cap would be as wrong as one
# that never waits:
#   late      the assistant turn lands 600 ms in     -> it IS counted (the race)
#   prompt    a complete transcript is there already -> counted, and the case
#                                                       proves the settle did not
#                                                       need the writer
#   never     the file stays empty forever           -> the cap is reached, the
#                                                       hook proceeds (never
#                                                       blocks), the ledger line
#                                                       is marked
#                                                       transcript_incomplete and
#                                                       a W-STATE warning names
#                                                       the path
#   overcap   a file past WV_TRANSCRIPT_CAP          -> no wait at all; the sum is
#                                                       skipped either way, so
#                                                       there is nothing to settle
#
# `set -u`, never `set -e`: every step records its own failures and the case
# still reaches its summary.
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

lline() { tail -n 1 "$WV_PROJECT/.wave/ledger.jsonl" 2>/dev/null; }

WV_ASSISTANT_LINE='{"type":"assistant","message":{"model":"claude-opus-5","usage":{"input_tokens":11,"output_tokens":13}}}'

cap="$(command grep -m1 -oE 'WV_TRANSCRIPT_CAP=[0-9]+' "$WV_REPO_ROOT/scripts/hooks/subagent-stop.sh" 2>/dev/null | cut -d= -f2)"
case "$cap" in
  ''|*[!0-9]*) fail "could not read WV_TRANSCRIPT_CAP out of scripts/hooks/subagent-stop.sh (got '$cap')"; exit 1 ;;
esac

drive() {
  # drive <step> <mode> — builds a fresh project, plants the transcript per
  # <mode>, runs the hook once. Returns 1 when the setup itself failed.
  local step="$1" mode="$2"
  WV_PROJECT="$(mkproj)"
  local st="$WV_RUN_TMP/$name-$step-state.json" c="$WV_RUN_TMP/$name-$step.json"
  local tr="$WV_PROJECT/.wave/tr/a1.jsonl"
  mkdir -p "$WV_PROJECT/.wave/tr" || return 1

  local writer_pid=""
  case "$mode" in
    late)
      # The file exists and is EMPTY when the hook starts, exactly as the live
      # race presents it, and gains its one complete assistant turn 600 ms in.
      : > "$tr"
      ( sleep 0.6; printf '%s\n' "$WV_ASSISTANT_LINE" >> "$tr" ) &
      writer_pid=$!
      ;;
    prompt)
      printf '%s\n' "$WV_ASSISTANT_LINE" > "$tr"
      ;;
    never)
      : > "$tr"
      ;;
    overcap)
      printf '%s\n' "$WV_ASSISTANT_LINE" > "$tr"
      truncate -s "$((cap + 1))" "$tr" || { fail "$step: truncate failed"; return 1; }
      ;;
  esac

  stop_state "$st" ".active = {a1: $(stop_active AC reviewer opus)}" || return 1
  stop_case "$c" "$(printf '.seed.state = "%s" | .seed.files = {".wave/ac.md": "AC-1 records the spend\\n"} | .stdin.agent_transcript_path = ".wave/tr/a1.jsonl"' "$st")" || return 1
  run_hook subagent-stop.sh "$c" || { fail "$step: run_hook: $WV_LAST_STDERR"; return 1; }
  [ -z "$writer_pid" ] || wait "$writer_pid" 2>/dev/null
  return 0
}

# ---- 1. the race itself ----------------------------------------------------
if drive late late; then
  assert_allow || fail "late: a late transcript must never block"
  printf '%s' "$(lline)" | jq -e '.turns == 1 and .input == 11 and .output == 13' >/dev/null 2>&1 || \
    fail "late: the assistant turn that landed 600 ms after the hook started was not counted; ledger line is $(lline)"
  printf '%s' "$(lline)" | jq -e '.tier_ok == true and .tier_verified == true' >/dev/null 2>&1 || \
    fail "late: the tier must be verified against the turn that landed late; ledger line is $(lline)"
  printf '%s' "$(lline)" | jq -e 'has("transcript_incomplete") | not' >/dev/null 2>&1 || \
    fail "late: a transcript that DID settle must not be marked incomplete; ledger line is $(lline)"
  case "${WV_LAST_STDERR:-}" in
    *W-STATE*) fail "late: a transcript that settled must not warn; stderr is '${WV_LAST_STDERR:-}'" ;;
  esac
fi

# ---- 2. the control: no writer needed -------------------------------------
if drive prompt prompt; then
  assert_allow || fail "prompt: want no block"
  printf '%s' "$(lline)" | jq -e '.turns == 1 and .tier_ok == true and (has("transcript_incomplete") | not)' >/dev/null 2>&1 || \
    fail "prompt: an already-complete transcript must be read as it always was; ledger line is $(lline)"
fi

# ---- 3. the cap ------------------------------------------------------------
if drive never never; then
  assert_allow || fail "never: reaching the settle cap must never block"
  printf '%s' "$(lline)" | jq -e '.transcript_incomplete == true' >/dev/null 2>&1 || \
    fail "never: an unsettled transcript must be recorded as transcript_incomplete; ledger line is $(lline)"
  printf '%s' "$(lline)" | jq -e '.turns == 0 and .tier_ok == null and .tier_verified == false' >/dev/null 2>&1 || \
    fail "never: an unsettled transcript is unverifiable, not tainted; ledger line is $(lline)"
  jq -e '(.phases.AC.tainted // false) == false' "$WV_PROJECT/.wave/state.json" >/dev/null 2>&1 || \
    fail "never: an unverifiable tier must not set tainted"
  assert_stderr_contains 'W-STATE' || fail "never: the cap must be reported"
  assert_stderr_contains '.wave/tr/a1.jsonl' || \
    fail "never: the W-STATE warning must name the transcript path, stderr is '${WV_LAST_STDERR:-}'"
fi

# ---- 4. no wait for a transcript already past the byte cap -----------------
if drive overcap overcap; then
  assert_allow || fail "overcap: want no block"
  printf '%s' "$(lline)" | jq -e '.note == "transcript too large" and (has("transcript_incomplete") | not)' >/dev/null 2>&1 || \
    fail "overcap: a transcript past the cap is skipped, not unsettled; ledger line is $(lline)"
fi

exit $rc
