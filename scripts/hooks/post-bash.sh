#!/usr/bin/env bash
# scripts/hooks/post-bash.sh — record background Bash launches by subagent.
set -u

WV_HOOK_DIR="$(cd "${BASH_SOURCE[0]%/*}" 2>/dev/null && pwd)"
# shellcheck source=scripts/hooks/lib.sh
source "$WV_HOOK_DIR/lib.sh"

wv_jq_str() {
  jq -Rn --arg v "${1:-}" '$v'
}

wv_bg_task_id() {
  # Return a JSON literal so shell substitution cannot trim an id's newline.
  wv_json '.tool_response | select(type == "object") | .backgroundTaskId
    | select(type == "string" and length > 0) | tojson'
}

wv_main() {
  wv_parse_stdin || return 0
  [ "$WV_EVENT" = "PostToolUse" ] && [ "$WV_TOOL" = "Bash" ] || return 0
  [ -n "$WV_AGENT_ID" ] || return 0
  wv_project_root || return 0
  wv_state_read || return 0
  case "$WV_MODE" in full|demo) ;; *) return 0 ;; esac
  [ "$(wv_json '.tool_input.run_in_background == true')" = "true" ] || return 0
  local id agent_lit task_lit
  if ! id="$(wv_bg_task_id)" || [ -z "$id" ]; then
    wv_warn W-STATE 'background Bash response lacks a nonempty string backgroundTaskId; its task was not recorded'
    printf '%s\n' "$WV_WARNINGS" >&2
    WV_WARNINGS=""
    return 0
  fi
  agent_lit="$(wv_jq_str "$WV_AGENT_ID")" || return 0
  task_lit="$id"
  # Validate the optional map rather than replacing malformed data. The guard
  # and unique append both evaluate on the latest state inside the lock.
  wv_state_update "
    if .status != \"active\" or (.mode != \"full\" and .mode != \"demo\") then .
    else (.bg_tasks // {}) as \$map
      | if (\$map | type) != \"object\" then error(\"invalid task map\") else
        (\$map[$agent_lit] // []) as \$ids
        | if (\$ids | type) != \"array\" then error(\"invalid task ids\")
          elif any(\$ids[]; type != \"string\") then error(\"invalid task id\")
          else .bg_tasks[$agent_lit] = ((\$ids + [$task_lit]) | unique) end
        end
    end"
}

wv_main
wv_emit_flush
exit 0
