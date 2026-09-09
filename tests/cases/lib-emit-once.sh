#!/usr/bin/env bash
# tests/cases/lib-emit-once.sh — Global Constraint 5: one JSON object on stdout,
# nothing else.
#
# pre-agent.sh evaluates twelve rules in a single invocation, so a second
# emitter firing after the first is the ordinary case, not an exotic one. Two
# objects on stdout is not "a bit more output": the client parses one object, so
# the second is either ignored or breaks the parse. Both orders are driven here
# — deny then deny, and a flushed warning then a deny — and both must leave
# exactly one object, carrying the FIRST rule that fired (the caller evaluates
# rules in the precedence order `hooks/reasons.tsv` pins).
set -u

# shellcheck source=tests/lib/assert.sh
source "$(dirname "$0")/../lib/assert.sh"

name="$(basename "$0" .sh)"
rc=0
fail() { printf 'ASSERT FAIL: %s\n' "$*" >&2; rc=1; }

mkcase() {
  # mkcase <drive-action> -> path of a JSON case file named after this case.
  local action="$1" case_file="$WV_RUN_TMP/$name.json"
  jq -n --arg a "$action" '{
    script: "tests/fixtures/drive-lib.sh",
    env: { WV_DRIVE: $a },
    seed: { state: "state/valid-full.json" },
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
  printf '%s' "$case_file"
}

count_objects() {
  # jq reads stdin as a stream of JSON values, so `-s` counts them.
  printf '%s' "$WV_LAST_STDOUT" | jq -s 'length' 2>/dev/null || printf 'unparseable'
}

# --- two deny calls back to back ------------------------------------------
WV_PROJECT=""
if ! run_hook tests/fixtures/drive-lib.sh "$(mkcase 'deny-twice:W-TAG,W-FORK')"; then
  printf 'run_hook could not run the driver: %s\n' "$WV_LAST_STDERR" >&2
  exit 1
fi
assert_exit 0 || rc=1
objects="$(count_objects)"
[ "$objects" = "1" ] || fail "two wv_deny calls printed $objects JSON objects, want 1: '$WV_LAST_STDOUT'"
assert_deny W-TAG || rc=1            # the first rule that fired, not the last
assert_single_rule_token || rc=1
case "$WV_LAST_STDOUT" in
  *W-FORK*) fail "the second rule leaked into the emitted object: '$WV_LAST_STDOUT'" ;;
esac

# --- a deny, then a warning queued after it --------------------------------
# The trailing wv_emit_flush every hook ends with must not turn that late
# warning into a second object.
WV_PROJECT=""
if ! run_hook tests/fixtures/drive-lib.sh "$(mkcase 'deny-then-warn:W-TAG')"; then
  printf 'run_hook could not run the driver: %s\n' "$WV_LAST_STDERR" >&2
  exit 1
fi
assert_exit 0 || rc=1
objects="$(count_objects)"
[ "$objects" = "1" ] || fail "a deny followed by a late warning printed $objects JSON objects, want 1: '$WV_LAST_STDOUT'"
assert_deny W-TAG || rc=1

# --- two block calls on a SubagentStop -------------------------------------
mkstopcase() {
  local action="$1" case_file="$WV_RUN_TMP/$name-stop.json"
  jq -n --arg a "$action" '{
    script: "tests/fixtures/drive-lib.sh",
    env: { WV_DRIVE: $a },
    seed: { state: "state/valid-full.json" },
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
if ! run_hook tests/fixtures/drive-lib.sh "$(mkstopcase 'block-twice:W-ARTIFACT,W-MARKER')"; then
  printf 'run_hook could not run the driver: %s\n' "$WV_LAST_STDERR" >&2
  exit 1
fi
assert_exit 0 || rc=1
objects="$(count_objects)"
[ "$objects" = "1" ] || fail "two wv_block calls printed $objects JSON objects, want 1: '$WV_LAST_STDOUT'"
assert_block W-ARTIFACT || rc=1
assert_single_rule_token || rc=1
case "$WV_LAST_STDOUT" in
  *W-MARKER*) fail "the second rule leaked into the emitted block: '$WV_LAST_STDOUT'" ;;
esac

# --- a flushed warning, then a deny ---------------------------------------
WV_PROJECT=""
if ! run_hook tests/fixtures/drive-lib.sh "$(mkcase 'flush-then-deny:W-TAG')"; then
  printf 'run_hook could not run the driver: %s\n' "$WV_LAST_STDERR" >&2
  exit 1
fi
assert_exit 0 || rc=1
objects="$(count_objects)"
[ "$objects" = "1" ] || fail "a flush followed by a deny printed $objects JSON objects, want 1: '$WV_LAST_STDOUT'"

exit $rc
