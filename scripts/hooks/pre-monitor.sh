#!/usr/bin/env bash
# scripts/hooks/pre-monitor.sh — the PreToolUse hook on `Monitor`.
# W-POLL leaves monitoring to the main session in active full/demo waves.
set -u

WV_HOOK_DIR="$(cd "${BASH_SOURCE[0]%/*}" 2>/dev/null && pwd)"
# shellcheck source=scripts/hooks/lib.sh
source "$WV_HOOK_DIR/lib.sh"

wv_main() {
  wv_parse_stdin || return 0
  [ "$WV_EVENT" = "PreToolUse" ] || return 0
  [ "$WV_TOOL" = "Monitor" ] || return 0
  wv_project_root || return 0
  wv_state_read || return 0
  case "$WV_MODE" in
    full|demo) : ;;
    *) return 0 ;;
  esac
  # Identity alone decides; tool_input describes the watched command.
  [ -n "$WV_AGENT_ID" ] || return 0
  wv_rule_deny W-POLL Monitor
}

wv_main
wv_emit_flush
exit 0
