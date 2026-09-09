#!/usr/bin/env bash
# tests/cases/lib-units.sh — the library interfaces that have no AC of their
# own in this task but must not ship untested: the `enforce: "warn"`
# conversion, the `WV_PARSED` / `WV_STATE_OK` emitter gates, `wv_tier`'s
# tokenising rules (spec section 7) and `wv_scan_count`'s "an empty count is a
# failed scan, never 0" rule (Global Constraint 7).
#
# The first half drives the library as a real hook process (which also writes
# the run marker tests/run.sh checks); the second half sources it and calls the
# pure helpers directly, which is the only way to assert a return code and a
# printed tier without inventing an output channel in production code.
set -u

# shellcheck source=tests/lib/assert.sh
source "$(dirname "$0")/../lib/assert.sh"

name="$(basename "$0" .sh)"
rc=0
fail() { printf 'ASSERT FAIL: %s\n' "$*" >&2; rc=1; }

# ---- enforce: "warn" turns a deny into the event's warn channel -----------
warn_fixture="$WV_RUN_TMP/state-enforce-warn.json"
jq '.enforce = "warn"' "$WV_TESTS_DIR/fixtures/state/valid-full.json" > "$warn_fixture"

case_file="$WV_RUN_TMP/$name.json"
jq -n --arg f "$warn_fixture" '{
  script: "lib.sh",
  env: { WV_DRIVE: "deny:W-TAG" },
  seed: { state: $f },
  stdin: {
    hook_event_name: "PreToolUse",
    tool_name: "Agent",
    cwd: ".",
    tool_input: {
      description: "probe dispatch",
      prompt: "Do the thing.",
      subagent_type: "general-purpose",
      model: "sonnet"
    },
    tool_use_id: "toolu_016jDXUebmA9qCw58g1rxGuH"
  }
}' > "$case_file"

WV_PROJECT=""
if ! run_hook lib.sh "$case_file"; then
  printf 'run_hook could not run the library: %s\n' "$WV_LAST_STDERR" >&2
  exit 1
fi
assert_exit 0 || rc=1
assert_warn W-TAG || rc=1              # same rule id, warn channel, no deny
assert_allow || rc=1

# ---- SubagentStop: block, and its warn channel ---------------------------
# SubagentStop has no additionalContext channel, so under enforce:"warn" the
# warning has to land in state.phases[<phase>].warned plus a `warn` field on a
# ledger line (spec section 2 / the AC conventions).
mkstop() {
  local fixture="$1" case_file="$WV_RUN_TMP/$name.json"
  jq -n --arg f "$fixture" '{
    script: "lib.sh",
    env: { WV_DRIVE: "block:W-ARTIFACT", WV_PHASE: "TDE-RED" },
    seed: { state: $f },
    stdin: {
      hook_event_name: "SubagentStop",
      agent_id: "abe831e9837f3dcee",
      agent_type: "general-purpose",
      agent_transcript_path: "/nonexistent/subagents/abe831e9837f3dcee.jsonl",
      last_assistant_message: "done",
      stop_hook_active: false,
      cwd: "."
    }
  }' > "$case_file"
  printf '%s' "$case_file"
}

WV_PROJECT=""
run_hook lib.sh "$(mkstop "$warn_fixture")" || exit 1
assert_exit 0 || rc=1
assert_allow || rc=1
[ -z "$WV_LAST_STDOUT" ] || fail "under enforce=warn a SubagentStop must not print a block: '$WV_LAST_STDOUT'"
assert_state '(.phases["TDE-RED"].warned | length) == 1 and (.phases["TDE-RED"].warned[0] | startswith("[W-ARTIFACT] "))' || rc=1
assert_ledger_lines 1 || rc=1
ledger_warn="$(jq -r '.warn[0] // ""' "$WV_PROJECT/.wave/ledger.jsonl")"
case "$ledger_warn" in
  "[W-ARTIFACT] "*) : ;;
  *) fail "the ledger line does not carry the warn field: '$ledger_warn'" ;;
esac

WV_PROJECT=""
run_hook lib.sh "$(mkstop state/valid-full.json)" || exit 1
assert_exit 0 || rc=1
assert_block W-ARTIFACT || rc=1
assert_ledger_lines 0 || rc=1

# ---- the pure helpers, called directly ------------------------------------
# shellcheck source=scripts/hooks/lib.sh
source "$WV_REPO_ROOT/scripts/hooks/lib.sh"

want_tier() {
  local model="$1" want="$2" got
  got="$(wv_tier "$model")"
  [ "$got" = "$want" ] || fail "wv_tier '$model': want $want, got $got"
}

want_tier haiku 1
want_tier sonnet 2
want_tier opus 3
want_tier fable 4
want_tier claude-haiku-4-5-20251001 1
want_tier claude-sonnet-4-5-20250929 2
want_tier 'claude-opus-5[1m]' 3
want_tier '  OPUS  ' 3                 # trimmed and lowercased
want_tier opusless-1 unknown           # tier names match as tokens, not substrings
want_tier gpt-5 unknown                # zero matches
want_tier claude-sonnet-opus-preview unknown   # two distinct matches
want_tier opusplan unknown             # declared-unknown alias
want_tier default unknown              # declared-unknown alias
want_tier '' unknown
want_tier inherit unknown

# ---- wv_scan_count -------------------------------------------------------
plant_control src/probe.txt
n="$(wv_scan_count "$WV_PROJECT/src/probe.txt" 'WV-PLANTED-CONTROL')"
scan_rc=$?
[ "$n" = "1" ] || fail "wv_scan_count on a planted control: want 1, got '$n'"
[ "$scan_rc" = "0" ] || fail "wv_scan_count on a planted control: want rc=0, got rc=$scan_rc"

n="$(wv_scan_count "$WV_PROJECT/src/probe.txt" 'THIS-STRING-IS-NOT-THERE')"
scan_rc=$?
[ "$n" = "0" ] || fail "wv_scan_count with no match: want a printed 0, got '$n'"
[ "$scan_rc" = "0" ] || fail "wv_scan_count with no match: a real zero is a clean scan, got rc=$scan_rc"

WV_PARSED=1
WV_WARNINGS=""
n="$(wv_scan_count "$WV_PROJECT/src/nonexistent.txt" 'anything')"
scan_rc=$?
[ "$scan_rc" = "1" ] || fail "wv_scan_count on an unreadable file must fail the scan, got rc=$scan_rc"
[ -z "$n" ] || fail "wv_scan_count on an unreadable file must not report a count, got '$n'"
wv_scan_count "$WV_PROJECT/src/nonexistent.txt" 'anything' >/dev/null
case "$WV_WARNINGS" in
  *"[W-STATE]"*) : ;;
  *) fail "a failed scan must warn W-STATE, got '$WV_WARNINGS'" ;;
esac

# ---- the emitter gates ---------------------------------------------------
WV_EVENT="PreToolUse"
WV_ENFORCE="block"

WV_PARSED=0
WV_STATE_OK=1
WV_WARNINGS=""
out="$(wv_deny W-TAG 'gate check')"
[ -z "$out" ] || fail "wv_deny emitted without a positive parse marker: '$out'"

WV_PARSED=1
WV_STATE_OK=0
WV_WARNINGS=""
out="$(wv_deny W-TAG 'gate check')"
[ -z "$out" ] || fail "wv_deny emitted while the state was unreadable: '$out'"

WV_PARSED=0
WV_STATE_OK=0
WV_WARNINGS=""
out="$(wv_warn W-STATE 'gate check'; printf '%s' "$WV_WARNINGS")"
[ -z "$out" ] || fail "wv_warn emitted without a positive parse marker: '$out'"

WV_PARSED=1
WV_STATE_OK=1
WV_WARNINGS=""
out="$(wv_deny W-TAG 'gate check')"
case "$out" in
  *'"permissionDecision":"deny"'*) : ;;
  *) fail "wv_deny with both markers set did not emit a deny: '$out'" ;;
esac

exit $rc
