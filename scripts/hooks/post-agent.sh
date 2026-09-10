#!/usr/bin/env bash
# scripts/hooks/post-agent.sh — the PostToolUse hook on the `Agent` tool.
#
# This is the launch record. `PostToolUse(Agent)` fires at DISPATCH, not at
# completion (spec section 2): for an async dispatch `tool_response` carries
# `status: "async_launched"`, an `agentId` and a `resolvedModel`; the
# (measured, synchronous) alternative carries `status: "completed"`. Either
# shape is a real launch. This script's only job is to remember it —
# `phase`, `role`, `requested_model`, `resolved_model`, `tool_use_id` and a
# `launched|downgraded` status — under `state.active[<agentId>]`, so that
# `subagent-stop.sh` (Task 8) can join on it at `SubagentStop` and increment
# `state.rounds`. This script never writes `state.rounds` itself (AC-201) and
# never denies: `PostToolUse` has no deny channel at all (spec section 2), so
# every rule below is a `wv_warn`, never a `wv_deny`.
#
# Interfaces this file provides (task 7 brief):
#   wv_tool_response_field <name>  — the tolerant three-step read of
#     tool_response, whether the client sent it as a JSON object, a
#     JSON-encoded string, or a string truncated mid-object.
#
# Evaluation order, one JSON object on stdout at most (the library's
# WV_EMITTED guard), never a deny:
#
#   event/tool guard   (silent: wired to PostToolUse(Agent) only)
#   -> state            (silent: no active wave, W-STATE on unreadable state)
#   -> the tag          (not a rule: identifies phase/role for the record,
#                        or "untagged"/"SOLO" per the untagged-dispatch
#                        behaviour below — never denies, never warns)
#   -> launch status    W-RESOLVE-UNKNOWN (status is neither async_launched
#                        nor completed: no active/pending entry at all)
#   -> agentId          W-RESOLVE-UNKNOWN (absent: state.pending[tool_use_id]
#                        instead of state.active, so the loss is visible)
#   -> resolved tier    W-DOWNGRADE (below the requested tier) or
#                       W-RESOLVE-UNKNOWN (resolvedModel unreadable) —
#                       upward or equal resolution is silent.
#
# Untagged-dispatch behaviour (brief step 5): a dispatch pre-agent.sh would
# have denied outright is never actually launched, so recording it would
# invent a phantom entry.
#   - full/demo, enforce:"block", no tag for this wave -> the dispatch was
#     already denied at PreToolUse; this script returns before touching
#     state at all, so state.json is byte-identical (AC-199).
#   - full/demo, enforce:"warn" -> the same dispatch WAS allowed through
#     (warn only), so its spend still has to be ledgered at stop: recorded
#     under phase:"untagged", role:"unknown" (AC-200).
#   - solo -> phases.tsv is never consulted (spec section 6), so a tag is
#     recorded verbatim when present and an untagged dispatch is recorded
#     under phase:"SOLO", role:"unknown" — subagent-stop.sh's solo-mode
#     ledger line (AC-330/AC-337, a different task's tests) reads its
#     phase/role off this record.
#   - any other/unrecognised mode is folded into the solo shape: a hook that
#     does not recognise the mode enforces nothing, per the library's own
#     precedent in pre-agent.sh, but still leaves a joinable record rather
#     than crashing a later hook on a missing key.
#
# What this file deliberately does NOT reuse from pre-agent.sh, and why:
#   - wv_phase_row / wv_role_tier (and hooks/phases.tsv itself) are never
#     read here. Pre-agent.sh's tier gate compares the REQUESTED model
#     against the phase table's per-role MINIMUM; this hook's tier cross-
#     check (spec section 7, second bullet) compares the RESOLVED model
#     against the REQUESTED model — a settings override silently downgrading
#     what was actually asked for, independent of what the table would have
#     required. There is no case in this file's evaluation order that needs
#     the table at all.
#   - wv_tag_parse itself is not sourced (see wv_tag_parse_light below) —
#     copied, not reused, for a mechanical reason: pre-agent.sh is a
#     standalone driver script that ends by calling its own wv_main and
#     `exit 0`, so `source`-ing it would run the whole PreToolUse rule chain
#     against THIS event and then terminate this script before its own code
#     ran. The grammar (WV_TAG_RE) is copied byte-for-byte so this script
#     recognises exactly the tag pre-agent.sh already judged; the
#     diagnostic-only machinery (WV_TAG_DETAIL, wv_excerpt, the late-tag and
#     role-shaped regexes) is dropped because this script never renders a
#     W-TAG reason to feed it.

set -u

WV_HOOK_DIR="$(cd "${BASH_SOURCE[0]%/*}" 2>/dev/null && pwd)"
# shellcheck source=scripts/hooks/lib.sh
source "$WV_HOOK_DIR/lib.sh"

# ---------------------------------------------------------------------------
# 1. The tag (a reduced copy of pre-agent.sh's wv_tag_parse; see header).
# ---------------------------------------------------------------------------

WV_TAG_RE='^\[W:([^] ]+) P:([A-Z0-9-]+) R:(lead|executor|reviewer|scanner|writer)\]'

WV_TAG_WAVE=""
WV_TAG_PHASE=""
WV_TAG_ROLE=""
WV_TAG_OK=0

wv_tag_parse_light() {
  # wv_tag_parse_light <description> <prompt> -> WV_TAG_WAVE / WV_TAG_PHASE /
  # WV_TAG_ROLE / WV_TAG_OK. Accepted at byte 0 of the description, or as the
  # prompt's first line — identical grammar and precedence to
  # pre-agent.sh's wv_tag_parse. Bash pattern matching only, never eval'd:
  # hook input is data.
  local desc="${1:-}" prompt="${2:-}"
  WV_TAG_WAVE=""
  WV_TAG_PHASE=""
  WV_TAG_ROLE=""
  WV_TAG_OK=0

  local first_line="${prompt%%$'\n'*}"
  local cand src
  for src in description prompt; do
    if [ "$src" = "description" ]; then cand="$desc"; else cand="$first_line"; fi
    if [[ "$cand" =~ $WV_TAG_RE ]]; then
      WV_TAG_WAVE="${BASH_REMATCH[1]}"
      WV_TAG_PHASE="${BASH_REMATCH[2]}"
      WV_TAG_ROLE="${BASH_REMATCH[3]}"
      WV_TAG_OK=1
      return 0
    fi
  done
  return 1
}

# ---------------------------------------------------------------------------
# 2. stdin: the launch-record fields.
# ---------------------------------------------------------------------------

WV_DESC=""
WV_PROMPT_TEXT=""
WV_MODEL_TRIM=""
WV_TOOL_USE_ID=""

wv_read_launch_input() {
  # One jq call per field, deliberately (a description or prompt may carry
  # newlines; see pre-agent.sh's wv_read_tool_input for the same reasoning).
  WV_DESC="$(wv_json '.tool_input.description // "" | tostring')"
  WV_PROMPT_TEXT="$(wv_json '.tool_input.prompt // "" | tostring')"
  local model
  model="$(wv_json '.tool_input.model // "" | tostring')"
  WV_MODEL_TRIM="${model#"${model%%[![:space:]]*}"}"
  WV_MODEL_TRIM="${WV_MODEL_TRIM%"${WV_MODEL_TRIM##*[![:space:]]}"}"
  WV_TOOL_USE_ID="$(wv_json '.tool_use_id // "" | tostring')"
  return 0
}

# ---------------------------------------------------------------------------
# 3. tool_response: the tolerant reader (this file's declared interface).
# ---------------------------------------------------------------------------

wv_tool_response_field() {
  # wv_tool_response_field <name> -> the field on stdout. Returns 1 when none
  # of the three steps found it at all (as opposed to finding it present but
  # empty, which is not a shape any of the measured fields ever take).
  #
  #   1. .tool_response.<name>            — tool_response is a JSON object.
  #   2. .tool_response | fromjson? | .<name>
  #                                        — tool_response is a JSON-encoded
  #                                          string that still parses whole.
  #   3. command grep -o '"<name>":"[^"]*"' over the raw text
  #                                        — a string truncated mid-object
  #                                          (Global Constraint 7: command
  #                                          grep, never a bare grep).
  #
  # `[$n]?` (rather than `[$n]`) is what makes step 1 safe when tool_response
  # is itself a string or absent: indexing a non-object with `?` yields
  # empty instead of a jq error, so the fallback chain never needs its own
  # type check.
  local name="$1" val=""

  val="$(printf '%s' "$WV_JSON" | jq -r --arg n "$name" \
    '.tool_response[$n]? // empty' 2>/dev/null)"
  if [ -n "$val" ]; then printf '%s' "$val"; return 0; fi

  val="$(printf '%s' "$WV_JSON" | jq -r --arg n "$name" \
    '(.tool_response | fromjson?)[$n]? // empty' 2>/dev/null)"
  if [ -n "$val" ]; then printf '%s' "$val"; return 0; fi

  local raw
  raw="$(printf '%s' "$WV_JSON" | jq -r \
    '.tool_response | if type == "string" then . else tostring end' 2>/dev/null)"
  if [ -n "$raw" ]; then
    val="$(printf '%s' "$raw" | command grep -o "\"$name\":\"[^\"]*\"" | head -n1)"
    if [ -n "$val" ]; then
      val="${val#*:\"}"
      val="${val%\"}"
      printf '%s' "$val"
      return 0
    fi
  fi
  return 1
}

# ---------------------------------------------------------------------------
# 4. The state write.
# ---------------------------------------------------------------------------

wv_jq_str() {
  # wv_jq_str <value> -> that value as a properly quoted/escaped JSON string
  # literal, for splicing into a jq filter built as text — the same
  # construction lib.sh's wv_block uses for its own state write.
  jq -Rn --arg v "${1:-}" '$v'
}

wv_write_active() {
  # wv_write_active <agent-id> <phase> <role> <requested-model> \
  #   <resolved-model> <tool-use-id> <status> — creates `active` itself when
  # absent (AC-18): jq path assignment auto-vivifies missing intermediate
  # objects, so `.active[$id] = {...}` on a state with no `active` key at
  # all produces one rather than erroring.
  local id="$1" phase="$2" role="$3" reqm="$4" resm="$5" tuid="$6" status="$7"
  local filter
  filter="$(printf '.active[%s] = {phase: %s, role: %s, requested_model: %s, resolved_model: %s, tool_use_id: %s, status: %s}' \
    "$(wv_jq_str "$id")" "$(wv_jq_str "$phase")" "$(wv_jq_str "$role")" \
    "$(wv_jq_str "$reqm")" "$(wv_jq_str "$resm")" "$(wv_jq_str "$tuid")" \
    "$(wv_jq_str "$status")")"
  wv_state_update "$filter"
}

wv_write_pending() {
  # wv_write_pending <phase> <role> — the thin `state.pending[<tool_use_id>]`
  # record (spec section 4's shape) for a launch with no agentId to join on.
  local phase="$1" role="$2"
  local filter
  filter="$(printf '.pending[%s] = {phase: %s, role: %s}' \
    "$(wv_jq_str "$WV_TOOL_USE_ID")" "$(wv_jq_str "$phase")" "$(wv_jq_str "$role")")"
  wv_state_update "$filter"
}

# ---------------------------------------------------------------------------
# 5. Reason detail builders. The shared W-RESOLVE-UNKNOWN template
#    (hooks/reasons.tsv) has one placeholder ("resolved model %s could not
#    be mapped to a tier") and is deliberately reused for all three causes
#    the brief assigns it (spec section 7 and the interfaces above); each
#    builder fills that one slot with a detail that still names the actual
#    problem, so a reader can tell the three apart.
# ---------------------------------------------------------------------------

# THE THREE CAUSES, EACH NAMED. hooks/reasons.tsv's W-RESOLVE-UNKNOWN template
# takes two arguments — the tool_response FIELD that could not be read, and the
# specific fact about it — because one id covers three different causes and a
# single free-text slot made the sentence wrong for two of them: it said
# "resolved model %s could not be mapped to a tier" when the actual finding was
# that the launch had no status field, or no agentId, and the resolved model was
# never in question (Task 13, reason corpus; carried from the Task 7 review).
# Each helper below returns only the FACT; the field name is passed beside it.

wv_ru_detail_status() {
  local status="${1:-}"
  if [ -z "$status" ]; then
    printf 'the field is absent, so this is not a recognised launch'
  else
    printf 'it is "%s", neither async_launched nor completed' "$status"
  fi
}

wv_ru_detail_agentid() {
  printf 'the field is absent, so tool_use_id %s cannot be joined to a SubagentStop; recorded under state.pending instead' "$WV_TOOL_USE_ID"
}

wv_ru_detail_model() {
  local raw="${1:-}"
  if [ -z "$raw" ]; then
    printf 'the field is absent'
  else
    printf 'it is "%s", which matches no tier token in hooks/models.tsv' "$raw"
  fi
}

# ---------------------------------------------------------------------------
# 6. Main.
# ---------------------------------------------------------------------------

wv_main() {
  wv_parse_stdin || return 0
  # Wired to PostToolUse(Agent) only. Any other event or tool has not been
  # measured by this script (Global Constraint 3).
  [ "$WV_EVENT" = "PostToolUse" ] || return 0
  [ "$WV_TOOL" = "Agent" ] || return 0
  wv_project_root || return 0
  wv_state_read || return 0

  wv_read_launch_input
  wv_tag_parse_light "$WV_DESC" "$WV_PROMPT_TEXT"

  local phase="" role=""
  case "$WV_MODE" in
    full|demo)
      if [ "$WV_TAG_OK" = "1" ] && [ "$WV_TAG_WAVE" = "$WV_WAVE" ]; then
        phase="$WV_TAG_PHASE"
        role="$WV_TAG_ROLE"
      else
        # No acceptable tag for this wave. Under enforce:"block" pre-agent.sh
        # already denied this dispatch outright, so it never actually
        # launched: recording it would invent a phantom entry (AC-199).
        # Under enforce:"warn" the dispatch WAS allowed through, so its
        # spend still has to be ledgered at stop (AC-200).
        [ "$WV_ENFORCE" = "block" ] && return 0
        phase="untagged"
        role="unknown"
      fi
      ;;
    solo)
      if [ "$WV_TAG_OK" = "1" ]; then
        phase="$WV_TAG_PHASE"
        role="$WV_TAG_ROLE"
      else
        phase="SOLO"
        role="unknown"
      fi
      ;;
    *)
      # An unrecognised mode enforces nothing (pre-agent.sh's own
      # precedent); still leave a joinable record rather than silently
      # dropping the dispatch.
      if [ "$WV_TAG_OK" = "1" ]; then
        phase="$WV_TAG_PHASE"
        role="$WV_TAG_ROLE"
      else
        phase="SOLO"
        role="unknown"
      fi
      ;;
  esac

  local status
  status="$(wv_tool_response_field status)"
  case "$status" in
    async_launched|completed) : ;;
    *)
      wv_warn W-RESOLVE-UNKNOWN status "$(wv_ru_detail_status "$status")"
      return 0
      ;;
  esac

  local agent_id
  agent_id="$(wv_tool_response_field agentId)"
  if [ -z "$agent_id" ]; then
    wv_write_pending "$phase" "$role"
    wv_warn W-RESOLVE-UNKNOWN agentId "$(wv_ru_detail_agentid)"
    return 0
  fi

  local resolved_raw resolved_tier
  resolved_raw="$(wv_tool_response_field resolvedModel)"
  if [ -z "$resolved_raw" ]; then
    resolved_tier="unknown"
  else
    resolved_tier="$(wv_tier "$resolved_raw")"
  fi

  local requested_tier=""
  if [ -n "$WV_MODEL_TRIM" ] && [ "$WV_MODEL_TRIM" != "inherit" ]; then
    requested_tier="$(wv_tier "$WV_MODEL_TRIM")"
  fi

  local status_field="launched" resolved_model_val="$resolved_raw"
  if [ "$resolved_tier" = "unknown" ]; then
    resolved_model_val="unknown"
    wv_warn W-RESOLVE-UNKNOWN resolvedModel "$(wv_ru_detail_model "$resolved_raw")"
  elif [ -n "$requested_tier" ] && [ "$requested_tier" != "unknown" ] \
    && [ "$resolved_tier" -lt "$requested_tier" ]; then
    status_field="downgraded"
    wv_warn W-DOWNGRADE "$WV_MODEL_TRIM" "$resolved_raw"
  elif [ -z "$requested_tier" ]; then
    # NO REQUESTED TIER TO COMPARE AGAINST, and that is worth saying out loud.
    # `requested_tier` is empty only when the dispatch named no model at all or
    # named "inherit" — both of which pre-agent.sh DENIES, so this branch is
    # reachable only under enforce="warn", where that deny became a warning and
    # the dispatch went through anyway. The downgrade check is then not "passed",
    # it is UNPERFORMED: nothing knows what tier this agent was supposed to run
    # on, so nothing can notice it ran lower. Silence here reads in the ledger
    # exactly like a dispatch that was checked and found correct, which is the
    # one thing this record must not do.
    wv_warn W-STATE "the launch of agent $agent_id resolved to \"$resolved_raw\" but the dispatch requested \"${WV_MODEL_TRIM:-<no model>}\", so there was no requested tier to compare it against and no downgrade check was performed; this dispatch was allowed by enforce=warn"
  fi

  wv_write_active "$agent_id" "$phase" "$role" "$WV_MODEL_TRIM" \
    "$resolved_model_val" "$WV_TOOL_USE_ID" "$status_field"
  return 0
}

wv_main
# The one emit: PostToolUse's additionalContext channel, or nothing.
wv_emit_flush
exit 0
