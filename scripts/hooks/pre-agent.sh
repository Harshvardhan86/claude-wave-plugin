#!/usr/bin/env bash
# scripts/hooks/pre-agent.sh — the PreToolUse hook on the `Agent` tool.
#
# Part 1 (this file, today): dispatch identity. Is this dispatch allowed to
# exist at all, is it labelled, and is it routed to a model the phase table
# accepts? Part 2 adds ordering, conditions, dispatch-time gates, the round
# ceiling and the budget gate at the marked extension point, in the same
# evaluation order.
#
# Every other tool is a silent no-op: the hook is wired to `Agent` only, and a
# script that is handed something else has measured nothing.
#
# Evaluation order — the precedence order of `hooks/reasons.tsv`, first deny
# wins, and exactly one JSON object reaches stdout per invocation (the
# library's WV_EMITTED guard enforces the second half of that):
#
#   state (W-STATE, in the library)
#   -> nested dispatch      W-NESTED
#   -> fork dispatch        W-FORK
#   -> tag                  W-TAG            (+ the W-DESC length warning)
#   -> mode                 W-MODE
#   -> role                 W-ROLE
#   -> model presence       W-MODEL-MISSING
#   -> tier                 W-TIER           (or the W-MODEL-UNKNOWN warning)
#   -> [part 2: W-SCOPE, W-COND, W-ORDER, the gates, W-ROUND, W-BUDGET]
#
# Solo mode is deliberately thin (spec section 6, "Solo mode"): `phases.tsv` is
# not consulted at all, the tag is recorded but not judged, nesting and forks
# are allowed, and the only rule kept is section 7's "every dispatch names its
# model". Any mode this version does not recognise is treated the same way — a
# hook must not invent enforcement for a wave it cannot read.
#
# Reasons are rendered from `hooks/reasons.tsv` through `wv_render`, never
# built here; this file only supplies the arguments each template declares.

set -u

# Builtins only, and before the library is sourced: `dirname` is an external
# binary and the library's own tool guard must be the first thing that runs.
WV_HOOK_DIR="$(cd "${BASH_SOURCE[0]%/*}" 2>/dev/null && pwd)"
# shellcheck source=scripts/hooks/lib.sh
source "$WV_HOOK_DIR/lib.sh"

WV_PHASES_TSV="$WV_PLUGIN_DIR/hooks/phases.tsv"

# ---------------------------------------------------------------------------
# 1. Everything this script exports, initialised before anything reads it.
# ---------------------------------------------------------------------------

WV_HAS_TOOL_INPUT=0
WV_HAS_MODEL=0
WV_DESC=""
WV_PROMPT_TEXT=""
WV_SUBAGENT=""
WV_MODEL=""          # exactly as sent
WV_MODEL_TRIM=""     # whitespace-trimmed, which is what the rules judge

WV_TAG_WAVE=""       # the tag's <wave>, byte for byte, never coerced
WV_TAG_PHASE=""
WV_TAG_ROLE=""
WV_TAG_OK=0
WV_TAG_DETAIL=""     # the diagnosis carried in the W-TAG reason

# Every column of hooks/phases.tsv, for the row wv_phase_row last read. Part 2
# reads `when`, `condition`, `after`, `fanout`, `artifact`, `marker` and
# `findings`; part 1 sets them because one reader of this file is cheaper to
# reason about than two, and a half-read row is how a column shift hides.
WV_ROW_CODE=""
WV_ROW_MODES=""
WV_ROW_WHEN=""
WV_ROW_CONDITION=""
WV_ROW_AFTER=""
WV_ROW_FANOUT=""
WV_ROW_LEAD=""
WV_ROW_EXECUTOR=""
WV_ROW_REVIEWER=""
WV_ROW_ARTIFACT=""
WV_ROW_MARKER=""
WV_ROW_FINDINGS=""

# The grammar (spec section 5): anchored at byte 0, case-sensitive, exactly one
# U+0020 between fields. `[^] ]+` is the portable spelling of the spec's
# `[^ \]]+` — inside a bracket expression a backslash is literal, so spelling it
# `[^ \]]` would also exclude a backslash from a wave id.
WV_TAG_RE='^\[W:([^] ]+) P:([A-Z0-9-]+) R:(lead|executor|reviewer|scanner|writer)\]'
# The same shape with any role, used only to diagnose a bad role enum.
WV_TAG_ROLE_SHAPED_RE='^\[W:([^] ]+) P:([A-Z0-9-]+) R:([^]]*)\]'
# A well-formed tag that is not at byte 0, used only to quote what precedes it.
WV_TAG_LATE_RE='^(.+)\[W:[^] ]+ P:[A-Z0-9-]+ R:(lead|executor|reviewer|scanner|writer)\]'

# ---------------------------------------------------------------------------
# 2. stdin: the four `tool_input` fields the probe recorded, plus the two
#    key-presence facts the rules need (a key that is absent is not the same
#    thing as a key whose value is empty).
# ---------------------------------------------------------------------------

wv_read_tool_input() {
  # Returns 1 when there is no `tool_input` object to judge. A missing field is
  # never a violation, so that is a silent allow, not a deny.
  WV_HAS_TOOL_INPUT=0
  WV_HAS_MODEL=0
  WV_DESC=""
  WV_PROMPT_TEXT=""
  WV_SUBAGENT=""
  WV_MODEL=""
  WV_MODEL_TRIM=""

  local flags
  flags="$(wv_json '
      if (.tool_input | type) == "object" then
        [ "1", (if (.tool_input | has("model")) then "1" else "0" end) ] | join("\u001f")
      else empty end')"
  [ -n "$flags" ] || return 1
  IFS=$'\x1f' read -r WV_HAS_TOOL_INPUT WV_HAS_MODEL <<<"$flags"

  # One jq call per field, deliberately: a description may contain newlines
  # (and one of the ACs sends exactly that), and a single US-joined line read
  # with `read` would silently truncate at the first of them.
  WV_DESC="$(wv_json '.tool_input.description // "" | tostring')"
  WV_PROMPT_TEXT="$(wv_json '.tool_input.prompt // "" | tostring')"
  WV_SUBAGENT="$(wv_json '.tool_input.subagent_type // "" | tostring')"
  WV_MODEL="$(wv_json '.tool_input.model // "" | tostring')"

  WV_MODEL_TRIM="${WV_MODEL#"${WV_MODEL%%[![:space:]]*}"}"
  WV_MODEL_TRIM="${WV_MODEL_TRIM%"${WV_MODEL_TRIM##*[![:space:]]}"}"
  return 0
}

# ---------------------------------------------------------------------------
# 3. The tag.
# ---------------------------------------------------------------------------

wv_tag_parse() {
  # wv_tag_parse <description> <prompt> -> WV_TAG_WAVE / WV_TAG_PHASE /
  # WV_TAG_ROLE, plus WV_TAG_OK and WV_TAG_DETAIL (the diagnosis the W-TAG
  # reason carries when the tag is not acceptable).
  #
  # Accepted at byte 0 of the description, or as the prompt's first line.
  # Everything here is bash pattern matching on the raw bytes: hook input is
  # data, so it is never eval'd, never a format string and never a shell word.
  local desc="${1:-}" prompt="${2:-}"
  WV_TAG_WAVE=""
  WV_TAG_PHASE=""
  WV_TAG_ROLE=""
  WV_TAG_OK=0
  WV_TAG_DETAIL=""

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

  # No acceptable tag. Diagnose it, most specific first, so the reason tells
  # the orchestrator what to change rather than only restating the grammar.
  if [ -z "$desc" ] && [ -z "$prompt" ]; then
    WV_TAG_DETAIL="no description was sent, and there is no prompt to read a tag from either"
    return 1
  fi

  for src in description prompt; do
    if [ "$src" = "description" ]; then cand="$desc"; else cand="$first_line"; fi
    [ -n "$cand" ] || continue
    if [[ "$cand" =~ $WV_TAG_ROLE_SHAPED_RE ]]; then
      WV_TAG_DETAIL="R:${BASH_REMATCH[3]} is not one of the five roles; hooks/roles.tsv maps the framework role names onto them"
      return 1
    fi
    if [[ "$cand" =~ $WV_TAG_LATE_RE ]]; then
      WV_TAG_DETAIL="the tag must start at byte 0 of the $src, and \"${BASH_REMATCH[1]}\" precedes it"
      return 1
    fi
    case "$cand" in
      *'[W:'*)
        WV_TAG_DETAIL="the $src reads \"$(wv_excerpt "$cand")\", which does not match the grammar"
        return 1
        ;;
    esac
  done

  case "$prompt" in
    *'[W:'*)
      WV_TAG_DETAIL="the prompt carries a tag on a later line, and only its first line is read"
      return 1
      ;;
  esac

  if [ -z "$desc" ]; then
    WV_TAG_DETAIL="no description was sent, and the prompt's first line carries no tag"
  fi
  return 1
}

wv_excerpt() {
  # wv_excerpt <text> -> its first line, capped, for quoting inside a reason.
  local text="${1:-}"
  text="${text%%$'\n'*}"
  if [ "${#text}" -gt 60 ]; then
    printf '%s...' "${text:0:60}"
  else
    printf '%s' "$text"
  fi
}

wv_tag_arg() {
  # The one argument hooks/reasons.tsv's W-TAG template declares: the active
  # wave id, plus the diagnosis when there is one. The template has a single
  # placeholder, in the wave slot of the illustrated tag, so a diagnosis has
  # nowhere else to go.
  if [ -n "$WV_TAG_DETAIL" ]; then
    printf '%s (%s)' "$WV_WAVE" "$WV_TAG_DETAIL"
  else
    printf '%s' "$WV_WAVE"
  fi
}

# ---------------------------------------------------------------------------
# 4. The phase table.
# ---------------------------------------------------------------------------

wv_phase_row() {
  # wv_phase_row <code> -> sets WV_ROW_* for every column of that row.
  # Returns 1 when the code is not a row, which the caller reports as W-TAG.
  local want="$1" line rec
  WV_ROW_CODE=""
  WV_ROW_MODES=""
  WV_ROW_WHEN=""
  WV_ROW_CONDITION=""
  WV_ROW_AFTER=""
  WV_ROW_FANOUT=""
  WV_ROW_LEAD=""
  WV_ROW_EXECUTOR=""
  WV_ROW_REVIEWER=""
  WV_ROW_ARTIFACT=""
  WV_ROW_MARKER=""
  WV_ROW_FINDINGS=""
  [ -f "$WV_PHASES_TSV" ] || return 1

  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*|"code"$'\t'*) continue ;; esac
    # Tabs are re-delimited to US first. `IFS=$'\t' read` would collapse two
    # adjacent tabs into one delimiter (tab is IFS whitespace), which silently
    # shifts every column after an empty cell — and `after` is empty on the
    # first row of this very file.
    rec="${line//$'\t'/$'\x1f'}"
    IFS=$'\x1f' read -r WV_ROW_CODE WV_ROW_MODES WV_ROW_WHEN WV_ROW_CONDITION \
      WV_ROW_AFTER WV_ROW_FANOUT WV_ROW_LEAD WV_ROW_EXECUTOR WV_ROW_REVIEWER \
      WV_ROW_ARTIFACT WV_ROW_MARKER WV_ROW_FINDINGS <<<"$rec"
    [ "$WV_ROW_CODE" = "$want" ] && return 0
  done < "$WV_PHASES_TSV"

  WV_ROW_CODE=""
  return 1
}

wv_role_tier() {
  # wv_role_tier <phase-code> <tag-role> -> the row's cell for that role, with
  # `scanner` and `writer` both resolving to the `executor` column (spec
  # section 5). A `-` cell is printed as `-` and returns 1: the phase does not
  # define that role, which the caller reports as W-ROLE.
  #
  # Callers read this through a command substitution, so a wv_phase_row call
  # made here would not survive into the caller's WV_ROW_*. The caller reads
  # the row first (it has to, to reject an unknown phase code) and this
  # function only re-reads it when it is asked about a different row.
  local code="$1" role="$2" cell=""
  if [ "$WV_ROW_CODE" != "$code" ]; then
    wv_phase_row "$code" || { printf '-'; return 1; }
  fi
  case "$role" in
    lead) cell="$WV_ROW_LEAD" ;;
    executor|scanner|writer) cell="$WV_ROW_EXECUTOR" ;;
    reviewer) cell="$WV_ROW_REVIEWER" ;;
    *) printf '-'; return 1 ;;
  esac
  [ -n "$cell" ] || cell="-"
  printf '%s' "$cell"
  [ "$cell" != "-" ]
}

wv_row_roles() {
  # The roles the current row defines, with the executor column's aliases, for
  # the W-ROLE reason: "lead, executor (aliases: scanner, writer), reviewer".
  local out=""
  if [ "$WV_ROW_LEAD" != "-" ] && [ -n "$WV_ROW_LEAD" ]; then
    out="lead"
  fi
  if [ "$WV_ROW_EXECUTOR" != "-" ] && [ -n "$WV_ROW_EXECUTOR" ]; then
    out="${out:+$out, }executor (aliases: scanner, writer)"
  fi
  if [ "$WV_ROW_REVIEWER" != "-" ] && [ -n "$WV_ROW_REVIEWER" ]; then
    out="${out:+$out, }reviewer"
  fi
  [ -n "$out" ] || out="no roles at all"
  printf '%s' "$out"
  return 0
}

wv_mode_allows() {
  # True when the row's `modes` column lists the wave's mode.
  case ",$WV_ROW_MODES," in
    *",$WV_MODE,"*) return 0 ;;
  esac
  return 1
}

# ---------------------------------------------------------------------------
# 5. The model.
# ---------------------------------------------------------------------------

wv_model_named() {
  # True when the dispatch actually names a model. An absent key, an empty
  # string, whitespace, and the literal `inherit` are all "no model": every
  # dispatch names its model (spec section 7).
  [ "$WV_HAS_MODEL" = "1" ] || return 1
  [ -n "$WV_MODEL_TRIM" ] || return 1
  [ "$WV_MODEL_TRIM" != "inherit" ] || return 1
  return 0
}

wv_model_missing_detail() {
  # wv_model_missing_detail <minimum-clause> -> the third argument of the
  # W-MODEL-MISSING template, which is where the minimum goes.
  local minimum="$1"
  if [ "$WV_HAS_MODEL" = "1" ] && [ "$WV_MODEL_TRIM" = "inherit" ]; then
    printf '%s; the dispatch said model: "inherit", which names no model' "$minimum"
  else
    printf '%s' "$minimum"
  fi
}

wv_model_unknown_detail() {
  # wv_model_unknown_detail <model> -> the one argument of the
  # W-MODEL-UNKNOWN template: the model, and why the map could not read it.
  # The DECISION stays with the library's wv_tier; this only explains it.
  local raw="${1:-}" lowered tokens token rank matches="" declared=""
  lowered="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')"
  tokens="$(printf '%s' "$lowered" | tr -c '[:alnum:]' ' ')"
  for token in $tokens; do
    rank="$(wv_tier_rank "$token")" || continue
    if [ "$rank" = "unknown" ]; then
      declared="$token"
      continue
    fi
    case " $matches " in
      *" $token "*) : ;;
      *) matches="${matches:+$matches }$token" ;;
    esac
  done
  if [ -n "$declared" ]; then
    printf '%s (hooks/models.tsv declares the token %s unknown: its execution model is not the substring)' "$raw" "$declared"
  elif [ -z "$matches" ]; then
    printf '%s (it matches no tier token)' "$raw"
  else
    printf '%s (ambiguous: it matches %s)' "$raw" "${matches// / and }"
  fi
}

# ---------------------------------------------------------------------------
# 6. The rules, in the one evaluation order.
# ---------------------------------------------------------------------------

wv_solo_rules() {
  # Solo keeps exactly one dispatch rule: the model must be named. The tag is
  # never judged and phases.tsv is not opened at all, so there is no tier to
  # compare against and no phase or role to reject. The parse here is read for
  # one thing only — the phase and role the reason names, `SOLO` and `any role`
  # when there is no tag. Recording the tag is post-agent.sh's job; this hook
  # writes no state.
  wv_tag_parse "$WV_DESC" "$WV_PROMPT_TEXT"
  if ! wv_model_named; then
    local phase="${WV_TAG_PHASE:-SOLO}" role="${WV_TAG_ROLE:-any role}"
    wv_deny W-MODEL-MISSING "$phase" "$role" \
      "$(wv_model_missing_detail 'none, because solo mode does not consult hooks/phases.tsv')"
  fi
  return 0
}

wv_tier_rule() {
  # wv_tier_rule <phase> <tag-role> <required-tier-name> — the W-TIER
  # comparison, or the W-MODEL-UNKNOWN warning when the map cannot read the
  # model. Returns 1 when it denied.
  local phase="$1" role="$2" need_name="$3"
  local requested need_rank
  requested="$(wv_tier "$WV_MODEL_TRIM")"
  if [ "$requested" = "unknown" ]; then
    # A model the map cannot read is a gap in our table, never a NO-GO.
    wv_warn W-MODEL-UNKNOWN "$(wv_model_unknown_detail "$WV_MODEL_TRIM")"
    return 0
  fi
  need_rank="$(wv_tier_rank "$need_name")" || need_rank=""
  case "$need_rank" in
    1|2|3|4) ;;
    *)
      # Our own data files disagree with each other. Fail open, loudly: a hook
      # that cannot rank the requirement has not measured the dispatch.
      wv_warn W-STATE "hooks/phases.tsv gives $phase/$role the tier name \"$need_name\", which hooks/models.tsv does not rank, so the tier comparison was skipped"
      return 0
      ;;
  esac
  if [ "$requested" -lt "$need_rank" ]; then
    wv_deny W-TIER "$WV_MODEL_TRIM" "$requested" "$phase" "$role" "$need_name" "$need_rank"
    return 1
  fi
  return 0
}

wv_main() {
  wv_parse_stdin || return 0
  # Wired to Agent only; anything else has not been measured and says nothing.
  [ "$WV_TOOL" = "Agent" ] || return 0
  wv_project_root || return 0
  wv_state_read || return 0
  wv_read_tool_input || return 0

  case "$WV_MODE" in
    full|demo) : ;;
    *) wv_solo_rules; return 0 ;;
  esac

  # 1. Nested dispatch (spec section 8.4): the orchestrator is the single
  #    dispatcher, and a correct tag does not rescue a nested call.
  if [ -n "$WV_AGENT_ID" ]; then
    wv_deny W-NESTED "$WV_AGENT_ID"
    return 0
  fi

  # 2. Fork (spec section 7): inherits the whole orchestrator context and
  #    cannot be model-routed at all.
  if [ "$WV_SUBAGENT" = "fork" ]; then
    wv_deny W-FORK
    return 0
  fi

  # 3. The description-length warning is queued before any deny, so a deny
  #    carries it as additionalContext instead of losing it.
  if [ "${#WV_DESC}" -gt 120 ]; then
    wv_warn W-DESC "${#WV_DESC}"
  fi

  # 4. The tag: present and well formed, for this wave, naming a real phase.
  wv_tag_parse "$WV_DESC" "$WV_PROMPT_TEXT"
  if [ "$WV_TAG_OK" != "1" ]; then
    wv_deny W-TAG "$(wv_tag_arg)"
    return 0
  fi
  if [ "$WV_TAG_WAVE" != "$WV_WAVE" ]; then
    # Byte comparison, never numeric: `01` is not `1`.
    WV_TAG_DETAIL="the dispatch said W:$WV_TAG_WAVE"
    wv_deny W-TAG "$(wv_tag_arg)"
    return 0
  fi
  if ! wv_phase_row "$WV_TAG_PHASE"; then
    WV_TAG_DETAIL="P:$WV_TAG_PHASE is not a row in hooks/phases.tsv"
    wv_deny W-TAG "$(wv_tag_arg)"
    return 0
  fi
  # The library records warnings against a phase; from here we know it.
  WV_PHASE="$WV_TAG_PHASE"

  # 5. Mode: the row has to run in this wave's mode.
  if ! wv_mode_allows; then
    wv_deny W-MODE "$WV_TAG_PHASE" "${WV_ROW_MODES//,/ or }" "$WV_MODE"
    return 0
  fi

  # 6. Role: the row has to define the tag's role (scanner and writer resolve
  #    to the executor column).
  local need_name
  need_name="$(wv_role_tier "$WV_TAG_PHASE" "$WV_TAG_ROLE")"
  if [ "$need_name" = "-" ]; then
    wv_deny W-ROLE "$WV_TAG_ROLE" "$WV_TAG_PHASE" "$(wv_row_roles)"
    return 0
  fi

  # 7. Model presence: every dispatch names its model.
  if ! wv_model_named; then
    wv_deny W-MODEL-MISSING "$WV_TAG_PHASE" "$WV_TAG_ROLE" \
      "$(wv_model_missing_detail "$need_name")"
    return 0
  fi

  # 8. Tier: at least the row's cell for that role; higher always passes.
  wv_tier_rule "$WV_TAG_PHASE" "$WV_TAG_ROLE" "$need_name" || return 0

  # --- part 2 extends here, in this same order: W-SCOPE, W-COND, W-ORDER,
  # --- W-ARTIFACT / W-MARKER, W-DR-OPEN, W-VISUAL, W-BF-APPROVAL, W-ROUND,
  # --- W-PASTE, W-BUDGET, W-PROMPT.
  return 0
}

wv_main
# The one emit: a deny has already written its object (and carried the queued
# warnings with it); this is how a warning-only invocation reaches stdout.
wv_emit_flush
exit 0
