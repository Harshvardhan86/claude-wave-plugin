#!/usr/bin/env bash
# scripts/hooks/pre-agent.sh — the PreToolUse hook on the `Agent` tool.
#
# Part 1: dispatch identity. Is this dispatch allowed to exist at all, is it
# labelled, and is it routed to a model the phase table accepts?
#
# Part 2: is it allowed NOW. The phase order (`after`), the conditional phases
# (ui / behaviour_change / cr / findings), the scope gate, the three gates that
# read an artifact at dispatch time, the round ceiling, the per-phase budget and
# the prompt-size caps. Part 2 decides nothing about identity and part 1 decides
# nothing about timing, which is why they read as one list rather than two.
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
#   -> [the W-PROMPT size warning is queued here, before any part-2 deny]
#   -> scope                 W-SCOPE          (TDE-RED only)
#   -> own condition         W-COND           (or W-ARTIFACT / W-MARKER when the
#                                             condition cannot be read, or
#                                             W-SCOPE when it rests on a flag
#                                             nobody has answered yet)
#   -> order                 W-ORDER          (or the same three)
#   -> DR open items         W-DR-OPEN        (TDE-RED, and only when DR ran)
#   -> visual approval       W-VISUAL         (ui true, ordered after TDE-GREEN)
#   -> bug-fix approval      W-BF-APPROVAL    (BF-* only)
#   -> round ceiling         W-ROUND
#   -> pasted block          W-PASTE
#   -> budget                W-BUDGET         (deny over 2x, warn over 1x)
#
# Solo mode is deliberately thin (spec section 6, "Solo mode"): `phases.tsv` is
# not consulted at all, the tag is recorded but not judged, nesting and forks
# are allowed, and the only rule kept is section 7's "every dispatch names its
# model". Any mode this version does not recognise is treated the same way — a
# hook must not invent enforcement for a wave it cannot read.
#
# Reasons are rendered from `hooks/reasons.tsv` through `wv_render`, never
# built here; this file only supplies the arguments each template declares.
#
# Every one of those arguments goes through `wv_rule_deny` / `wv_rule_warn`,
# which rewrite the two characters `W-` to `W_` in each argument. A reason must
# carry exactly one `W-` token, because that token is how a consumer reads
# which rule fired (`assert_single_rule_token` extracts it with
# `W-[A-Z0-9-]+`), and several reasons quote the dispatch back to the caller:
# a description of `[W:1 P:AC R:lead W-FORK] bad`, a model of `W-TIER`, an
# `agent_id` of `W-FORK` would otherwise each put a second token in the reason
# and a consumer would read the wrong rule off it. `W_FORK` is visibly the
# caller's own text, still names what was wrong, and cannot be mistaken for a
# rule id. The rewrite happens at the emit choke point rather than at the eight
# places that quote input (the five tag diagnoses, `agent_id`, and the model in
# both W-TIER and W-MODEL-UNKNOWN), so a rule added by part 2 cannot forget it.
#
# Part 2 reads much more than part 1 did — other rows of `hooks/phases.tsv`,
# `hooks/budgets.tsv`, the state's `phases` and `rounds` maps, and up to five
# files under `.wave/`. Two properties hold across all of it. Every reader is
# read-only with respect to WV_ROW_*, so asking about a predecessor can never
# change which row the caller is judging. And every path that could not measure
# what it wanted ALLOWS: an unreadable ledger, a phase with no budget row, a
# gating scan that returned no count, and a condition keyword this version does
# not know each warn at most, because a hook that measured nothing has not
# measured a violation. The one deliberate exception is a findings file that a
# phase claims to have produced and did not: that is a W-ARTIFACT deny, because
# there the state and the disk disagree, and guessing either way is worse than
# stopping.

set -u

# Builtins only, and before the library is sourced: `dirname` is an external
# binary and the library's own tool guard must be the first thing that runs.
WV_HOOK_DIR="$(cd "${BASH_SOURCE[0]%/*}" 2>/dev/null && pwd)"
# shellcheck source=scripts/hooks/lib.sh
source "$WV_HOOK_DIR/lib.sh"

WV_PHASES_TSV="$WV_PLUGIN_DIR/hooks/phases.tsv"
WV_BUDGETS_TSV="$WV_PLUGIN_DIR/hooks/budgets.tsv"

# ---------------------------------------------------------------------------
# 1. Everything this script exports, initialised before anything reads it.
# ---------------------------------------------------------------------------

WV_HAS_TOOL_INPUT=0
WV_HAS_MODEL=0
WV_DESC=""
WV_PROMPT_TEXT=""
WV_PROMPT_TYPE=""   # the JSON type the client sent: string, null, array, ...
WV_PROMPT_LEN=0     # its length in Unicode scalar values (jq counts codepoints)
WV_PROMPT_BYTES=0   # its length in bytes, which is what the paste scan needs
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
  WV_PROMPT_TYPE=""
  WV_PROMPT_LEN=0
  WV_PROMPT_BYTES=0
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

  # The prompt's TYPE and its length are read from the JSON, not from the
  # stringified copy above: `${#WV_PROMPT_TEXT}` counts whatever the ambient
  # locale says a character is, while jq's `length` on a string is always
  # Unicode scalar values after unescaping, which is the unit spec section 9
  # names. The type matters because a client that sends a non-string there has
  # given the size rules nothing to measure.
  local pmeta
  pmeta="$(wv_json '
      (.tool_input.prompt) as $p
      | [ ($p | type),
          (if ($p | type) == "string" then ($p | length) else 0 end),
          (if ($p | type) == "string" then ($p | utf8bytelength) else 0 end) ]
      | map(tostring) | join("\u001f")')"
  if [ -n "$pmeta" ]; then
    IFS=$'\x1f' read -r WV_PROMPT_TYPE WV_PROMPT_LEN WV_PROMPT_BYTES <<<"$pmeta"
  fi
  case "$WV_PROMPT_LEN" in ''|*[!0-9]*) WV_PROMPT_LEN=0 ;; esac
  case "$WV_PROMPT_BYTES" in ''|*[!0-9]*) WV_PROMPT_BYTES=0 ;; esac

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
  # READ-ONLY: it never touches WV_ROW_*. It used to call wv_phase_row when
  # asked about a row other than the one already loaded, which silently moved
  # the caller's WV_ROW_* — invisible while the only caller asked about the
  # dispatched phase, and a wrong-row bug the moment anything asked about a
  # second row. It reads the other row through wv_row_line instead, which is
  # also why every part-2 reader below is built the same way.
  local code="$1" role="$2" cell="" rec
  local lead="$WV_ROW_LEAD" exe="$WV_ROW_EXECUTOR" rev="$WV_ROW_REVIEWER"
  if [ "$WV_ROW_CODE" != "$code" ]; then
    rec="$(wv_row_line "$code")" || { printf '-'; return 1; }
    local -a cells=()
    IFS=$'\x1f' read -r -a cells <<<"$rec"
    lead="${cells[6]:-}"
    exe="${cells[7]:-}"
    rev="${cells[8]:-}"
  fi
  case "$role" in
    lead) cell="$lead" ;;
    executor|scanner|writer) cell="$exe" ;;
    reviewer) cell="$rev" ;;
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
# 5b. Part 2's reads: the phase table by column, the state's phase and round
#     maps, the budget table, and the two gating scans that need a count.
#
# Every reader here is READ-ONLY with respect to WV_ROW_*. Part 2 asks about
# rows other than the dispatched one many times per invocation — a
# predecessor's condition, and the condition of the row that predecessor waits
# on — and a reader that moved WV_ROW_* would leave the caller judging the
# wrong row. wv_row_line re-reads the file instead; it is 27 lines.
# ---------------------------------------------------------------------------

WV_COL_MODES=2
WV_COL_WHEN=3
WV_COL_CONDITION=4
WV_COL_AFTER=5
WV_COL_FANOUT=6

# Files bigger than this are not searched for a pasted block. A cap is needed
# because the search reads the file; 256 KiB is far above every artifact the
# framework writes and is recorded here rather than in prose.
WV_PASTE_FILE_CAP=262144

wv_row_line() {
  # wv_row_line <code> -> the row's twelve cells joined with US on stdout.
  # Returns 1 when <code> is not a row. See wv_phase_row for why tabs are
  # re-delimited to US rather than read with IFS=$'\t'.
  local want="$1" line rec code
  [ -f "$WV_PHASES_TSV" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*|"code"$'\t'*) continue ;; esac
    rec="${line//$'\t'/$'\x1f'}"
    code="${rec%%$'\x1f'*}"
    if [ "$code" = "$want" ]; then
      printf '%s' "$rec"
      return 0
    fi
  done < "$WV_PHASES_TSV"
  return 1
}

wv_row_get() {
  # wv_row_get <code> <1-based column> -> that cell, which may legitimately be
  # empty (`after` is empty on the AC and AD rows). Returns 1 only when the
  # code is not a row at all, so a caller can tell "no such phase" from "no
  # predecessors".
  local rec
  rec="$(wv_row_line "$1")" || return 1
  local -a cells=()
  IFS=$'\x1f' read -r -a cells <<<"$rec"
  printf '%s' "${cells[$(($2 - 1))]:-}"
  return 0
}

wv_state_phase_status() {
  # wv_state_phase_status <code> -> state.phases[<code>].status, or "" when the
  # key, the map or the whole `phases` object is absent. A missing `phases` key
  # reads as {} — never as "everything done", and never as a crash.
  [ -n "$WV_STATE" ] || return 0
  printf '%s' "$WV_STATE" | jq -r --arg c "$1" \
    'try ((.phases // {})[$c].status // "") catch ""' 2>/dev/null
  return 0
}

wv_rounds_count() {
  # wv_rounds_count <"PHASE/role"> -> the recorded round count, 0 when absent
  # or not a number. pre-agent.sh only ever READS this key.
  [ -n "$WV_STATE" ] || { printf '0'; return 0; }
  local n
  n="$(printf '%s' "$WV_STATE" | jq -r --arg k "$1" \
    'try (((.rounds // {})[$k] // 0) | if type == "number" then floor else 0 end) catch 0' 2>/dev/null)"
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  printf '%s' "$n"
  return 0
}

wv_budget_value() {
  # wv_budget_value <code> -> the row's output-token budget from
  # hooks/budgets.tsv. Returns 1 when the phase has no row or a non-numeric
  # one, which every caller treats as "unbudgeted, fail open".
  local want="$1" code val
  [ -f "$WV_BUDGETS_TSV" ] || return 1
  while IFS=$'\t' read -r code val; do
    case "$code" in ''|'#'*|code) continue ;; esac
    if [ "$code" = "$want" ]; then
      case "$val" in ''|*[!0-9]*) return 1 ;; esac
      printf '%s' "$val"
      return 0
    fi
  done < "$WV_BUDGETS_TSV"
  return 1
}

wv_scan_count_text() {
  # wv_scan_count_text <text> <extended-regex> <label> -> the match count.
  # wv_scan_count's contract (Global Constraint 7) against a string rather than
  # a file: an ABSENT count is a FAILED scan — it warns, prints nothing and
  # returns 1 — never a clean zero.
  local text="$1" regex="$2" label="$3" count
  count="$(command grep -cE -- "$regex" <<<"$text" 2>/dev/null)"
  case "$count" in
    ''|*[!0-9]*)
      wv_rule_warn W-STATE "the gating scan of $label returned no count, so it did not run and nothing was measured; re-run once the file is readable"
      return 1
      ;;
  esac
  printf '%s' "$count"
  return 0
}

wv_first_line() {
  # wv_first_line <file> -> its first line, for quoting inside a W-MARKER
  # reason. An unreadable file gives the empty string, never an error.
  local l=""
  IFS= read -r l < "$1" 2>/dev/null
  printf '%s' "$l"
  return 0
}

wv_findings_count() {
  # wv_findings_count <file> -> the count on the FIRST `^FINDINGS: [0-9]+$`
  # line, base 10 (so `FINDINGS: 08` is 8, not an octal 0).
  #
  # Returns 1 when the gating scan did not run at all (it has already warned
  # W-STATE, and the caller must fail open), and 2 when the file is present but
  # carries no such line — which is a W-MARKER for the caller to report.
  local file="$1" n line
  n="$(wv_scan_count "$file" '^FINDINGS: [0-9]+$')" || return 1
  [ "$n" != "0" ] || return 2
  line="$(command grep -m1 -E '^FINDINGS: [0-9]+$' "$file" 2>/dev/null)"
  line="${line#FINDINGS: }"
  case "$line" in ''|*[!0-9]*) return 2 ;; esac
  printf '%s' "$((10#$line))"
  return 0
}

# ---------------------------------------------------------------------------
# 5c. Conditions and the skip rule.
# ---------------------------------------------------------------------------

WV_COND_RULE=""            # W-ARTIFACT or W-MARKER when a condition is unreadable
declare -a WV_COND_ARGS=() # that rule's template arguments
WV_COND_PENDING=""         # the scan a `findings:` condition is still waiting on
WV_COND_TEXT=""            # the condition exactly as the table writes it
WV_COND_DETAIL=""          # the remedy clause the W-COND reason carries
WV_PHASE_DONE_WHY=""       # `done`, `mode` or `condition`: which clause answered

wv_unanswered_scope() {
  # wv_unanswered_scope <value> <state-key> [<value> <state-key>]... -> true, with
  # WV_COND_RULE / WV_COND_ARGS set to the W-SCOPE deny, when any of the flags a
  # condition depends on is the string "unknown".
  #
  # "unknown" is UNANSWERED, never false. `wave-init.sh` writes it and every later
  # wave inherits it, so it is the deploy-day value of all three flags — and the
  # difference matters in the reason, not just in the rule id. A `W-COND` on an
  # unanswered flag tells the orchestrator "this wave declares no design review",
  # which is a statement nobody has made; `W-SCOPE` says the question is open and
  # names the one command that closes it. Answered `false` still gives `W-COND`,
  # because then the statement is true.
  #
  # The reason names every unanswered flag of the condition (`ui and
  # behaviour_change` when both are open) and its remedy names the FIRST one, so
  # there is one command to run rather than a choice to make.
  local flags="" first="" value key
  while [ "$#" -ge 2 ]; do
    value="$1"; key="$2"; shift 2
    [ "$value" = "unknown" ] || continue
    flags="${flags:+$flags and }$key"
    if [ -z "$first" ]; then
      # The state key is not always the key scripts/wave-set.sh takes.
      case "$key" in
        behaviour_change) first="behaviour-change" ;;
        cr_enabled) first="cr" ;;
        *) first="$key" ;;
      esac
    fi
  done
  [ -n "$flags" ] || return 1
  WV_COND_RULE=W-SCOPE
  WV_COND_ARGS=("$flags" "$first")
  return 0
}

wv_condition_met() {
  # wv_condition_met <code> — the row's `condition` cell, evaluated against the
  # wave state and, for `findings:<CODE>`, against `.wave/findings/<CODE>.md`.
  #
  # Returns:
  #   0  met: the row runs in this wave.
  #   1  not met: the row is skipped, which every `after` naming it reads as
  #      done (spec section 6's skip rule).
  #   2  cannot be answered here: WV_COND_RULE and WV_COND_ARGS carry the deny.
  #      Either the file the condition reads could not be read (W-ARTIFACT,
  #      W-MARKER) or a flag it depends on is still unanswered (W-SCOPE).
  #      Nothing was measured, so nothing is guessed — and note that this status
  #      propagates through wv_phase_done and the order walk, which is what stops
  #      an unanswered condition from being SKIPPED THROUGH to a successor.
  #   3  pending: a `findings:<CODE>` condition whose scan has not run yet.
  #      WV_COND_PENDING names that scan and the order rule reports IT as the
  #      blocker: "BF-SEA's condition cannot be read" is never the sentence the
  #      orchestrator can act on, "SEA has not run" always is. This is also why
  #      an absent findings file is only a W-ARTIFACT once the scan claims to
  #      be done — before that it is simply the future.
  #
  # Never call this through a command substitution: the status is the answer,
  # but the five globals above are the reason, and a subshell drops them.
  local code="$1" cond src file rel count rc
  WV_COND_RULE=""
  WV_COND_ARGS=()
  WV_COND_PENDING=""
  WV_COND_TEXT=""
  WV_COND_DETAIL=""

  cond="$(wv_row_get "$code" "$WV_COL_CONDITION")" || return 0
  WV_COND_TEXT="$cond"
  case "$cond" in
    ''|always)
      return 0
      ;;
    'ui|behaviour_change')
      [ "$WV_UI" = "true" ] && return 0
      [ "$WV_BC" = "true" ] && return 0
      wv_unanswered_scope "$WV_UI" ui "$WV_BC" behaviour_change && return 2
      WV_COND_DETAIL="state.ui and state.behaviour_change are both false in .wave/state.json, so this wave declares no design review; run \`scripts/wave-set.sh ui true\` or \`scripts/wave-set.sh behaviour-change true\` if that is wrong"
      return 1
      ;;
    cr)
      [ "$WV_CR" = "true" ] && return 0
      wv_unanswered_scope "$WV_CR" cr_enabled && return 2
      WV_COND_DETAIL="state.cr_enabled is false in .wave/state.json; run \`scripts/wave-set.sh cr true\` if this wave does need a code review"
      return 1
      ;;
    findings:*)
      src="${cond#findings:}"
      rel=".wave/findings/$src.md"
      file="$WV_WAVE_DIR/findings/$src.md"
      if [ ! -f "$file" ]; then
        if [ "$(wv_state_phase_status "$src")" = "done" ]; then
          WV_COND_RULE=W-ARTIFACT
          WV_COND_ARGS=("$rel" "$src" "$rel")
          return 2
        fi
        WV_COND_PENDING="$src"
        return 3
      fi
      count="$(wv_findings_count "$file")"
      rc=$?
      case "$rc" in
        1)
          # The scan itself did not run; wv_scan_count has warned. A hook that
          # measured nothing allows, so the condition is treated as met.
          return 0
          ;;
        2)
          WV_COND_RULE=W-MARKER
          WV_COND_ARGS=('^FINDINGS: [0-9]+$' \
            "$rel (first line: \"$(wv_excerpt "$(wv_first_line "$file")")\")")
          return 2
          ;;
      esac
      [ "$count" -ge 1 ] && return 0
      WV_COND_DETAIL="$rel reports FINDINGS: $count, so there is nothing for $code to fix"
      return 1
      ;;
    *)
      # Our own table carries a keyword this version does not know. Fail open,
      # loudly: a hook that cannot read the condition has not measured it.
      wv_rule_warn W-STATE "hooks/phases.tsv gives $code the condition \"$cond\", which this version does not understand, so the condition check was skipped"
      return 0
      ;;
  esac
}

wv_phase_done() {
  # wv_phase_done <code> — 0 when the row counts as done for every `after` that
  # names it: its state row says `done`, OR its `modes` excludes the active
  # mode, OR its `condition` is false. That last clause is the skip rule, and
  # it is what stops a clean scan (`FINDINGS: 0`, so its `BF-*` never runs) and
  # the demo subset from deadlocking the pipeline.
  #
  # The status check comes first, deliberately: a phase the ledger records as
  # done is done whatever its condition now says, so an all-done fixture cannot
  # be made to depend on a findings file that no longer needs to exist.
  #
  # Returns 1 not done, and passes wv_condition_met's 2 (cannot be answered here:
  # W-ARTIFACT / W-MARKER / W-SCOPE) and 3 (pending) through unchanged, along with
  # its globals. A row whose condition is UNANSWERED is therefore neither done nor
  # skipped: the caller denies instead of walking past it.
  #
  # WV_PHASE_DONE_WHY says which of the three clauses answered: `done`, `mode`
  # or `condition`. The order rule needs the distinction, because only a row the
  # state records as done has actually absorbed its own history — a SKIPPED row
  # still has predecessors, and treating it as a full stop would let a wave with
  # cr_enabled false run BC before TDE-GREEN, which is the hole a literal
  # reading of the skip rule leaves open.
  local code="$1" modes
  WV_PHASE_DONE_WHY=""
  if [ "$(wv_state_phase_status "$code")" = "done" ]; then
    WV_PHASE_DONE_WHY="done"
    return 0
  fi
  modes="$(wv_row_get "$code" "$WV_COL_MODES")" || return 1
  case ",$modes," in
    *",$WV_MODE,"*) : ;;
    *) WV_PHASE_DONE_WHY="mode"; return 0 ;;
  esac
  wv_condition_met "$code"
  case "$?" in
    0) return 1 ;;
    1) WV_PHASE_DONE_WHY="condition"; return 0 ;;
    2) return 2 ;;
    *) return 3 ;;
  esac
}

wv_required_because() {
  # wv_required_because <code> -> the clause that says WHY a conditional
  # predecessor is in this wave's predecessor set at all, or nothing for an
  # unconditional row. Without it a W-ORDER naming DR reads as a table quirk
  # rather than as a consequence of an answer the user gave.
  local code="$1" cond
  cond="$(wv_row_get "$code" "$WV_COL_CONDITION")" || return 0
  case "$cond" in
    'ui|behaviour_change')
      if [ "$WV_UI" = "true" ] && [ "$WV_BC" = "true" ]; then
        printf ' (required because state.ui and state.behaviour_change are true)'
      elif [ "$WV_UI" = "true" ]; then
        printf ' (required because state.ui is true)'
      elif [ "$WV_BC" = "true" ]; then
        printf ' (required because state.behaviour_change is true)'
      fi
      ;;
    cr)
      [ "$WV_CR" = "true" ] && printf ' (required because state.cr_enabled is true)'
      ;;
    findings:*)
      printf ' (required because %s reported findings)' "${cond#findings:}"
      ;;
  esac
  return 0
}

WV_UNMET=""           # the comma list the W-ORDER reason quotes
WV_ORDER_DETAIL=""    # the same list with each entry's "required because" clause
WV_UNMET_SEEN=""      # blockers already named, so each is named exactly once
WV_UNMET_VISITED=""   # rows already walked, so a shared predecessor is cheap

wv_after_unmet() {
  # wv_after_unmet <code> -> the unmet-predecessor list, on stdout AND in
  # WV_UNMET. Read it through WV_UNMET rather than a command substitution: the
  # list is only half the answer, and a subshell would drop WV_ORDER_DETAIL and
  # the WV_COND_* deny that comes with status 2.
  #
  # 0 = every predecessor settled, 1 = at least one is not, 2 = a predecessor's
  # condition could not be answered here — unreadable, or resting on an
  # unanswered scope flag (WV_COND_RULE / WV_COND_ARGS carry the deny).
  WV_UNMET=""
  WV_ORDER_DETAIL=""
  WV_UNMET_SEEN=""
  WV_UNMET_VISITED=""
  wv_after_unmet_walk "$1"
  [ "$?" = "2" ] && return 2
  [ -n "$WV_UNMET" ] || return 0
  printf '%s' "$WV_UNMET"
  return 1
}

wv_after_unmet_walk() {
  # The recursion behind wv_after_unmet. A predecessor that is SKIPPED (its
  # `modes` exclude the active mode, or its `condition` is false) is not a full
  # stop: the walk continues into ITS predecessors, so a wave with cr_enabled
  # false still cannot run BC before TDE-GREEN, and a demo wave still cannot run
  # TEET before TDE-GREEN through the full-only rows between them. A predecessor
  # the state records as `done` ends the walk, because a phase that actually ran
  # already waited for its own predecessors.
  #
  # It returns 2 the moment a condition cannot be answered, so the W-ARTIFACT,
  # W-MARKER or W-SCOPE deny reaches the caller unchanged. That is also why an
  # unanswered flag on a SKIPPABLE predecessor blocks the successor instead of
  # being walked past: `unknown` never reaches the skip branch at all.
  local code="$1" after p blocker
  local -a preds=()
  case " $WV_UNMET_VISITED " in *" $code "*) return 0 ;; esac
  WV_UNMET_VISITED="$WV_UNMET_VISITED $code"
  after="$(wv_row_get "$code" "$WV_COL_AFTER")" || return 0
  [ -n "$after" ] || return 0
  IFS=',' read -ra preds <<<"$after"
  for p in "${preds[@]}"; do
    [ -n "$p" ] || continue
    wv_phase_done "$p"
    case "$?" in
      0)
        case "$WV_PHASE_DONE_WHY" in
          done) continue ;;
          *)
            wv_after_unmet_walk "$p"
            [ "$?" = "2" ] && return 2
            continue
            ;;
        esac
        ;;
      2) return 2 ;;
      3) blocker="$WV_COND_PENDING" ;;
      *) blocker="$p" ;;
    esac
    # Several predecessors can resolve to one blocker (a row and the BF row
    # waiting on it both pend on the same scan); the reason names it once.
    case " $WV_UNMET_SEEN " in *" $blocker "*) continue ;; esac
    WV_UNMET_SEEN="$WV_UNMET_SEEN $blocker"
    WV_UNMET="${WV_UNMET:+$WV_UNMET, }$blocker"
    WV_ORDER_DETAIL="${WV_ORDER_DETAIL:+$WV_ORDER_DETAIL, }$blocker$(wv_required_because "$blocker")"
  done
  return 0
}

WV_OA_SEEN=""

wv_ordered_after() {
  # wv_ordered_after <code> <target> — true when <target> is a transitive
  # predecessor of <code> through the `after` columns.
  #
  # Structural: neither mode nor condition enters. "Ordered after TDE-GREEN" is
  # a fact about the pipeline's shape, so BC is ordered after TDE-GREEN whether
  # or not the CR row between them runs in this wave.
  WV_OA_SEEN=""
  wv_ordered_after_walk "$1" "$2"
}

wv_ordered_after_walk() {
  local code="$1" target="$2" after p
  local -a preds=()
  case " $WV_OA_SEEN " in *" $code "*) return 1 ;; esac
  WV_OA_SEEN="$WV_OA_SEEN $code"
  after="$(wv_row_get "$code" "$WV_COL_AFTER")" || return 1
  [ -n "$after" ] || return 1
  IFS=',' read -ra preds <<<"$after"
  for p in "${preds[@]}"; do
    [ -n "$p" ] || continue
    [ "$p" = "$target" ] && return 0
    wv_ordered_after_walk "$p" "$target" && return 0
  done
  return 1
}

# ---------------------------------------------------------------------------
# 5d. The scope gate.
# ---------------------------------------------------------------------------

WV_SCOPE_FLAG=""   # the state key that is still "unknown"
WV_SCOPE_ARG=""    # the key scripts/wave-set.sh takes for it

wv_scope_ready() {
  # False while `ui`, `behaviour_change` or `cr_enabled` is the string
  # "unknown" — the value wave-init.sh actually writes, and the value every
  # later wave inherits. One flag is reported at a time, in the order the
  # questions are asked, so the reason names one command rather than three.
  #
  # This gate is TDE-RED's, and it is deliberately not the only place an
  # unanswered flag is caught: a dispatch of DR or CR itself, or of anything whose
  # predecessor set depends on one, is refused by wv_unanswered_scope through the
  # same rule id. This gate asks "may the wave proceed past the question"; that
  # one asks "can this particular condition be evaluated at all".
  #
  # The CLI key is not the state key (`behaviour-change` vs
  # `behaviour_change`), which is why the reason carries both.
  WV_SCOPE_FLAG=""
  WV_SCOPE_ARG=""
  if [ "$WV_UI" = "unknown" ]; then
    WV_SCOPE_FLAG="ui"; WV_SCOPE_ARG="ui"; return 1
  fi
  if [ "$WV_BC" = "unknown" ]; then
    WV_SCOPE_FLAG="behaviour_change"; WV_SCOPE_ARG="behaviour-change"; return 1
  fi
  if [ "$WV_CR" = "unknown" ]; then
    WV_SCOPE_FLAG="cr_enabled"; WV_SCOPE_ARG="cr"; return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# 5e. The three dispatch-time gates. Each returns 1 — and only 1 — after it has
#     emitted its deny, so wv_main can chain them with `|| return 0`.
# ---------------------------------------------------------------------------

wv_dr_open_gate() {
  # TDE-RED is denied while `.wave/dr.md` has more `^OPEN:` lines than
  # `.wave/approvals/dr-open.md` has `^RESOLVED:` lines.
  #
  # The gate is the approval file, never the absence of text: the user answers
  # DR items in conversation and nothing rewrites dr.md, so counting only the
  # OPEN lines would make the wave unblockable.
  #
  # It applies only when DR actually ran. With ui and behaviour_change both
  # false there is no design review to answer, and requiring dr.md would
  # deadlock every wave that legitimately skips DR.
  [ "$WV_TAG_PHASE" = "TDE-RED" ] || return 0
  wv_condition_met DR
  [ "$?" = "0" ] || return 0

  local rel=".wave/dr.md" file="$WV_WAVE_DIR/dr.md"
  if [ ! -f "$file" ]; then
    wv_rule_deny W-ARTIFACT "$rel" DR "$rel"
    return 1
  fi

  # Fenced blocks are stripped first: a dr.md that DOCUMENTS the OPEN: format
  # inside a code fence has no open items.
  local stripped
  stripped="$(command awk '/^```/ { fence = !fence; next } !fence' "$file" 2>/dev/null)"

  local open_n
  open_n="$(wv_scan_count_text "$stripped" '^OPEN:' "$rel")" || return 0
  [ "$open_n" -gt 0 ] || return 0

  local approval="$WV_WAVE_DIR/approvals/dr-open.md" resolved_n=0
  if [ -f "$approval" ]; then
    resolved_n="$(wv_scan_count "$approval" '^RESOLVED:')" || return 0
  fi
  [ "$resolved_n" -ge "$open_n" ] && return 0

  local lines="" l
  while IFS= read -r l; do
    [ -n "$l" ] || continue
    lines="${lines:+$lines | }$l"
  done < <(command grep -E '^OPEN:' <<<"$stripped" 2>/dev/null)

  wv_rule_deny W-DR-OPEN "$open_n" "$resolved_n" "$lines"
  return 1
}

wv_visual_gate() {
  # While `ui` is true, every phase ordered after TDE-GREEN waits for
  # `.wave/approvals/green-visual.md`. Not only TEET: a bug scan or a code
  # review reading a screen nobody has looked at is the same defect one step
  # earlier. `anytime` rows have no place in the order and are exempt.
  [ "$WV_UI" = "true" ] || return 0
  [ "$(wv_row_get "$WV_TAG_PHASE" "$WV_COL_WHEN")" != "anytime" ] || return 0
  wv_ordered_after "$WV_TAG_PHASE" TDE-GREEN || return 0
  [ -f "$WV_WAVE_DIR/approvals/green-visual.md" ] && return 0
  wv_rule_deny W-VISUAL "$WV_TAG_PHASE"
  return 1
}

wv_bf_approval_gate() {
  # A `BF-<X>` dispatch waits for `.wave/approvals/bf-<X>.md`: bug-fix
  # decisions come from the user, never from the orchestrator's judgement.
  #
  # The path is byte-exact — `bf-bc.md` does not satisfy `BF-BC`. On a
  # case-insensitive filesystem the kernel would fold it for us; the reason
  # names the exact path so the difference is visible either way.
  local src
  case "$WV_TAG_PHASE" in
    BF-?*) src="${WV_TAG_PHASE#BF-}" ;;
    *) return 0 ;;
  esac
  [ -f "$WV_WAVE_DIR/approvals/bf-$src.md" ] && return 0
  wv_rule_deny W-BF-APPROVAL "$src" "$WV_TAG_PHASE"
  return 1
}

# ---------------------------------------------------------------------------
# 5f. The round ceiling and the budget gate.
# ---------------------------------------------------------------------------

wv_round_gate() {
  # Two completed rounds of the same phase AND role is the ceiling; the third
  # needs `.wave/approvals/rerun-<PHASE>-<role>.md`.
  #
  # Rounds, not dispatches: `state.rounds` is incremented once, by
  # subagent-stop.sh, when the last concurrent agent of that phase+role stops,
  # so a `fanout` of 3 PDT writers is one round and a dispatch this hook denied
  # never burned anything. THIS SCRIPT NEVER WRITES `rounds`.
  #
  # The approval is scoped to the phase and the role it names: one role's
  # rerun approval cannot unlock another's.
  [ "$(wv_row_get "$WV_TAG_PHASE" "$WV_COL_WHEN")" != "anytime" ] || return 0
  local n
  n="$(wv_rounds_count "$WV_TAG_PHASE/$WV_TAG_ROLE")"
  [ "$n" -ge 2 ] || return 0
  [ -f "$WV_WAVE_DIR/approvals/rerun-$WV_TAG_PHASE-$WV_TAG_ROLE.md" ] && return 0
  wv_rule_deny W-ROUND "$WV_TAG_PHASE" "$WV_TAG_ROLE" "$n" "$WV_TAG_PHASE" "$WV_TAG_ROLE"
  return 1
}

wv_ledger_sum() {
  # wv_ledger_sum <phase> <ledger> -> "<output sum><US><unparsable line numbers>".
  # Empty output means jq could not read the file at all, which every caller
  # treats as "nothing measured" and never as a zero spend.
  #
  # Output tokens only (spec section 9): output is the work produced, and cache
  # reads are cheap enough to hide waste. Absent fields count as 0; a line that
  # is not a JSON object is counted as skipped rather than as anything.
  jq -R -r -n --arg phase "$1" '
      [inputs] as $lines
      | reduce range(0; ($lines | length)) as $i ({sum: 0, bad: []};
          $lines[$i] as $raw
          | if ($raw | test("^[[:space:]]*$")) then .
            else (($raw | try fromjson catch null)) as $o
              | if ($o | type) != "object" then (.bad += [$i + 1])
                else (if (($o.phase // "") == $phase)
                      then (.sum += (($o.output // 0) | if type == "number" then floor else 0 end))
                      else . end)
                end
            end)
      | "\(.sum)\u001f\(.bad | map(tostring) | join(","))"' < "$2" 2>/dev/null
  return 0
}

wv_budget_gate() {
  # The phase's ledgered output tokens against `hooks/budgets.tsv` value ×
  # `fanout`, as a per-phase total. Over 1× warns; over 2× denies until
  # `.wave/approvals/budget-<PHASE>.md` exists. Both boundaries are strictly
  # greater, so exactly 1× is silent and exactly 2× warns without denying.
  #
  # A phase with no budget row, an absent ledger, and a ledger jq cannot read
  # all produce no W-BUDGET at all: an unmeasured spend is not an overspend.
  # `anytime` rows are exempt (spec section 6).
  [ "$(wv_row_get "$WV_TAG_PHASE" "$WV_COL_WHEN")" != "anytime" ] || return 0
  local ledger="$WV_WAVE_DIR/ledger.jsonl"
  [ -f "$ledger" ] || return 0

  local base fanout limit blob spent bad
  base="$(wv_budget_value "$WV_TAG_PHASE")" || return 0
  fanout="$(wv_row_get "$WV_TAG_PHASE" "$WV_COL_FANOUT")"
  case "$fanout" in ''|*[!0-9]*|0) fanout=1 ;; esac
  limit=$((base * fanout))
  [ "$limit" -gt 0 ] || return 0

  blob="$(wv_ledger_sum "$WV_TAG_PHASE" "$ledger")"
  [ -n "$blob" ] || return 0
  IFS=$'\x1f' read -r spent bad <<<"$blob"
  if [ -n "$bad" ]; then
    wv_rule_warn W-STATE "$ledger could not be parsed at line $bad, so that line was skipped; the budget was summed over the lines that did parse, because a corrupt ledger must never manufacture a deny"
  fi
  case "$spent" in ''|*[!0-9]*) return 0 ;; esac
  [ "$spent" -gt "$limit" ] || return 0

  # One decimal, truncated, computed in integers: the ratio is a diagnosis, not
  # an accounting figure, and a truncated 2.1x never overstates the overage.
  local tenths ratio
  tenths=$(( spent * 10 / limit ))
  ratio="$((tenths / 10)).$((tenths % 10))"

  if [ "$spent" -gt $(( limit * 2 )) ]; then
    [ -f "$WV_WAVE_DIR/approvals/budget-$WV_TAG_PHASE.md" ] && return 0
    wv_rule_deny W-BUDGET "$WV_TAG_PHASE" "$spent" "$limit" "$ratio" "$WV_TAG_PHASE"
    return 1
  fi
  wv_rule_warn W-BUDGET "$WV_TAG_PHASE" "$spent" "$limit" "$ratio" "$WV_TAG_PHASE"
  return 0
}

# ---------------------------------------------------------------------------
# 5g. Prompt size and verbatim pastes.
# ---------------------------------------------------------------------------

wv_prompt_warn() {
  # Two warnings and no deny (spec section 9): over 8,000 characters is worth
  # saying, over 24,000 is worth saying loudly, and neither is worth blocking —
  # the framework requires cross-team data to pass through the orchestrator, so
  # a hard cap here would force it to make the brief worse.
  #
  # One warning per invocation, carrying both thresholds when both are crossed:
  # a reason must carry exactly one `W-` token, and two queued W-PROMPT
  # warnings would put two in the additionalContext a consumer reads.
  case "$WV_PROMPT_TYPE" in
    string|null|'') : ;;
    *)
      wv_rule_warn W-STATE "the dispatch sent tool_input.prompt as a JSON $WV_PROMPT_TYPE, and only a string can be measured, so the prompt-size and paste checks were skipped for this call"
      return 0
      ;;
  esac
  case "$WV_PROMPT_LEN" in ''|*[!0-9]*) return 0 ;; esac
  if [ "$WV_PROMPT_LEN" -gt 24000 ]; then
    wv_rule_warn W-PROMPT "$WV_PROMPT_LEN" "8000-character lean-context cap and, more loudly, the 24000-character cap - still not a deny, because the framework requires cross-team data to pass through the orchestrator"
  elif [ "$WV_PROMPT_LEN" -gt 8000 ]; then
    wv_rule_warn W-PROMPT "$WV_PROMPT_LEN" "8000-character lean-context cap"
  fi
  return 0
}

wv_paste_block_len() {
  # wv_paste_block_len <file> -> the length of the FIRST block <file> and the
  # prompt share that reaches 4,000 characters; empty when they share no such
  # block. Not the longest: the reason only needs one, and stopping at the first
  # is what keeps the search linear.
  #
  # Exact, and linear in the file. A shared block of >= 4,000 characters must
  # fully contain one of the file's 2,000-character windows taken at a 2,000
  # stride, so only those windows are searched — 128 of them for a 256 KiB
  # file, not 252,000 — and each hit is then extended in both directions to
  # measure the real block. Every occurrence of a window is tried, because the
  # first one need not be the one that extends far enough.
  #
  # Lengths are whatever this awk counts, which is bytes on a byte-oriented
  # awk. That is the right unit here: spec section 9 denies on a block that is
  # byte-identical to a file, and it is the prompt-size caps, not this, that
  # are specified in Unicode scalar values.
  WV_PASTE_PROMPT="$WV_PROMPT_TEXT" command awk '
    BEGIN { p = ENVIRON["WV_PASTE_PROMPT"]; lp = length(p); min = 4000; seed = 2000; s = "" }
    { s = (NR == 1 ? $0 : s "\n" $0) }
    END {
      n = length(s)
      if (n < min || lp < min) exit 0
      for (i = 1; i + seed - 1 <= n; i += seed) {
        w = substr(s, i, seed)
        from = 1
        while (1) {
          k = index(substr(p, from), w)
          if (k == 0) break
          j = from + k - 1
          a = i; b = j
          while (a > 1 && b > 1 && substr(s, a - 1, 1) == substr(p, b - 1, 1)) { a--; b-- }
          e1 = i + seed - 1; e2 = j + seed - 1
          while (e1 < n && e2 < lp && substr(s, e1 + 1, 1) == substr(p, e2 + 1, 1)) { e1++; e2++ }
          if (e1 - a + 1 >= min) { printf "%d", e1 - a + 1; exit 0 }
          from = j + 1
        }
      }
    }' "$1" 2>/dev/null
  return 0
}

wv_paste_gate() {
  # The pollution pattern spec section 9 actually denies: a >= 4,000-character
  # block of the prompt that is byte-identical to a stretch of some file already
  # under `.wave/`, which the subagent could have read itself. Size alone is
  # never the deny.
  [ "$WV_PROMPT_TYPE" = "string" ] || return 0
  # The short circuit is on BYTES, not on scalar values: the block length below
  # is measured by awk, which counts bytes on a byte-oriented awk, and a prompt
  # of 3,000 four-byte emoji is 12,000 bytes. Guarding on the scalar count would
  # skip the scan on a prompt that does contain a 4,000-byte pasted block.
  case "$WV_PROMPT_BYTES" in ''|*[!0-9]*) return 0 ;; esac
  [ "$WV_PROMPT_BYTES" -ge 4000 ] || return 0
  [ -n "$WV_WAVE_DIR" ] || return 0
  [ -d "$WV_WAVE_DIR" ] || return 0

  local f size len rel
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    size="$(wc -c < "$f" 2>/dev/null)"
    case "$size" in ''|*[!0-9]*) continue ;; esac
    [ "$size" -ge 4000 ] || continue
    [ "$size" -le "$WV_PASTE_FILE_CAP" ] || continue
    len="$(wv_paste_block_len "$f")"
    case "$len" in ''|*[!0-9]*) continue ;; esac
    [ "$len" -ge 4000 ] || continue
    rel=".wave${f#"$WV_WAVE_DIR"}"
    wv_rule_deny W-PASTE "$len" "$rel"
    return 1
  done < <(find "$WV_WAVE_DIR" -type f 2>/dev/null | sort)
  return 0
}

# ---------------------------------------------------------------------------
# 6. The emit choke point.
# ---------------------------------------------------------------------------

wv_rule_deny() {
  # wv_rule_deny <rule> [args...] — wv_deny with every argument neutralised.
  # See the header: `W-` becomes `W_` in the arguments, never in the template,
  # so the rendered reason keeps exactly one `W-` token even when the dispatch
  # text contains something that looks like a rule id.
  local rule="$1"
  shift
  if [ "$#" -eq 0 ]; then
    wv_deny "$rule"
    return
  fi
  local -a args=()
  local arg
  for arg in "$@"; do
    args+=("${arg//W-/W_}")
  done
  wv_deny "$rule" "${args[@]}"
}

wv_rule_warn() {
  # wv_rule_warn <rule> [args...] — wv_warn, neutralised the same way.
  local rule="$1"
  shift
  if [ "$#" -eq 0 ]; then
    wv_warn "$rule"
    return
  fi
  local -a args=()
  local arg
  for arg in "$@"; do
    args+=("${arg//W-/W_}")
  done
  wv_warn "$rule" "${args[@]}"
}

# ---------------------------------------------------------------------------
# 7. The rules, in the one evaluation order.
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
    wv_rule_deny W-MODEL-MISSING "$phase" "$role" \
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
    wv_rule_warn W-MODEL-UNKNOWN "$(wv_model_unknown_detail "$WV_MODEL_TRIM")"
    return 0
  fi
  need_rank="$(wv_tier_rank "$need_name")" || need_rank=""
  case "$need_rank" in
    1|2|3|4) ;;
    *)
      # Our own data files disagree with each other. Fail open, loudly: a hook
      # that cannot rank the requirement has not measured the dispatch.
      wv_rule_warn W-STATE "hooks/phases.tsv gives $phase/$role the tier name \"$need_name\", which hooks/models.tsv does not rank, so the tier comparison was skipped"
      return 0
      ;;
  esac
  if [ "$requested" -lt "$need_rank" ]; then
    wv_rule_deny W-TIER "$WV_MODEL_TRIM" "$requested" "$phase" "$role" "$need_name" "$need_rank"
    return 1
  fi
  return 0
}

wv_main() {
  wv_parse_stdin || return 0
  # Wired to PreToolUse(Agent) only. Any other event or tool has not been
  # measured by this script and says nothing: a PostToolUse payload carries a
  # tool_response this file must not judge, and that event has no deny channel
  # at all, so a reason emitted there would be silently discarded.
  [ "$WV_EVENT" = "PreToolUse" ] || return 0
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
    wv_rule_deny W-NESTED "$WV_AGENT_ID"
    return 0
  fi

  # 2. Fork (spec section 7): inherits the whole orchestrator context and
  #    cannot be model-routed at all.
  if [ "$WV_SUBAGENT" = "fork" ]; then
    wv_rule_deny W-FORK
    return 0
  fi

  # 3. The description-length warning is queued before any deny, so a deny
  #    carries it as additionalContext instead of losing it.
  #
  #    `${#...}` counts what the ambient locale calls a character, so a
  #    description of exactly 120 multi-byte characters can land either side of
  #    this boundary depending on how the client's environment is set. It is
  #    left as it is because the consequence is one warning on one dispatch;
  #    the prompt caps below, whose boundary decides nothing but is measured far
  #    more often, are read through jq instead, which always counts Unicode
  #    scalar values.
  if [ "${#WV_DESC}" -gt 120 ]; then
    wv_rule_warn W-DESC "${#WV_DESC}"
  fi

  # 4. The tag: present and well formed, for this wave, naming a real phase.
  wv_tag_parse "$WV_DESC" "$WV_PROMPT_TEXT"
  if [ "$WV_TAG_OK" != "1" ]; then
    wv_rule_deny W-TAG "$(wv_tag_arg)"
    return 0
  fi
  if [ "$WV_TAG_WAVE" != "$WV_WAVE" ]; then
    # Byte comparison, never numeric: `01` is not `1`.
    WV_TAG_DETAIL="the dispatch said W:$WV_TAG_WAVE"
    wv_rule_deny W-TAG "$(wv_tag_arg)"
    return 0
  fi
  if ! wv_phase_row "$WV_TAG_PHASE"; then
    WV_TAG_DETAIL="P:$WV_TAG_PHASE is not a row in hooks/phases.tsv"
    wv_rule_deny W-TAG "$(wv_tag_arg)"
    return 0
  fi
  # The library records warnings against a phase; from here we know it.
  WV_PHASE="$WV_TAG_PHASE"

  # 5. Mode: the row has to run in this wave's mode.
  if ! wv_mode_allows; then
    wv_rule_deny W-MODE "$WV_TAG_PHASE" "${WV_ROW_MODES//,/ or }" "$WV_MODE"
    return 0
  fi

  # 6. Role: the row has to define the tag's role (scanner and writer resolve
  #    to the executor column).
  local need_name
  need_name="$(wv_role_tier "$WV_TAG_PHASE" "$WV_TAG_ROLE")"
  if [ "$need_name" = "-" ]; then
    wv_rule_deny W-ROLE "$WV_TAG_ROLE" "$WV_TAG_PHASE" "$(wv_row_roles)"
    return 0
  fi

  # 7. Model presence: every dispatch names its model.
  if ! wv_model_named; then
    wv_rule_deny W-MODEL-MISSING "$WV_TAG_PHASE" "$WV_TAG_ROLE" \
      "$(wv_model_missing_detail "$need_name")"
    return 0
  fi

  # 8. Tier: at least the row's cell for that role; higher always passes.
  wv_tier_rule "$WV_TAG_PHASE" "$WV_TAG_ROLE" "$need_name" || return 0

  # 9. Prompt size, queued BEFORE any part-2 deny for the same reason the
  #    description-length warning is: a deny then carries it as
  #    additionalContext instead of losing it. It also reports a prompt the
  #    client sent as something other than a string, which is the one case
  #    where the size and paste rules measured nothing.
  wv_prompt_warn

  # 10. Scope: TDE-RED is the first phase whose predecessor set depends on the
  #     answers, so it is where an unanswered scope question stops the wave.
  #     Earlier phases stay dispatchable — a wave has to be able to start.
  if [ "$WV_TAG_PHASE" = "TDE-RED" ] && ! wv_scope_ready; then
    wv_rule_deny W-SCOPE "$WV_SCOPE_FLAG" "$WV_SCOPE_ARG"
    return 0
  fi

  # 11. The dispatched phase's OWN condition. A row whose condition is false is
  #     not part of this wave at all, so dispatching it is a mistake worth
  #     naming rather than an ordering problem.
  wv_condition_met "$WV_TAG_PHASE"
  case "$?" in
    1)
      wv_rule_deny W-COND "$WV_COND_TEXT" "$WV_TAG_PHASE" "$WV_COND_DETAIL"
      return 0
      ;;
    2)
      wv_rule_deny "$WV_COND_RULE" "${WV_COND_ARGS[@]}"
      return 0
      ;;
  esac
  # 0 (met) and 3 (its own scan has not run yet) both fall through: for 3 the
  # order rule below names that scan, which is the sentence the orchestrator can
  # act on, and that scan is in this row's `after` anyway.

  # 12. Order: the `after` DAG, with the mode-and-condition skip rule. An
  #     `anytime` row is exempt (spec section 6).
  if [ "$(wv_row_get "$WV_TAG_PHASE" "$WV_COL_WHEN")" != "anytime" ]; then
    # Not a command substitution: WV_UNMET carries the list and WV_ORDER_DETAIL
    # the "required because" clauses, and a subshell would drop both.
    wv_after_unmet "$WV_TAG_PHASE" >/dev/null
    case "$?" in
      1)
        wv_rule_deny W-ORDER "$WV_UNMET" "$WV_TAG_PHASE" "$WV_ORDER_DETAIL"
        return 0
        ;;
      2)
        wv_rule_deny "$WV_COND_RULE" "${WV_COND_ARGS[@]}"
        return 0
        ;;
    esac
  fi

  # 13. The three gates that read an artifact at dispatch time rather than at
  #     stop, in the precedence order hooks/reasons.tsv pins.
  wv_dr_open_gate || return 0
  wv_visual_gate || return 0
  wv_bf_approval_gate || return 0

  # 14. The round ceiling. Read only — subagent-stop.sh owns the counter.
  wv_round_gate || return 0

  # 15. The pasted-block deny, then the budget.
  wv_paste_gate || return 0
  wv_budget_gate || return 0

  return 0
}

wv_main
# The one emit: a deny has already written its object (and carried the queued
# warnings with it); this is how a warning-only invocation reaches stdout.
wv_emit_flush
exit 0
