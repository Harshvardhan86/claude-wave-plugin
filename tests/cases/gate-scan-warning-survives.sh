#!/usr/bin/env bash
# tests/cases/gate-scan-warning-survives.sh — fix round 2, item 1.
#
# A GATING SCAN THAT DID NOT RUN MUST SAY SO. `wv_scan_count` warns W-STATE when
# `command grep -c` gives it no count (an unreadable file, a wrapped searcher
# declining one) — but every caller in pre-agent.sh read it through a command
# substitution, and a command substitution is a subshell: the warning was queued
# on a COPY of the queue that died with it. The hook then allowed, silently,
# having reported a clean scan of a file it never managed to read. That is the
# false-allow shape Global Constraint 7 exists to prevent, arriving through the
# back door.
#
# Two reachable sites, one leg each, both driven with the file made UNREADABLE
# rather than absent — absence is a different, already-handled branch:
#
#   the findings condition  `.wave/findings/BC.md` unreadable, dispatching BF-BC
#   the DR RESOLVED count   `.wave/approvals/dr-open.md` unreadable, dispatching TDE-RED
#
# Each must still ALLOW (a hook that measured nothing does not deny) and must
# carry the W-STATE naming the file it could not read.
set -u

# shellcheck source=tests/lib/assert.sh
source "$(dirname "$0")/../lib/assert.sh"

name="${WV_CASE_NAME:-$(basename "$0" .sh)}"
log="${WV_CASE_LOG:-$WV_RUN_TMP/logs/$name.log}"
rc=0
fail() { printf 'ASSERT FAIL: %s\n' "$*" >&2; rc=1; }
printf 'RAN pre-agent.sh %s decision=multi\n' "$name" >> "$log"

if [ "$(id -u)" = "0" ]; then
  fail "this case cannot measure anything as root: an unreadable file is still readable"
  exit $rc
fi

leg() {
  # leg <label> <state fixture> <phase> <role> <model> <unreadable path> <seed json>
  local label="$1" state="$2" phase="$3" role="$4" model="$5" unreadable="$6" seed="$7"
  WV_PROJECT="$(mkproj)"
  local c="$WV_RUN_TMP/$name-$label.json"
  jq -n --arg s "$state" --argjson f "$seed" --arg d "[W:1 P:$phase R:$role] do the work" \
    --arg m "$model" '{
      script: "pre-agent.sh",
      seed: {state: $s, files: $f},
      stdin: {
        session_id: "1a2b0599-4617-4e73-a9c0-2bef462b2626",
        transcript_path: "/tmp/wave-plugin-tests/transcript.jsonl",
        cwd: ".", permission_mode: "bypassPermissions",
        hook_event_name: "PreToolUse", tool_name: "Agent",
        tool_use_id: "toolu_01RXAwe6jcU5LBKHd9geD6sE",
        tool_input: {description: $d, prompt: "Do the thing.",
                     subagent_type: "general-purpose", model: $m}
      }
    }' > "$c" || { fail "$label: could not build the case"; return 1; }

  # The seed is applied by run_hook, so the file cannot be made unreadable until
  # after it has been written — drive the seed here, then chmod, then run.
  WV_PROJECT="$WV_PROJECT" _wv_apply_seed "$c" || { fail "$label: seed failed"; return 1; }
  chmod 000 "$WV_PROJECT/$unreadable" || { fail "$label: chmod failed"; return 1; }
  [ -r "$WV_PROJECT/$unreadable" ] && { fail "$label: $unreadable is still readable"; return 1; }

  # A second _wv_apply_seed inside run_hook would rewrite the file we just made
  # unreadable, so the case json is stripped of its seed for the run itself.
  local c2="$WV_RUN_TMP/$name-$label-run.json"
  jq 'del(.seed)' "$c" > "$c2" || return 1
  run_hook pre-agent.sh "$c2" || { fail "$label: run_hook: $WV_LAST_STDERR"; return 1; }

  assert_allow || fail "$label: a scan that did not run must never deny"
  case "$WV_LAST_STDOUT$WV_LAST_STDERR" in
    *W-STATE*) : ;;
    *) fail "$label: the failed scan must be reported (W-STATE), got stdout='$WV_LAST_STDOUT' stderr='$WV_LAST_STDERR'" ;;
  esac
  case "$WV_LAST_STDOUT$WV_LAST_STDERR" in
    *"$(basename "$unreadable")"*) : ;;
    *) fail "$label: the report must name $unreadable, got '$WV_LAST_STDOUT$WV_LAST_STDERR'" ;;
  esac
  chmod 644 "$WV_PROJECT/$unreadable" 2>/dev/null
  return 0
}

leg findings state/p2-bc.json BF-BC executor sonnet .wave/findings/BC.md \
  '{".wave/findings/BC.md": "FINDINGS: 2\n", ".wave/approvals/bf-BC.md": "Approved.\n"}'

leg dropen state/p2-dr-ui.json TDE-RED executor sonnet .wave/approvals/dr-open.md \
  '{".wave/dr.md": "DR-VERIFIED\nOPEN: one\nOPEN: two\n", ".wave/approvals/dr-open.md": "RESOLVED: one\nRESOLVED: two\n"}'

exit $rc
