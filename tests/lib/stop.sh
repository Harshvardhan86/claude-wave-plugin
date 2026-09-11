#!/usr/bin/env bash
# tests/lib/stop.sh — helpers for the hand-written `subagent-stop.sh` cases.
#
# Sourced only by tests/cases/{stop,marker,taint,ledger,lock,lean}-*.sh, on top
# of tests/lib/assert.sh. The declarative JSON schema (tests/cases/README.md)
# covers one run against one seeded project; the scenarios here need several
# runs against ONE project with assertions between them (a data-state matrix,
# two agents of the same phase, twenty concurrent stops, a lock held by someone
# else). Each of those builds its own state file and its own case file, so
# these two builders exist to keep that boilerplate in one place:
#
#   stop_state <outfile> <jq filter over tests/fixtures/state/valid-full.json>
#   stop_case  <outfile> <jq filter over the base SubagentStop case>
#
# The base case's `stdin` is copied field for field from the SubagentStop
# payload in ~/WAVE_PLUGIN_ANALYSIS/probe-hooks.log — the same object
# tests/tools/gen-stop-cases.sh writes, so a `.sh` case and a `.json` case
# exercise the identical payload shape.
#
# `set -u`, never `set -e`: a case must be able to record several failures and
# still reach its own summary.
set -u

WV_STOPLIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WV_STOP_TESTS_DIR="$(cd "$WV_STOPLIB_DIR/.." && pwd)"
WV_STOP_BASE_STATE="$WV_STOP_TESTS_DIR/fixtures/state/valid-full.json"

stop_state() {
  # stop_state <outfile> <jq filter> — writes a wave state derived from
  # valid-full.json. Returns 1 (and says so) when jq rejects the filter, so a
  # broken filter fails its case instead of silently seeding the base state.
  local out="$1" filter="$2"
  if ! jq "$filter" "$WV_STOP_BASE_STATE" > "$out" 2>/dev/null; then
    printf 'stop_state: jq rejected the filter: %s\n' "$filter" >&2
    return 1
  fi
  [ -s "$out" ] || { printf 'stop_state: wrote an empty state file\n' >&2; return 1; }
  return 0
}

stop_active() {
  # stop_active <phase> <role> <requested-model> -> the jq object literal for
  # one state.active entry, in the exact shape post-agent.sh writes.
  jq -nc --arg p "$1" --arg r "$2" --arg m "$3" \
    '{phase: $p, role: $r, requested_model: $m,
      resolved_model: ("claude-" + $m + "-5"),
      tool_use_id: "toolu_01RXAwe6jcU5LBKHd9geD6sE", status: "launched"}'
}

stop_case() {
  # stop_case <outfile> <jq filter> — writes a SubagentStop case file. The
  # filter sets whatever the scenario needs, e.g.
  #   '.seed.state = "/abs/state.json"
  #    | .stdin.agent_id = "a2"
  #    | .stdin.stop_hook_active = true
  #    | .seed.files = {".wave/ac.md": "AC-1 x\n"}'
  local out="$1" filter="$2" base
  base="$(cat <<'JSON'
{
  "script": "subagent-stop.sh",
  "seed": {},
  "stdin": {
    "session_id": "1a2b0599-4617-4e73-a9c0-2bef462b2626",
    "transcript_path": "/tmp/wave-plugin-tests/transcript.jsonl",
    "cwd": ".",
    "prompt_id": "c1f033ea-e4ee-4474-88ec-3913700ae39d",
    "permission_mode": "bypassPermissions",
    "agent_id": "a1",
    "agent_type": "general-purpose",
    "hook_event_name": "SubagentStop",
    "stop_hook_active": false,
    "last_assistant_message": "done",
    "background_tasks": [
      {"id": "a1", "type": "subagent", "status": "running",
       "description": "probe echo", "agent_type": "general-purpose"}
    ],
    "session_crons": []
  },
  "expect": {}
}
JSON
)"
  if ! printf '%s' "$base" | jq "$filter" > "$out" 2>/dev/null; then
    printf 'stop_case: jq rejected the filter: %s\n' "$filter" >&2
    return 1
  fi
  [ -s "$out" ] || { printf 'stop_case: wrote an empty case file\n' >&2; return 1; }
  return 0
}

stop_phase_status() {
  # stop_phase_status <code> -> state.phases[<code>].status, or "" — read from
  # the live project, between runs.
  jq -r --arg c "$1" '(.phases[$c].status // "")' \
    "$WV_PROJECT/.wave/state.json" 2>/dev/null
}

stop_ledger_count() {
  # stop_ledger_count -> the number of ledger lines, 0 when there is no ledger.
  local l="$WV_PROJECT/.wave/ledger.jsonl"
  if [ -f "$l" ]; then wc -l < "$l" | tr -d ' '; else printf '0'; fi
}
