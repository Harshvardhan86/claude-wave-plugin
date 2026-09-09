#!/usr/bin/env bash
# scripts/hooks/pre-read.sh — the PreToolUse hook on `Read`.
#
# Spec section 8.2: a main-session Read is denied (W-READ) unless the
# resolved path is under `.wave/` (reports, artifacts, checkpoints) or
# outside the project root entirely. `Grep`, `Glob` and `LS` are never
# gated — this script is wired to `Read` only, and any other tool is a
# silent no-op by construction (AC-277).
#
# Solo mode and any call made INSIDE a subagent (stdin carries `agent_id`)
# are both silent no-ops — see pre-edit.sh's header, which this script
# mirrors, and lib.sh's wv_resolve_input_path for the shared path logic.
#
# Measured (Task 9 probe, 2026-09-10; see tests/fixtures/measured-keys.txt):
# `Read` carries `tool_input.file_path`, always sent as an absolute path.

set -u

WV_HOOK_DIR="$(cd "${BASH_SOURCE[0]%/*}" 2>/dev/null && pwd)"
# shellcheck source=scripts/hooks/lib.sh
source "$WV_HOOK_DIR/lib.sh"

wv_main() {
  wv_parse_stdin || return 0
  [ "$WV_EVENT" = "PreToolUse" ] || return 0
  [ "$WV_TOOL" = "Read" ] || return 0

  # Subagents read whatever they need; only the main session is gated.
  [ -z "$WV_AGENT_ID" ] || return 0

  wv_project_root || return 0
  wv_state_read || return 0
  case "$WV_MODE" in
    full|demo) : ;;
    *) return 0 ;;
  esac

  local raw resolved
  raw="$(wv_json '.tool_input.file_path // empty')"
  resolved="$(wv_resolve_input_path "$raw")" || return 0

  # Outside the project root: silent no-op (spec section 8.2's second
  # exemption — the orchestrator's own analysis and handoff files).
  wv_inside_root "$resolved" || return 0

  local rel="${resolved#"$WV_ROOT"/}"
  case "$rel" in
    .wave|.wave/*) return 0 ;;
  esac

  wv_rule_deny W-READ "$resolved"
  return 0
}

wv_main
wv_emit_flush
exit 0
