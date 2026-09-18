#!/usr/bin/env bash
# scripts/hooks/user-prompt.sh — the UserPromptSubmit hook, spec section 8.6.
#
# While a full- or demo-mode wave is active, injects:
#   "wave <id> active, phase <last done> → <next allowed>. This session is
#    the orchestrator: dispatch tagged Agents, read only .wave/ reports, no
#    builds/tests/edits here."
#
# Silent (no output at all) with no wave, a closed wave, AND in solo mode
# (AC-291): solo receives no orchestrator reminder, just like an inactive wave.
#

# "Last done" / "next allowed" are computed via lib.sh's wv_last_done_phase /
# wv_next_allowed_phase, a minimal advisory-only port of pre-agent.sh's own
# order walk (see lib.sh section 11) — this file does not source
# pre-agent.sh, which would run its entire PreToolUse(Agent) rule chain
# against this event and then exit before this file ran another line.

set -u

WV_HOOK_DIR="$(cd "${BASH_SOURCE[0]%/*}" 2>/dev/null && pwd)"
# shellcheck source=scripts/hooks/lib.sh
source "$WV_HOOK_DIR/lib.sh"

wv_main() {
  wv_parse_stdin || return 0
  [ "$WV_EVENT" = "UserPromptSubmit" ] || return 0
  wv_project_root || return 0
  wv_state_read || return 0

  case "$WV_MODE" in
    full|demo) : ;;
    *) return 0 ;;   # solo (AC-291) and any unrecognised mode: silent
  esac

  local last_done next_allowed
  last_done="$(wv_last_done_phase)"
  next_allowed="$(wv_next_allowed_phase)"

  # An unanswered row is the phase the operator is waiting on, but it is not
  # yet dispatchable: a scope flag still has to be answered. The template's
  # third %s carries that note so the reminder stays one rule, stays
  # truthful, and stays under the 400-character bound (the longest fill is
  # a 9-character code plus " (scope answer pending)", well inside it).
  wv_up_condition_met "$next_allowed"
  if [ "$?" -eq 2 ]; then
    next_allowed="$next_allowed (scope answer pending)"
  fi

  wv_rule_warn W-REMINDER "$WV_WAVE" "$last_done" "$next_allowed"
  return 0
}

wv_main
wv_emit_flush
exit 0
