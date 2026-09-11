#!/usr/bin/env bash
# tests/cases/reasons-392-state-outranks.sh — AC-392: W-STATE outranks every other
# id, which is the fail-open principle expressed as precedence.
#
# An unreadable state file plus an otherwise perfectly denyable dispatch must
# produce a W-STATE WARNING and never a deny. Not because W-STATE is "more
# important", but because a hook that could not read its input has not measured
# anything: the rule it would have denied on was never evaluated against real
# state, so denying would be a false NO-GO built on nothing.
#
# Three shapes of "could not be trusted", each with an input that WOULD deny if the
# state were readable — that pairing is the whole content of the claim, and a case
# that only proved "unreadable state is silent" would pass just as well against a
# hook that denied nothing ever:
#
#   invalid    state.json is not JSON at all
#   noschema   state.json parses but declares no mode (a half-written file)
#   badenforce state.json is valid but `enforce` is neither block nor warn, so
#              block is used AND the value is reported — the one shape where a
#              W-STATE warning rides ALONGSIDE a real deny rather than replacing
#              it, because here the state WAS readable
#
# `set -u`, never `set -e`.
set -u

# shellcheck source=tests/lib/assert.sh
source "$(dirname "$0")/../lib/assert.sh"

name="${WV_CASE_NAME:-$(basename "$0" .sh)}"
log="${WV_CASE_LOG:-$WV_RUN_TMP/logs/$name.log}"
rc=0
fail() { printf 'ASSERT FAIL: %s\n' "$*" >&2; rc=1; }
printf 'RAN multi %s decision=multi\n' "$name" >> "$log"

# The denyable dispatch every shape below reuses: untagged, so a readable state
# would answer W-TAG. Proven first, as the positive control.
DENYABLE='.stdin.tool_input.description = "run the acceptance criteria review"'

drive() {
  # drive <label> <state file contents or fixture path> <stdin filter>
  local label="$1" state="$2" stdin_filter="$3"
  WV_PROJECT="$(mkproj)"
  local c="$WV_RUN_TMP/$name-$label.json"
  jq -n '{
    script: "pre-agent.sh",
    seed: {},
    stdin: {
      session_id: "1a2b0599-4617-4e73-a9c0-2bef462b2626",
      cwd: ".",
      hook_event_name: "PreToolUse",
      tool_name: "Agent",
      tool_input: {subagent_type: "general-purpose"}
    },
    expect: {}
  }' | jq "$stdin_filter" > "$c" || { fail "$label: jq rejected the stdin filter"; return 1; }
  mkdir -p "$WV_PROJECT/.wave"
  if [ -f "$WV_TESTS_DIR/fixtures/state/$state" ]; then
    cp "$WV_TESTS_DIR/fixtures/state/$state" "$WV_PROJECT/.wave/state.json"
  else
    printf '%s' "$state" > "$WV_PROJECT/.wave/state.json"
  fi
  : > "$WV_PROJECT/.wave/lock"
  run_hook pre-agent.sh "$c" || { fail "$label: run_hook: $WV_LAST_STDERR"; return 1; }
  return 0
}

reason_of() {
  printf '%s' "$WV_LAST_STDOUT" | jq -r \
    '.hookSpecificOutput.permissionDecisionReason // .reason // .hookSpecificOutput.additionalContext // empty'
}

# ---- the positive control: readable state, so the dispatch DOES deny ---------
if drive control valid-full.json "$DENYABLE"; then
  assert_deny W-TAG || fail "control: a readable state must let the untagged dispatch deny W-TAG"
fi

# ---- unreadable state: warn, never deny ------------------------------------
for shape in invalid noschema; do
  case "$shape" in
    invalid)  st='this is not json at all' ;;
    noschema) st='{"schema":1,"status":"active","wave":"1"}' ;;
  esac
  if drive "$shape" "$st" "$DENYABLE"; then
    assert_exit 0 || fail "$shape: a hook that could not read its state must exit 0"
    if printf '%s' "$WV_LAST_STDOUT" | jq -e '.hookSpecificOutput.permissionDecision' >/dev/null 2>&1; then
      fail "$shape: the same input that denies on readable state must NOT deny here: '$WV_LAST_STDOUT'"
    fi
    r="$(reason_of)"
    case "$r" in
      "[W-STATE] "*) : ;;
      *) fail "$shape: want a rendered W-STATE warning, got '$r'" ;;
    esac
    tokens="$(printf '%s' "$r" | command grep -oE 'W-[A-Z0-9-]+' | wc -l | tr -d ' ')"
    [ "$tokens" = "1" ] || fail "$shape: the warning carries $tokens W- tokens, want 1: '$r'"
    case "$r" in
      *W-TAG*) fail "$shape: the outranked rule's id must not appear: '$r'" ;;
    esac
    printf '  %-10s -> %s\n' "$shape" "$(printf '%s' "$r" | cut -c1-90)"
  fi
done

# ---- readable state, unrecognised enforce: the warning RIDES on the deny -----
#
# This is the boundary of AC-392 and the reason the rule is "W-STATE outranks",
# not "W-STATE silences": here the state WAS read, so the dispatch is judged, and
# the W-STATE warning about the bad `enforce` value travels as additionalContext
# on the deny object rather than replacing it. A hook that dropped it would leave
# the operator denied under a value the plugin silently reinterpreted.
if drive badenforce '{"schema":1,"status":"active","mode":"full","wave":"1","enforce":"maybe","ui":false,"behaviour_change":false,"cr_enabled":false,"phases":{},"active":{},"pending":{},"rounds":{}}' "$DENYABLE"; then
  assert_deny W-TAG || fail "badenforce: a readable state still judges the dispatch"
  ctx="$(printf '%s' "$WV_LAST_STDOUT" | jq -r '.hookSpecificOutput.additionalContext // ""')"
  case "$ctx" in
    *'[W-STATE]'*) : ;;
    *) fail "badenforce: the W-STATE warning must ride on the deny as additionalContext, got '$ctx'" ;;
  esac
  case "$ctx" in
    *'maybe'*) : ;;
    *) fail "badenforce: the warning must name the value it refused: '$ctx'" ;;
  esac
  n="$(printf '%s' "$WV_LAST_STDOUT" | jq -s 'length')"
  [ "$n" = "1" ] || fail "badenforce: $n JSON object(s) on stdout, want exactly 1"
  printf '  %-10s -> deny W-TAG carrying the W-STATE warning\n' badenforce
fi

exit $rc
