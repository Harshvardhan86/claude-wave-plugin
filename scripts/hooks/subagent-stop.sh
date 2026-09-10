#!/usr/bin/env bash
# scripts/hooks/subagent-stop.sh — the SubagentStop hook.
#
# This is where a dispatch is closed out. `post-agent.sh` recorded the launch
# under `state.active[<agentId>]` (phase, VERBATIM tag role, requested and
# resolved model, tool_use_id); this script joins the stopping agent to that
# record and then does five separate things with it:
#
#   1. checks the phase's hand-off artifact and marker ON DISK, but only at the
#      stop of the phase's CLOSING role and only when no other agent of that
#      phase is still running (spec section 6);
#   2. reads the agent's own transcript and compares the MODAL tier of its
#      assistant turns with what the phase table required (spec section 7) —
#      a warning and a recorded taint, never a block;
#   3. appends one ledger line per agent with the token usage (spec section 9);
#   4. increments `state.rounds["<PHASE>/<role>"]` once per concurrent group
#      (spec section 8.7), which is the counter pre-agent.sh's round ceiling
#      reads and never writes;
#   5. blocks ONCE for a return message over 2,000 characters (spec section
#      8.5), and hands over to `scripts/wave-close.sh --if-terminal` when the
#      active mode's terminal phase reaches `done`.
#
# Evaluation order, at most one JSON object on stdout (the library's WV_EMITTED
# guard), and every state write completed BEFORE that object is emitted:
#
#   event guard        (silent: wired to SubagentStop only)
#   -> state           (silent when there is no active wave)
#   -> join state.active[agent_id]      (unknown agent: ledgered, never blocked)
#   -> transcript stats + modal tier    (W-TAINT warning at most; the expensive
#                                        read, deliberately before the lock)
#   -> take .wave/lock ONCE for the whole write phase, and inside it:
#        drain the ledger spool  (so Task 6's budget gate sees a spooled line)
#        the stop record and the round counter
#        artifact + marker, closing role, last one out  (W-ARTIFACT / W-MARKER)
#        the phase record, then the ledger line
#   -> release, then the terminal-phase close (a separate process, same lock)
#   -> the one block: W-ARTIFACT / W-MARKER, else W-LONG-RETURN
#
# THE THREE RULES THAT DECIDE WHEN THIS SCRIPT BLOCKS, and why each is written
# the way it is:
#
#   * ONE BLOCK PER AGENT PER RULE, and the key is a RECORD
#     (`active[<id>].blocked`), never `stop_hook_active`. Measured (probe2): a
#     block IS honoured — the agent keeps working, obeys the reason, and stops
#     again with the flag set — and it then stops a THIRD time with the flag
#     FALSE again. A hook keyed on the flag blocks that third stop, and the one
#     after it, up to the harness's block cap. A record survives every stop; a
#     flag on one payload does not. `stop_hook_active: true` additionally
#     disarms the artifact block on its own, and the failure is recorded in the
#     state either way for the next dependent dispatch to deny on.
#   * The artifact and marker checks run ONLY at the closing role's stop
#     (`reviewer`, else `lead`, else `executor`) and only when this agent is the
#     last of its phase still running. A PDT fan-out launches three writers
#     before any of them stops; blocking the first one out on an artifact its
#     siblings are still writing — or on one the reviewer has not been
#     dispatched to write yet — is a false NO-GO on a correct wave.
#   * The ledger line, the round increment and the `stopped` record are each
#     keyed so that the stop which follows a block repeats none of them — and the
#     ledger line a lean-return block DEFERS is written by that following stop,
#     carrying `long_return: true`, so no spend is lost.
#
# WHAT THIS FILE READS FROM THE LIBRARY, and why it is not read from
# pre-agent.sh: the phase-table readers (`wv_row_line`, `wv_row_get`, the
# `WV_COL_*` constants) live in lib.sh section 7b, because three scripts read
# that table and the column numbers are the table's contract rather than any one
# script's. `source`-ing pre-agent.sh instead would run its whole PreToolUse rule
# chain against this event and then `exit 0` before this file ran a line — the
# same mechanical reason post-agent.sh gives for not sourcing it either.
#
# `set -u`, never `set -e`: a hook must not fail closed on its own bug.

set -u

WV_HOOK_DIR="$(cd "${BASH_SOURCE[0]%/*}" 2>/dev/null && pwd)"
# shellcheck source=scripts/hooks/lib.sh
source "$WV_HOOK_DIR/lib.sh"

# ---------------------------------------------------------------------------
# 1. Caps this file states in the code that enforces them.
#
# The phase table is read through lib.sh's `wv_row_line` / `wv_row_get` and the
# `WV_COL_*` constants (library section 7b). This file used to carry its own copy
# of both readers; a review ruled the duplication out.
# ---------------------------------------------------------------------------

# Transcripts above this many bytes are not summed (spec section 9: "above a
# stated transcript byte cap the sum is skipped"). 8 MiB is far above every
# subagent transcript measured while building this layer, and it is stated here,
# in the code that enforces it, rather than in prose — tests/cases/
# taint-245-over-cap.sh reads this line and fails loudly if it cannot.
WV_TRANSCRIPT_CAP=8388608

# Spec section 8.5. "Longer than 2,000 characters" — 2,000 exactly passes.
WV_LONG_RETURN_CAP=2000

wv_tier_name() {
  # wv_tier_name <rank> -> the tier token with that rank, from hooks/models.tsv.
  # The inverse of lib.sh's wv_tier_rank, and it reads the same file so the two
  # cannot disagree about what tier 3 is called.
  local want="$1" name rank
  if [ -f "$WV_MODELS_TSV" ]; then
    while IFS=$'\t' read -r name rank; do
      case "$name" in ''|'#'*|token) continue ;; esac
      if [ "$rank" = "$want" ]; then
        printf '%s' "$name"
        return 0
      fi
    done < "$WV_MODELS_TSV"
  fi
  case "$want" in
    1) printf 'haiku' ;;
    2) printf 'sonnet' ;;
    3) printf 'opus' ;;
    4) printf 'fable' ;;
    *) printf 'unknown' ;;
  esac
  return 0
}

# ---------------------------------------------------------------------------
# 2. Roles: which column a tag role reads, and which role closes a phase.
# ---------------------------------------------------------------------------

wv_role_column() {
  # wv_role_column <tag role> -> lead | executor | reviewer. `scanner` and
  # `writer` both resolve to the executor column (spec section 5).
  case "${1:-}" in
    lead) printf 'lead' ;;
    executor|scanner|writer) printf 'executor' ;;
    reviewer) printf 'reviewer' ;;
    *) return 1 ;;
  esac
  return 0
}

wv_closing_role() {
  # wv_closing_role <code> -> the highest-ranked role column the row DEFINES:
  # `reviewer`, else `lead`, else `executor`. Returns 1 (printing nothing) when
  # the row defines no role at all, which no shipped row does but a hand-edited
  # table could.
  #
  # This is the whole of the "who closes the phase" question, and it is answered
  # from the table rather than from a list of phase codes: BC defines only an
  # executor, so its scanner closes it (AC-230), while TEET-TC defines all three
  # and its three parallel writers close nothing (AC-228, AC-229).
  local rec
  rec="$(wv_row_line "$1")" || return 1
  local -a cells=()
  IFS=$'\x1f' read -r -a cells <<<"$rec"
  local lead="${cells[$((WV_COL_LEAD - 1))]:-}"
  local exe="${cells[$((WV_COL_EXECUTOR - 1))]:-}"
  local rev="${cells[$((WV_COL_REVIEWER - 1))]:-}"
  if [ -n "$rev" ] && [ "$rev" != "-" ]; then printf 'reviewer'; return 0; fi
  if [ -n "$lead" ] && [ "$lead" != "-" ]; then printf 'lead'; return 0; fi
  if [ -n "$exe" ] && [ "$exe" != "-" ]; then printf 'executor'; return 0; fi
  return 1
}

wv_running_siblings() {
  # wv_running_siblings <code> -> the ids of the OTHER agents of that phase that
  # state.active still reports as not stopped, space separated. Empty output is
  # "this agent is the last one out".
  #
  # The IDS, not a count, because the one place this answer is negative is a
  # place the operator has to be told about: the phase's closing role has stopped
  # and the check was skipped because somebody else is still running. If that
  # somebody was killed or rate-limited, its stop will never arrive and the wave
  # waits forever — so the warning has to name who it is waiting for.
  printf '%s' "$(printf '%s' "$WV_STATE" | jq -r --arg id "$WV_STOP_AGENT" --arg p "$1" '
        [ ((.active // {}) | to_entries[])
          | select(.key != $id)
          | select(((.value.phase // "") == $p))
          | select(((.value.status // "") != "stopped"))
          | .key ] | join(" ")' 2>/dev/null)"
  return 0
}

# ---------------------------------------------------------------------------
# 3. The transcript. Streamed line by line under a byte cap; a line that does
#    not parse is SKIPPED and counted, never fatal — the last line of a live
#    transcript is routinely a mid-write fragment.
# ---------------------------------------------------------------------------

WV_TS_OK=0            # 1 once a token sum was actually computed
WV_TS_TURNS=0
WV_TS_INPUT=0
WV_TS_OUTPUT=0
WV_TS_CACHE_READ=0
WV_TS_CACHE_CREATE=0
WV_TS_SKIPPED=0
WV_TS_EXCLUDED=0      # assistant turns with no model, or no output tokens
WV_TS_VOTES=0         # assistant turns that DID carry a mappable tier
WV_TS_TIER=""         # the modal tier's rank, or "" when unverifiable
WV_TS_MODEL=""        # a model string representing that tier
WV_TS_NOTE=""         # "" | "no transcript" | "transcript too large" | …

WV_TS_JQ='
def num($v): if ($v|type) == "number" then $v else 0 end;
reduce inputs as $l (
  {turns:0, input:0, output:0, cread:0, ccreate:0, skipped:0, excluded:0, votes:{}};
  ([$l | fromjson?]) as $p
  | if ($p | length) == 0 then
      (if ($l | test("^\\s*$")) then . else .skipped += 1 end)
    else
      ($p[0]) as $o
      | if ($o | type) != "object" then .skipped += 1
        elif (($o.type // "") != "assistant") then .
        else
          ((if (($o.message? | type) == "object") then $o.message else {} end)) as $msg
          | ((if (($msg.usage? | type) == "object") then $msg.usage else {} end)) as $u
          | (num($u.output_tokens)) as $out
          | (($msg.model // "") | tostring) as $m
          | .turns += 1
          | .input += num($u.input_tokens)
          | .output += $out
          | .cread += num($u.cache_read_input_tokens)
          | .ccreate += num($u.cache_creation_input_tokens)
          | if ($m != "" and $out > 0)
            then .votes[$m] = ((.votes[$m] // 0) + 1)
            else .excluded += 1 end
        end
    end
)
| ([(.turns|tostring), (.input|tostring), (.output|tostring), (.cread|tostring),
    (.ccreate|tostring), (.skipped|tostring), (.excluded|tostring)] | join("\u001f")),
  (.votes | to_entries[] | ((.value | tostring) + "\u001f" + .key))
'

wv_transcript_stats() {
  # wv_transcript_stats <path> — sets every WV_TS_* above.
  #
  # The path is used EXACTLY as the client sent it and is never constructed: a
  # subagent transcript lives under the account's projects directory, not under
  # the project, so a guess would be wrong in a way that reads as "the agent
  # produced nothing". An absent field, a path that does not exist, or a file
  # over the byte cap all record a note and leave the tier unverified — which is
  # not the same thing as, and must never be reported as, a downgrade.
  local path="${1:-}"
  WV_TS_OK=0
  WV_TS_TURNS=0
  WV_TS_INPUT=0
  WV_TS_OUTPUT=0
  WV_TS_CACHE_READ=0
  WV_TS_CACHE_CREATE=0
  WV_TS_SKIPPED=0
  WV_TS_EXCLUDED=0
  WV_TS_VOTES=0
  WV_TS_TIER=""
  WV_TS_MODEL=""
  WV_TS_NOTE=""

  if [ -z "$path" ] || [ ! -f "$path" ]; then
    WV_TS_NOTE="no transcript"
    return 1
  fi

  local size
  size="$(stat -c %s "$path" 2>/dev/null)"
  case "$size" in ''|*[!0-9]*) size="$(wc -c < "$path" 2>/dev/null | tr -d ' ')" ;; esac
  case "$size" in ''|*[!0-9]*) size="" ;; esac
  if [ -z "$size" ]; then
    WV_TS_NOTE="no transcript"
    return 1
  fi
  if [ "$size" -gt "$WV_TRANSCRIPT_CAP" ]; then
    WV_TS_NOTE="transcript too large"
    return 1
  fi

  # -R: every line arrives as a raw STRING, so a line that is not JSON is data to
  # be counted rather than a fatal parse error. -r: the US separators are written
  # as bytes; without it jq re-escapes them as `` inside a quoted string and
  # the split below silently reads the whole header as one field.
  local out
  out="$(jq -Rrn "$WV_TS_JQ" "$path" 2>/dev/null)"
  if [ -z "$out" ]; then
    WV_TS_NOTE="transcript unreadable"
    return 1
  fi

  local header=""
  local -a votes=()
  local line first=1
  while IFS= read -r line; do
    if [ "$first" = "1" ]; then
      header="$line"
      first=0
    else
      [ -n "$line" ] && votes+=("$line")
    fi
  done <<<"$out"

  IFS=$'\x1f' read -r WV_TS_TURNS WV_TS_INPUT WV_TS_OUTPUT WV_TS_CACHE_READ \
    WV_TS_CACHE_CREATE WV_TS_SKIPPED WV_TS_EXCLUDED <<<"$header"
  local f
  for f in WV_TS_TURNS WV_TS_INPUT WV_TS_OUTPUT WV_TS_CACHE_READ WV_TS_CACHE_CREATE \
           WV_TS_SKIPPED WV_TS_EXCLUDED; do
    case "${!f}" in ''|*[!0-9]*) eval "$f=0" ;; esac
  done
  WV_TS_OK=1

  # The modal TIER, not the modal model: two different opus ids are the same
  # tier, and the requirement is expressed in tiers. A model the map cannot read
  # is excluded from the vote rather than counted as a downgrade (spec section 7:
  # unreadable is a gap in our table, never a violation).
  local -a tally=(0 0 0 0 0)
  local -a rep=("" "" "" "" "")
  local v count model rank
  for v in "${votes[@]:-}"; do
    [ -n "$v" ] || continue
    count="${v%%$'\x1f'*}"
    model="${v#*$'\x1f'}"
    case "$count" in ''|*[!0-9]*) continue ;; esac
    rank="$(wv_tier "$model")"
    case "$rank" in
      1|2|3|4) : ;;
      *) WV_TS_EXCLUDED=$((WV_TS_EXCLUDED + count)); continue ;;
    esac
    tally[$rank]=$(( ${tally[$rank]} + count ))
    WV_TS_VOTES=$((WV_TS_VOTES + count))
    [ -n "${rep[$rank]}" ] || rep[$rank]="$model"
  done

  # Ascending, with a strict `>`: on a tie the LOWEST tier wins. Half the turns
  # having run on a smaller model is worth recording, and recording it costs a
  # warning while hiding it costs the wave's evidence.
  local best=0 best_rank=""
  for rank in 1 2 3 4; do
    if [ "${tally[$rank]}" -gt "$best" ]; then
      best="${tally[$rank]}"
      best_rank="$rank"
    fi
  done
  if [ -n "$best_rank" ]; then
    WV_TS_TIER="$best_rank"
    WV_TS_MODEL="${rep[$best_rank]}"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# 4. The artifact and its marker, entirely from the row.
# ---------------------------------------------------------------------------

WV_AC_RULE=""              # "" | W-ARTIFACT | W-MARKER
declare -a WV_AC_ARGS=()   # that rule's template arguments
WV_AC_FINDINGS=""          # the findings count to record, when there is one
WV_AC_FINDINGS_N=""        # wv_findings_count's answer, readable without a subshell
WV_AC_OPEN=""              # the OPEN: count to record, when there is one

wv_artifact_rel() {
  # wv_artifact_rel <cell> -> the on-disk path for a `.wave/`-relative cell.
  # `.wave/` is resolved through WV_WAVE_DIR (already realpath'd and proved to
  # be inside the project root), so a symlinked `.wave` still lands where the
  # library decided it lands.
  local cell="$1"
  case "$cell" in
    .wave/*) printf '%s/%s' "$WV_WAVE_DIR" "${cell#.wave/}" ;;
    /*) printf '%s' "$cell" ;;
    *) printf '%s/%s' "$WV_ROOT" "$cell" ;;
  esac
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
  # line, base 10 (so `FINDINGS: 08` is 8, not an octal error). Returns 1 when
  # the gating scan did not run (it has already warned W-STATE) and 2 when the
  # file carries no such line.
  local file="$1" line
  wv_scan "$file" '^FINDINGS: [0-9]+$' || return 1
  [ "$WV_SCAN_COUNT" != "0" ] || return 2
  line="$(command grep -m1 -E '^FINDINGS: [0-9]+$' "$file" 2>/dev/null)"
  line="${line#FINDINGS: }"
  case "$line" in ''|*[!0-9]*) return 2 ;; esac
  WV_AC_FINDINGS_N="$((10#$line))"
  printf '%s' "$WV_AC_FINDINGS_N"
  return 0
}

wv_screenshot_check() {
  # wv_screenshot_check -> 0 when `.wave/screenshots/` holds at least one file
  # matching `^green-.+\.png$` with a size above zero; otherwise it prints the
  # detail for the W-ARTIFACT reason and returns 1.
  #
  # This one requirement is prose in spec section 6's table rather than a column
  # of phases.tsv (the table has no screenshot column), so it is keyed here on
  # the phase code and on `ui`, and the reason names the required FORM — "add a
  # screenshot" is not an instruction anything can follow deterministically.
  local dir="$WV_WAVE_DIR/screenshots"
  local f base empty_stem=0 zero=""
  if [ ! -d "$dir" ]; then
    printf 'no .wave/screenshots/ directory at all (the wave needs one file matching ^green-.+\\.png$ with size > 0)'
    return 1
  fi
  for f in "$dir"/green-*.png; do
    [ -f "$f" ] || continue
    base="${f##*/}"
    base="${base#green-}"
    base="${base%.png}"
    if [ -z "$base" ]; then
      empty_stem=1
      continue
    fi
    if [ ! -s "$f" ]; then
      zero="${f##*/}"
      continue
    fi
    return 0
  done
  if [ -n "$zero" ]; then
    printf '%s is 0 bytes (the wave needs one file matching ^green-.+\\.png$ with size > 0)' "$zero"
  elif [ "$empty_stem" = "1" ]; then
    printf 'green-.png has an empty stem (the wave needs one file matching ^green-.+\\.png$ with size > 0)'
  else
    printf 'no file in .wave/screenshots/ matches ^green-.+\\.png$ with size > 0'
  fi
  return 1
}

wv_artifact_check() {
  # wv_artifact_check <code> — judges the phase's hand-off artifact on disk and
  # sets WV_AC_RULE / WV_AC_ARGS (the block to emit, if any) plus WV_AC_FINDINGS
  # and WV_AC_OPEN (informational records). Returns 0 when the phase passes.
  #
  # Every shape comes out of the row: a plain path, a path plus a marker regex,
  # a GLOB with the marker `exists` (CCP), or `-` for a phase that hands nothing
  # over. Nothing here is keyed on a phase code except the `ui`-conditional
  # screenshot requirement, which spec section 6 states in prose because the
  # table has no column for it.
  local code="$1"
  WV_AC_RULE=""
  WV_AC_ARGS=()
  WV_AC_FINDINGS=""
  WV_AC_OPEN=""

  local artifact marker
  artifact="$(wv_row_get "$code" "$WV_COL_ARTIFACT")" || return 0
  marker="$(wv_row_get "$code" "$WV_COL_MARKER")"

  local path=""
  if [ -n "$artifact" ] && [ "$artifact" != "-" ]; then
    path="$(wv_artifact_rel "$artifact")"
    case "$artifact" in
      *'*'*)
        # A glob cell (CCP). At least one match must be a non-empty regular
        # file. A `*-precompact.md` in the same directory is named explicitly,
        # because an auto-compact writes one on its own and a reader who cannot
        # see why their checkpoint "does not count" will delete the guard.
        local g found=0
        for g in $path; do
          [ -f "$g" ] && [ -s "$g" ] && { found=1; break; }
        done
        if [ "$found" != "1" ]; then
          local dir="${path%/*}" detail="" pre=""
          for pre in "$dir"/*-precompact.md; do
            [ -f "$pre" ] && { detail="${pre##*/}"; break; }
          done
          if [ -n "$detail" ]; then
            WV_AC_ARGS=("$artifact (the directory holds $detail, and a PreCompact checkpoint does not satisfy $code)" \
                        "$code" "$artifact")
          else
            WV_AC_ARGS=("$artifact (no file matches)" "$code" "$artifact")
          fi
          WV_AC_RULE=W-ARTIFACT
          return 1
        fi
        ;;
      *)
        if [ ! -e "$path" ]; then
          WV_AC_ARGS=("$artifact" "$code" "$artifact")
          WV_AC_RULE=W-ARTIFACT
          return 1
        fi
        if [ ! -f "$path" ]; then
          WV_AC_ARGS=("$artifact (the path exists but is not a regular file)" "$code" "$artifact")
          WV_AC_RULE=W-ARTIFACT
          return 1
        fi
        if [ ! -s "$path" ]; then
          # An empty artifact is a MARKER failure, not a missing one: the phase
          # did create its file, and "it is empty" is the actionable sentence.
          WV_AC_ARGS=("${marker:--}" "$artifact (the file exists and is 0 bytes)")
          WV_AC_RULE=W-MARKER
          return 1
        fi
        if [ -n "$marker" ] && [ "$marker" != "-" ] && [ "$marker" != "exists" ]; then
          # wv_scan, not wv_scan_count: the count matters, and so does the
          # W-STATE the library queues when the scan did NOT run. Read through a
          # command substitution that warning would be queued in a subshell and
          # lost, and this hook would report a clean scan of a file it never
          # managed to read (Global Constraint 7).
          if wv_scan "$path" "$marker"; then
            if [ "$WV_SCAN_COUNT" = "0" ]; then
              WV_AC_ARGS=("$marker" "$artifact (first line: \"$(wv_first_line "$path")\")")
              WV_AC_RULE=W-MARKER
              return 1
            fi
          fi
          # An ABSENT count is a FAILED scan, never a clean zero: the warning is
          # queued, and a hook that measured nothing allows (Global Constraint 4).
        fi
        # Informational, for any row: the OPEN: items a review artifact carries.
        # Recorded, never gated on — the TDE-RED gate re-reads dr.md at dispatch
        # time so that there is one source of truth (AC-147, AC-215).
        if wv_scan "$path" '^OPEN:'; then
          [ "$WV_SCAN_COUNT" = "0" ] || WV_AC_OPEN="$WV_SCAN_COUNT"
        fi
        ;;
    esac
  fi

  # The ui-conditional screenshot requirement (spec section 6's table, prose).
  if [ "$code" = "TDE-GREEN" ] && [ "$WV_UI" = "true" ]; then
    local sdetail
    if ! sdetail="$(wv_screenshot_check)"; then
      WV_AC_ARGS=(".wave/screenshots/green-<name>.png ($sdetail)" "$code" \
                  ".wave/screenshots/green-<name>.png")
      WV_AC_RULE=W-ARTIFACT
      return 1
    fi
  fi

  # The findings count, from the row's `findings` column. Its ABSENCE is not
  # judged here: the dependent `BF-<X>` dispatch judges that (AC-92, AC-225), so
  # one place decides instead of two that can disagree.
  local fcode
  fcode="$(wv_row_get "$code" "$WV_COL_FINDINGS")"
  if [ -n "$fcode" ] && [ "$fcode" != "-" ]; then
    local ffile="$WV_WAVE_DIR/findings/$fcode.md"
    if [ -f "$ffile" ]; then
      # Not a command substitution, for the same reason as the scans above: this
      # runs wv_scan, and its W-STATE has to survive.
      if wv_findings_count "$ffile" >/dev/null; then
        WV_AC_FINDINGS="$WV_AC_FINDINGS_N"
      fi
    fi
  fi
  return 0
}

# ---------------------------------------------------------------------------
# 5. State writes. Each one is its own locked read-modify-write through the
#    library, so a failure warns W-STATE and leaves the file untouched.
# ---------------------------------------------------------------------------

wv_jq_str() {
  # wv_jq_str <value> -> that value as a properly escaped JSON string literal,
  # for splicing into a jq filter built as text (post-agent.sh's own idiom).
  jq -Rn --arg v "${1:-}" '$v'
}

wv_stale_successors() {
  # wv_stale_successors <code> -> the phases, transitively AFTER <code>, that
  # state.json currently records as `done`. A failed re-run of <code> invalidates
  # every one of them, and a successor left reading `done` is how a failed re-run
  # gets masked by the earlier success.
  local code="$1"
  local frontier="$code" next seen="" line rec c after
  local -a codes=()
  # One pass per generation over the (26-row) table; the DAG is small and this
  # keeps the walk obviously terminating.
  local guard=0
  while [ -n "$frontier" ] && [ "$guard" -lt 30 ]; do
    guard=$((guard + 1))
    next=""
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in ''|'#'*|"code"$'\t'*) continue ;; esac
      rec="${line//$'\t'/$'\x1f'}"
      local -a cells=()
      IFS=$'\x1f' read -r -a cells <<<"$rec"
      c="${cells[0]:-}"
      after="${cells[4]:-}"
      [ -n "$c" ] || continue
      case " $seen $frontier " in *" $c "*) continue ;; esac
      local p
      for p in ${frontier//,/ }; do
        case ",$after," in
          *",$p,"*) next="${next:+$next }$c"; break ;;
        esac
      done
    done < "$WV_PHASES_TSV"
    seen="${seen:+$seen }$frontier"
    frontier="${next// /,}"
    for c in $next; do codes+=("$c"); done
  done
  local out=""
  for c in "${codes[@]:-}"; do
    [ -n "$c" ] || continue
    if [ "$(printf '%s' "$WV_STATE" | jq -r --arg c "$c" '((.phases // {})[$c].status // "")' 2>/dev/null)" = "done" ]; then
      out="${out:+$out }$c"
    fi
  done
  printf '%s' "$out"
  return 0
}

# ---------------------------------------------------------------------------
# 6. Main.
# ---------------------------------------------------------------------------

WV_STOP_AGENT=""
WV_STOP_PHASE="unknown"
WV_STOP_ROLE="unknown"
WV_STOP_REQ="unknown"
WV_STOP_RES="unknown"
WV_STOP_JOINED=0
WV_STOP_SEEN=0        # this agent has already been ledgered (a replay/second stop)
WV_STOP_GATED=0       # the phase table applies to this stop
declare -a WV_STOP_WARN=()   # rendered rule warnings for the ledger + state

wv_neutralise() {
  # wv_neutralise <text> -> the same text with `W-` rewritten to `W_`.
  #
  # Every argument that reaches a reason is neutralised, because the arguments
  # carry text this hook did not write: a model id out of the transcript, the
  # first line of an artifact a subagent authored. A reason must contain exactly
  # ONE `W-` token — its own rule id — or the harness (and a reader) cannot tell
  # which rule fired. Same construction, and the same reason, as pre-agent.sh's
  # wv_rule_deny; the template is never touched, only the arguments.
  printf '%s' "${1//W-/W_}"
}

wv_stop_warn() {
  # wv_stop_warn <rule> [args…] — SubagentStop has no additionalContext channel,
  # so its warn channel is `state.phases[<phase>].warned` plus `warn:[…]` on the
  # ledger line (the corpus convention behind AC-395). Queued here, written by
  # the phase record and the ledger line below.
  local rule="$1"
  shift
  local -a args=()
  local arg
  for arg in "$@"; do args+=("$(wv_neutralise "$arg")"); done
  WV_STOP_WARN+=("$(wv_render "$rule" "${args[@]:-}")")
  return 0
}

wv_stop_block() {
  # wv_stop_block <rule> [args…] — wv_block with every argument neutralised.
  local rule="$1"
  shift
  if [ "$#" -eq 0 ]; then
    wv_block "$rule"
    return
  fi
  local -a args=()
  local arg
  for arg in "$@"; do args+=("$(wv_neutralise "$arg")"); done
  wv_block "$rule" "${args[@]}"
}

wv_was_blocked_for() {
  # wv_was_blocked_for <rule> — true when `active[<id>].blocked` already records
  # that rule for this agent. Reads `blocked_rules`, which wv_main fills once.
  case ",${blocked_rules:-}," in
    *",$1,"*) return 0 ;;
  esac
  return 1
}

wv_ledger_has_agent() {
  # wv_ledger_has_agent <id> — true when the ledger already holds a line for that
  # agent. This is the dedupe question in its most durable form — the ledger is
  # the record that must hold one line per agent — and it is read together with
  # the spool, because a line waiting there is a line the next drain appends.
  local ledger="$WV_WAVE_DIR/ledger.jsonl" id="$1"
  [ -f "$ledger" ] || return 1
  jq -Rr --arg id "$id" 'fromjson? // empty | select((.agent // "") == $id) | "hit"' \
    "$ledger" 2>/dev/null | command grep -q '^hit$'
}

wv_main() {
  wv_parse_stdin || return 0
  # Wired to SubagentStop only. Any other event has not been measured by this
  # script and says nothing (Global Constraint 3).
  [ "$WV_EVENT" = "SubagentStop" ] || return 0
  wv_project_root || return 0
  wv_state_read || return 0

  WV_STOP_AGENT="$WV_AGENT_ID"
  if [ -z "$WV_STOP_AGENT" ]; then
    # Every measured SubagentStop payload carries agent_id. Without it there is
    # nothing to join on and nothing to dedupe against, so a ledger line would
    # collide with every other such stop: report and stop.
    wv_warn W-STATE "a SubagentStop payload arrived with no agent_id, so it could not be joined to a launch record or ledgered; nothing was recorded for it"
    return 0
  fi

  local stop_active last_len transcript
  stop_active="$(wv_json 'if (.stop_hook_active // false) == true then "true" else "false" end')"
  [ "$stop_active" = "true" ] || stop_active="false"
  # jq counts Unicode scalar values, which is what "characters" means for the
  # 2,000-character cap (spec section 9's own definition).
  last_len="$(wv_json '(.last_assistant_message // "") | tostring | length')"
  case "$last_len" in ''|*[!0-9]*) last_len=0 ;; esac
  transcript="$(wv_json 'if has("agent_transcript_path") then ((.agent_transcript_path // "") | tostring) else "" end')"

  # ---- the join ----------------------------------------------------------
  local rec
  rec="$(printf '%s' "$WV_STATE" | jq -r --arg id "$WV_STOP_AGENT" '
      ((.active // {})[$id]) as $a
      | if ($a | type) == "object"
        then [ "1", ($a.phase // ""), ($a.role // ""), ($a.requested_model // ""),
               ($a.resolved_model // ""), ($a.status // "") ] | join("\u001f")
        else "0" end' 2>/dev/null)"
  local joined_status=""
  if [ "${rec%%$'\x1f'*}" = "1" ]; then
    IFS=$'\x1f' read -r WV_STOP_JOINED WV_STOP_PHASE WV_STOP_ROLE WV_STOP_REQ \
      WV_STOP_RES joined_status <<<"$rec"
    [ -n "$WV_STOP_PHASE" ] || WV_STOP_PHASE="unknown"
    [ -n "$WV_STOP_ROLE" ] || WV_STOP_ROLE="unknown"
    [ -n "$WV_STOP_REQ" ] || WV_STOP_REQ="unknown"
    [ -n "$WV_STOP_RES" ] || WV_STOP_RES="unknown"
  else
    WV_STOP_JOINED=0
    case "$WV_MODE" in
      solo)
        # Solo mode ledgers an untagged dispatch under phase SOLO (spec
        # section 6), and post-agent.sh normally records exactly that; an
        # unjoined stop in solo mode is the same thing one event earlier.
        WV_STOP_PHASE="SOLO"
        ;;
      *)
        wv_warn W-STATE "SubagentStop for agent $WV_STOP_AGENT found no state.active record to join, so post-agent.sh did not run for its launch (or the dispatch predates this wave); its spend is ledgered under phase \"unknown\" and no phase was judged"
        ;;
    esac
  fi
  # The library records a warning against a phase; from here we know it.
  WV_PHASE="$WV_STOP_PHASE"

  # The phase table applies only to a full/demo wave, only to a phase that IS a
  # row, and only when that row RUNS IN THIS MODE (spec section 6: `modes` is
  # `full`, `demo` or `full,demo`, and phases.tsv is not consulted at all in solo
  # mode). Without the mode clause a demo wave judged a full-only phase: it wrote
  # `phases.BC` and `rounds["BC/scanner"]` for a row that has no place in a demo
  # wave at all, which then unblocks a later `after: BC` for free.
  local row_ok=0 row_modes=""
  if wv_row_line "$WV_STOP_PHASE" >/dev/null; then
    row_ok=1
    row_modes="$(wv_row_get "$WV_STOP_PHASE" "$WV_COL_MODES")"
  fi
  case "$WV_MODE" in
    full|demo)
      if [ "$row_ok" = "1" ]; then
        case ",$row_modes," in
          *",$WV_MODE,"*)
            WV_STOP_GATED=1
            ;;
          *)
            wv_warn W-STATE "hooks/phases.tsv gives $WV_STOP_PHASE the modes \"$row_modes\", which do not include this wave's mode \"$WV_MODE\", so the phase was not judged at this stop and no round was counted; the dispatch should not have been tagged P:$WV_STOP_PHASE in a $WV_MODE wave"
            ;;
        esac
      fi
      ;;
  esac

  # ---- the transcript and the tier --------------------------------------
  wv_transcript_stats "$transcript"

  local tier_ok="null" tier_verified="false" req_name="-" req_rank=""
  if [ "$WV_STOP_GATED" = "1" ]; then
    local rolecol
    if rolecol="$(wv_role_column "$WV_STOP_ROLE")"; then
      case "$rolecol" in
        lead) req_name="$(wv_row_get "$WV_STOP_PHASE" "$WV_COL_LEAD")" ;;
        executor) req_name="$(wv_row_get "$WV_STOP_PHASE" "$WV_COL_EXECUTOR")" ;;
        reviewer) req_name="$(wv_row_get "$WV_STOP_PHASE" "$WV_COL_REVIEWER")" ;;
      esac
      [ -n "$req_name" ] || req_name="-"
    fi
  fi
  if [ "$req_name" != "-" ] && [ -n "$WV_TS_TIER" ]; then
    req_rank="$(wv_tier_rank "$req_name")" || req_rank=""
    case "$req_rank" in
      1|2|3|4)
        tier_verified="true"
        if [ "$WV_TS_TIER" -ge "$req_rank" ]; then
          tier_ok="true"
        else
          tier_ok="false"
          wv_stop_warn W-TAINT "$(wv_tier_name "$WV_TS_TIER")" "$req_name" \
            "$WV_TS_MODEL (phase $WV_STOP_PHASE)"
        fi
        ;;
    esac
  fi

  # ---- the write phase, under ONE lock acquisition -----------------------
  #
  # Everything below writes, and it all takes the same `.wave/lock`. Taken once,
  # here, for three reasons: the whole of this stop's record lands atomically;
  # nested acquisitions cost nothing (the library counts depth); and — the
  # binding one — a hook that took the lock separately for the drain, the state
  # write and the ledger append would wait out `flock -w 10` up to three times
  # over, and a SubagentStop hook has to be back inside the timeout it
  # advertises (AC-254: exit 0 within timeout + 1s).
  #
  # The expensive reads (the transcript, above) are deliberately OUTSIDE it, so
  # twenty agents stopping at once do not queue behind each other's file reads.
  #
  # When it cannot be taken at all, this hook has measured nothing it can record:
  # no phase is judged, no round moves, and the ledger line goes straight to the
  # spool — without waiting a second time — for the next acquisition to drain.
  local have_lock=0
  if wv_lock_acquire; then
    have_lock=1
    # A line an earlier hook could not write reaches the ledger before this one
    # reads it for the dedupe, and before Task 6's budget gate sums it.
    wv_ledger_drain_locked
  else
    wv_warn W-STATE "could not take the wave state lock $WV_WAVE_DIR/lock within 10s, so no phase was judged and no round was counted for agent $WV_STOP_AGENT; its ledger line is spooled instead"
  fi

  # Which rules has this agent already been blocked for? THE block-once key.
  #
  # `stop_hook_active` is not that key and cannot be: the measured log
  # (probe2-worktree-stopblock.log) records three stops for one agent, and the
  # flag is FALSE on the third — a hook keyed on the flag alone blocks the same
  # agent for the same reason again, and again, up to the harness's block cap.
  # A record survives every stop; a flag on one payload does not.
  local blocked_rules
  blocked_rules="$(printf '%s' "$WV_STATE" | jq -r --arg id "$WV_STOP_AGENT" \
    'try ((((.active // {})[$id].blocked) // []) | join(",")) catch ""' 2>/dev/null)"

  # Has this agent already been LEDGERED? That, and not "has it stopped before",
  # is the dedupe question: a stop that blocked for a lean return deliberately
  # leaves the ledger line to the stop that follows it, so keying the dedupe on
  # the stop record would lose that line for good. The spool counts as ledgered —
  # a line waiting there is a line the next drain will append.
  if wv_ledger_has_agent "$WV_STOP_AGENT" \
    || [ -f "$WV_WAVE_DIR/ledger.pending/$WV_STOP_AGENT.json" ]; then
    WV_STOP_SEEN=1
  fi

  # ---- the lean-return facts, before anything is recorded ----------------
  #
  # Length only: whether it BLOCKS also depends on stop_hook_active, and whether
  # the ledger line waits for the next stop also depends on the artifact verdict
  # below.
  local lean_blocked_before=0
  wv_was_blocked_for W-LONG-RETURN && lean_blocked_before=1

  local long_return="false"
  if [ "$last_len" -gt "$WV_LONG_RETURN_CAP" ]; then long_return="true"; fi
  if [ "$lean_blocked_before" = "1" ]; then
    # This agent was already blocked once for a long return. Whatever length the
    # summary it has come back with is, the FACT stays on its ledger line (spec
    # section 8.5) — including on the deferred line this stop is about to write.
    long_return="true"
  fi
  local block_lean=0
  case "$WV_MODE" in
    full|demo)
      # The one-shot key is `lean_blocked_before`, read from the record — not
      # `stop_hook_active`. Keyed on the flag, a second stop carrying a SHORT
      # return was blocked again ("has 1999") and, because a lean-return block
      # defers the ledger line, that line was then never written at all: the
      # agent's whole spend vanished.
      #
      # `have_lock` is part of the condition too, because the block is only safe
      # as a one-shot: what stops the next stop from blocking again is the record
      # it leaves, and a hook that cannot write cannot leave one.
      if [ "$long_return" = "true" ] && [ "$stop_active" = "false" ] \
        && [ "$WV_STOP_SEEN" = "0" ] && [ "$have_lock" = "1" ] \
        && [ "$lean_blocked_before" = "0" ]; then
        block_lean=1
      fi
      ;;
    *)
      # Section 8 is not enforced in solo mode (spec section 6), so a long return
      # is neither blocked nor recorded there.
      long_return="false"
      ;;
  esac

  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  # ---- 1. the stop record, and the round counter with it ------------------
  #
  # First, because everything below reads "is any other agent of this phase still
  # running" and that answer is only true once this agent's own stop is on the
  # record. Written once: a second stop by the same agent must leave state.json
  # byte-identical (AC-237), so an already-`stopped` record is left alone.
  #
  # The round predicate is evaluated INSIDE the filter, under the lock, on the
  # state as it is on disk — not on the copy this process read at startup. Twenty
  # agents stopping at once each read a state in which nineteen siblings were
  # still running, so a predicate evaluated out here would leave the counter at
  # zero for the whole group. A round is one concurrent GROUP of the same phase
  # and role (spec section 8.7): that is why a fanout of three PDT writers is one
  # round and never three.
  # Only for an agent there IS a launch record for: writing `active[<id>]` for an
  # agent nothing launched would invent the phantom entry post-agent.sh refuses to
  # invent (AC-199), and it would be a record of a phase and role nobody knows.
  if [ "$have_lock" = "1" ] && [ "$WV_STOP_JOINED" = "1" ] && [ "$joined_status" != "stopped" ]; then
    local id_lit ts_lit upd
    id_lit="$(wv_jq_str "$WV_STOP_AGENT")"
    ts_lit="$(wv_jq_str "$ts")"
    upd="$(printf '.active[%s] = ((.active[%s] // {}) + {status: "stopped", stopped: %s})' \
      "$id_lit" "$id_lit" "$ts_lit")"
    if [ "$WV_STOP_GATED" = "1" ]; then
      local key_lit phase_lit role_lit
      key_lit="$(wv_jq_str "$WV_STOP_PHASE/$WV_STOP_ROLE")"
      phase_lit="$(wv_jq_str "$WV_STOP_PHASE")"
      role_lit="$(wv_jq_str "$WV_STOP_ROLE")"
      upd="$upd | (if (([ ((.active // {}) | to_entries[])"
      upd="$upd | select(.key != $id_lit)"
      upd="$upd | select(((.value.phase // \"\") == $phase_lit))"
      upd="$upd | select(((.value.role // \"\") == $role_lit))"
      upd="$upd | select(((.value.status // \"\") != \"stopped\")) ] | length) == 0)"
      upd="$upd then .rounds[$key_lit] = (((.rounds[$key_lit] // 0) | if type == \"number\" then . else 0 end) + 1) else . end)"
    fi
    wv_state_update "$upd"
  fi

  # The one-shot marker for the lean-return block, written beside the stop record
  # and inside the same held lock: the stop that follows the block reads it and
  # still records long_return on the ledger line, whatever length the summary it
  # comes back with is (spec section 8.5).
  if [ "$have_lock" = "1" ] && [ "$block_lean" = "1" ]; then
    wv_state_update "$(printf '.active[%s] = ((.active[%s] // {}) + {long_return: true})' \
      "$(wv_jq_str "$WV_STOP_AGENT")" "$(wv_jq_str "$WV_STOP_AGENT")")"
  fi

  # ---- 2. the artifact, at the closing role's stop, last one out ----------
  local status_new="" prev_status="" existing_agent="" verdict_rule=""
  local -a verdict_args=()
  prev_status="$(printf '%s' "$WV_STATE" | jq -r --arg c "$WV_STOP_PHASE" '((.phases // {})[$c].status // "")' 2>/dev/null)"
  existing_agent="$(printf '%s' "$WV_STATE" | jq -r --arg c "$WV_STOP_PHASE" '((.phases // {})[$c].agent // "")' 2>/dev/null)"

  local closing=""
  if [ "$WV_STOP_GATED" = "1" ]; then
    closing="$(wv_closing_role "$WV_STOP_PHASE")" || closing=""
  fi
  local is_closing=0 rolecol2=""
  if [ -n "$closing" ] && rolecol2="$(wv_role_column "$WV_STOP_ROLE")"; then
    [ "$rolecol2" = "$closing" ] && is_closing=1
  fi

  local verdict_blocked_before=0
  if [ "$have_lock" = "1" ] && [ "$is_closing" = "1" ]; then
    local siblings
    siblings="$(wv_running_siblings "$WV_STOP_PHASE")"
    if [ -z "$siblings" ]; then
      if wv_artifact_check "$WV_STOP_PHASE"; then
        status_new="done"
      else
        verdict_rule="$WV_AC_RULE"
        verdict_args=("${WV_AC_ARGS[@]}")
        wv_was_blocked_for "$verdict_rule" && verdict_blocked_before=1
        # Three outcomes, and the difference between them is what the next
        # dispatch reads:
        #   failed            this agent was ALREADY blocked for exactly this
        #                     rule, came back, and still has not produced the
        #                     artifact. There is nothing further this hook can do
        #                     — it must not block a third time — so the phase is
        #                     recorded as settled-failed and the wave stops on it.
        #   redo              a phase the state recorded as done now fails, so a
        #                     failed re-run can never be masked by the earlier
        #                     success (and its successors go stale).
        #   artifact-missing  the ordinary first failure. The RULE id on the block
        #                     (W-ARTIFACT vs W-MARKER) says which way the hand-off
        #                     was unacceptable.
        if [ "$verdict_blocked_before" = "1" ]; then
          status_new="failed"
        elif [ "$prev_status" = "done" ]; then
          status_new="redo"
        else
          status_new="artifact-missing"
        fi
      fi
    else
      # The closing role has stopped and the check was SKIPPED because a sibling
      # of the same phase is still open. For a live fan-out that is correct and
      # temporary. For a sibling that was killed, rate-limited, or whose own
      # SubagentStop never arrived, it is a wave that waits for an event that will
      # not come — silently, because the skip writes nothing at all. So the skip
      # is reported, and the report names WHO it is waiting for.
      wv_warn W-STATE "$WV_STOP_PHASE's closing role ($WV_STOP_ROLE, agent $WV_STOP_AGENT) stopped while state.active still shows these agents of the same phase running: $siblings — so the artifact check was skipped and the phase was not judged; if those agents are gone (killed, rate-limited, or their SubagentStop was lost), remove their entries from state.active in $WV_STATE_FILE and re-dispatch $WV_STOP_PHASE's closing role"
    fi
  fi

  local warnjson="[]" warns_new=0
  if [ "${#WV_STOP_WARN[@]}" -gt 0 ]; then
    warnjson="$(printf '%s\n' "${WV_STOP_WARN[@]}" | jq -Rsc 'split("\n") | map(select(. != ""))')"
    # How many of them are not ALREADY on the phase's record. A replayed stop
    # renders the same warning text again, and appending it again is how
    # `phases[X].warned` grew 1 -> 2 -> 3 across three identical stops and made
    # `state.json` differ every time. The list is a SET.
    warns_new="$(printf '%s' "$WV_STATE" | jq -r --arg c "$WV_STOP_PHASE" --argjson w "$warnjson" \
      'try ((((.phases // {})[$c].warned) // []) as $have
            | [ $w[] | select(([$have[]] | index(.)) == null) ] | length) catch ($w | length)' 2>/dev/null)"
    case "$warns_new" in ''|*[!0-9]*) warns_new=1 ;; esac
  fi

  # ---- 3. the phase record -----------------------------------------------
  #
  # Skipped entirely when the SAME agent stops again with the same verdict, which
  # is what keeps a second stop byte-identical (AC-236, AC-237) while still
  # letting a LATER stop record a real change — the agent that was blocked for a
  # missing artifact and has now written it marks its phase done on its second
  # stop, which is the whole point of blocking it.
  if [ -n "$status_new" ]; then
    local same=0
    if [ "$status_new" = "$prev_status" ] && [ "$existing_agent" = "$WV_STOP_AGENT" ] \
      && [ "$warns_new" = "0" ]; then
      same=1
    fi
    if [ "$same" = "0" ]; then
      local newrec
      newrec="$(jq -nc --arg s "$status_new" --arg at "$ts" --arg agent "$WV_STOP_AGENT" \
        --arg prev "$prev_status" --arg findings "$WV_AC_FINDINGS" --arg open "$WV_AC_OPEN" \
        --argjson tainted "$([ "$tier_ok" = "false" ] && printf 'true' || printf 'false')" '
          {status: $s, at: $at, agent: $agent}
          + (if $prev == "" then {} else {prev: $prev} end)
          + (if $findings == "" then {} else {findings: ($findings | tonumber)} end)
          + (if $open == "" then {} else {open: ($open | tonumber)} end)
          + (if $tainted then {tainted: true} else {} end)')"
      local tainted_extra="{}"
      if [ "$tier_ok" = "false" ]; then
        tainted_extra="$(jq -nc --arg m "$WV_TS_MODEL" --arg used "$(wv_tier_name "$WV_TS_TIER")" \
          --arg req "$req_name" '{tainted_model: $m, tainted_used: $used, tainted_required: $req}')"
      fi
      local code_lit
      code_lit="$(wv_jq_str "$WV_STOP_PHASE")"
      local filter
      filter="$(printf '.phases[%s] = ((.phases[%s] // {} | with_entries(select(.key == "warned"))) + %s + %s | .warned = (((.warned // []) + %s) | unique) | if ((.warned | length) == 0) then del(.warned) else . end)' \
        "$code_lit" "$code_lit" "$newrec" "$tainted_extra" "$warnjson")"
      # A failed re-run invalidates every successor the state still calls done.
      if [ "$status_new" = "redo" ]; then
        local s
        for s in $(wv_stale_successors "$WV_STOP_PHASE"); do
          filter="$filter | .phases[$(wv_jq_str "$s")].stale = true"
        done
      fi
      wv_state_update "$filter"
    fi
  fi

  # ---- 4. the ledger line ------------------------------------------------
  #
  # One per agent_id, with the closed key set of spec section 9 plus only the
  # extras that section names. Appended even when the phase failed its artifact
  # check — the tokens were spent either way, and a wave that hides failed spend
  # cannot be scored.
  #
  # The one stop that does NOT write it is the one that blocks for a lean return
  # and nothing else: that agent is about to keep working (it has a report to
  # write), so its totals are not final, and a line written now would dedupe the
  # real one away.
  # WHICH rule this stop will emit, decided once, here, because three later
  # things read it: whether the ledger line waits for the next stop, what goes on
  # `active[<id>].blocked`, and what reaches stdout.
  #
  # An artifact verdict outranks a long return (the precedence pinned in
  # hooks/reasons.tsv), `stop_hook_active` disarms the artifact block, and the
  # RECORD disarms both — a rule already blocked for this agent is never blocked
  # for it again.
  local emit_rule=""
  if [ -n "$verdict_rule" ] && [ "$stop_active" = "false" ] \
    && [ "$verdict_blocked_before" = "0" ]; then
    emit_rule="$verdict_rule"
  elif [ "$block_lean" = "1" ]; then
    emit_rule=W-LONG-RETURN
  fi

  local defer_ledger=0
  if [ "$emit_rule" = "W-LONG-RETURN" ]; then
    defer_ledger=1
  fi

  if [ "$WV_STOP_SEEN" = "0" ] && [ "$defer_ledger" = "0" ]; then
    local extras
    extras="$(jq -nc --arg note "$WV_TS_NOTE" --arg skipped "$WV_TS_SKIPPED" \
      --arg excluded "$WV_TS_EXCLUDED" --arg turns "$WV_TS_TURNS" \
      --argjson long "$long_return" --argjson warn "$warnjson" '
        {}
        + (if $note != "" then {note: $note}
           elif ($excluded | tonumber) > 0 then
             {note: ("\($excluded) of \($turns) assistant line(s) were excluded from the tier vote (no message.model, or output_tokens 0)")}
           else {} end)
        + (if ($skipped | tonumber) > 0 then {skipped_lines: ($skipped | tonumber)} else {} end)
        + (if $long then {long_return: true} else {} end)
        + (if ($warn | length) > 0 then {warn: $warn} else {} end)')"
    local line
    line="$(jq -nc --arg agent "$WV_STOP_AGENT" --arg phase "$WV_STOP_PHASE" \
      --arg role "$WV_STOP_ROLE" --arg requested "$WV_STOP_REQ" --arg resolved "$WV_STOP_RES" \
      --argjson tier_ok "$tier_ok" --argjson tier_verified "$tier_verified" \
      --argjson input "$WV_TS_INPUT" --argjson output "$WV_TS_OUTPUT" \
      --argjson cache_read "$WV_TS_CACHE_READ" --argjson cache_create "$WV_TS_CACHE_CREATE" \
      --argjson turns "$WV_TS_TURNS" --arg stopped "$ts" --argjson extras "$extras" '
        {agent: $agent, phase: $phase, role: $role, requested: $requested, resolved: $resolved,
         tier_ok: $tier_ok, tier_verified: $tier_verified, input: $input, output: $output,
         cache_read: $cache_read, cache_create: $cache_create, turns: $turns, stopped: $stopped}
        + $extras')"
    if [ -n "$line" ]; then
      if [ "$have_lock" = "1" ]; then
        wv_ledger_append "$line"
      else
        wv_ledger_spool "$line"
      fi
    else
      wv_warn W-STATE "the ledger line for agent $WV_STOP_AGENT could not be rendered, so this step is missing from the token ledger"
    fi
  fi

  # ---- 5. the block-once record -------------------------------------------
  #
  # Written under the SAME held lock as everything else, before the object
  # reaches stdout: the record is what makes the block a one-shot, and a block
  # emitted without it would be repeated on the agent's next stop (the measured
  # log shows a third stop with stop_hook_active FALSE, so the flag cannot carry
  # this).
  if [ "$have_lock" = "1" ] && [ -n "$emit_rule" ]; then
    local id_lit2 rule_lit
    id_lit2="$(wv_jq_str "$WV_STOP_AGENT")"
    rule_lit="$(wv_jq_str "$emit_rule")"
    wv_state_update "$(printf '.active[%s] = ((.active[%s] // {}) + {blocked: (((.active[%s].blocked // []) + [%s]) | unique)})' \
      "$id_lit2" "$id_lit2" "$id_lit2" "$rule_lit")"
  fi

  if [ "$have_lock" = "1" ]; then
    wv_lock_release
  fi

  # ---- the one block, and the terminal close ----------------------------
  #
  # Both are last, so every record above is already on disk whichever way this
  # goes, and `stop_hook_active` disarms every block path without disarming any
  # of the recording.
  case "$emit_rule" in
    W-ARTIFACT|W-MARKER)
      wv_stop_block "$emit_rule" "${verdict_args[@]}"
      return 0
      ;;
    W-LONG-RETURN)
      wv_stop_block W-LONG-RETURN "$last_len" "$WV_STOP_PHASE" "$WV_STOP_ROLE" "$WV_STOP_AGENT"
      return 0
      ;;
  esac

  # No block. A phase that failed its check is still not closed out, so the
  # terminal close is reached only by a phase that is genuinely done.
  if [ -n "$verdict_rule" ]; then
    return 0
  fi

  if [ "$status_new" = "done" ]; then
    wv_close_if_terminal "$WV_STOP_PHASE"
  fi
  return 0
}

wv_close_if_terminal() {
  # Hands the terminality question to scripts/wave-close.sh, which derives the
  # mode's terminal phase from hooks/phases.tsv and is a silent no-op for every
  # other phase. Its stdout is captured and asserted EMPTY: that script's
  # --if-terminal contract says it prints only to stderr, and this hook's stdout
  # may carry nothing but its own single JSON object.
  local code="$1"
  local closer="$WV_PLUGIN_DIR/scripts/wave-close.sh"
  [ -f "$closer" ] || return 0
  local out
  out="$(CLAUDE_PROJECT_DIR="$WV_ROOT" bash "$closer" --if-terminal "$code" 2>/dev/null)"
  if [ -n "$out" ]; then
    wv_warn W-STATE "scripts/wave-close.sh --if-terminal $code wrote to stdout ($out), which would corrupt this hook's JSON channel; the output was discarded and the wave may not be closed"
  fi
  return 0
}

wv_main
# SubagentStop has no additionalContext channel, so queued library warnings go
# to stderr; a block has already written the event's one JSON object.
wv_emit_flush
exit 0
