#!/usr/bin/env bash
# scripts/hooks/pre-compact.sh — the PreCompact hook (spec section 10,
# invariant 7's CHECKPOINT half; the STOP half is not enforceable — the
# platform ignores PreCompact's own stdout entirely and compaction proceeds
# regardless, so this script never tries to block it, and its exit code and
# stdout are both irrelevant to the platform).
#
# Writes .wave/checkpoints/<ISO-ts>-precompact.md from state.json and the
# ledger, and does nothing else: no subprocess is spawned (Task brief AC-317
# — this cannot fail for lack of context, because it never asks anything for
# context), and an unwritable .wave/ warns to stderr and still exits 0 —
# PreCompact has no additionalContext channel (lib.sh's
# wv_warn_channel_is_stdout), so a W-STATE warning here is stderr-only.
#
# Kept on in every mode including solo (AC-336): like the commit guard, this
# is a cheap invariant, not part of the tag/order/round machinery solo turns
# off.

set -u

WV_HOOK_DIR="$(cd "${BASH_SOURCE[0]%/*}" 2>/dev/null && pwd)"
# shellcheck source=scripts/hooks/lib.sh
source "$WV_HOOK_DIR/lib.sh"

wv_pc_artifact_present() {
  # wv_pc_artifact_present <glob> -> true if at least one file under the
  # project root matches <glob> (which may be a plain path or carry a `*`,
  # e.g. hooks/phases.tsv's `.wave/checkpoints/*-ccp.md` CCP row). Never
  # fails: an unmatched glob just expands to itself, which then simply does
  # not exist.
  local glob="$1" f
  for f in "$WV_ROOT"/$glob; do
    [ -e "$f" ] && return 0
  done
  return 1
}

wv_pc_artifact_inventory() {
  # Lists which of hooks/phases.tsv's declared artifacts (column
  # WV_COL_ARTIFACT, skipping `-`) actually exist on disk right now, one per
  # line, de-duplicated (BC's findings artifact and DS's share no path, but a
  # future row could).
  #
  # Tabs are re-delimited to US (0x1f) before anything reads them, same as
  # lib.sh's wv_row_line/wv_row_get: tab is IFS WHITESPACE, so a plain
  # `IFS=$'\t' read -r a b c ...` collapses two adjacent tabs into one
  # delimiter and silently shifts every named column after an empty cell —
  # and `after` (column 5) IS empty on the AC row, which shifted this
  # function's `artifact` right onto the marker column and made
  # `.wave/ac.md` invisible to the inventory even when present on disk.
  [ -f "$WV_PHASES_TSV" ] || return 0
  local line rec artifact seen=""
  local -a cells
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*|"code"$'\t'*) continue ;; esac
    rec="${line//$'\t'/$'\x1f'}"
    cells=()
    IFS=$'\x1f' read -r -a cells <<<"$rec"
    artifact="${cells[$((WV_COL_ARTIFACT - 1))]:-}"
    [ -n "$artifact" ] && [ "$artifact" != "-" ] || continue
    case " $seen " in *" $artifact "*) continue ;; esac
    seen="$seen $artifact"
    if wv_pc_artifact_present "$artifact"; then
      printf '%s\n' "- $artifact"
    fi
  done < "$WV_PHASES_TSV"
  return 0
}

wv_pc_phase_summary() {
  # One line per phase state.json actually records, "<CODE>: <status>" (plus
  # " (tainted)" when the phase record says so) — this is the "phases
  # done/failed/tainted" the task brief asks for, read straight from the
  # state the framework already maintains rather than re-derived.
  [ -n "$WV_STATE" ] || return 0
  printf '%s' "$WV_STATE" | jq -r '
    (.phases // {}) | to_entries | sort_by(.key)[] |
    "- " + .key + ": " + (.value.status // "unknown") +
    (if (.value.tainted // false) then " (tainted)" else "" end)
  ' 2>/dev/null
  return 0
}

wv_pc_ledger_summary() {
  # The ledger's output-token totals: a grand total plus one line per phase,
  # summed straight from .wave/ledger.jsonl. A missing or unparseable ledger
  # gives "no ledger entries yet" rather than an error — this checkpoint must
  # never fail for lack of spend to report.
  local ledger="$WV_WAVE_DIR/ledger.jsonl"
  [ -s "$ledger" ] || { printf 'no ledger entries yet\n'; return 0; }
  jq -R -r -n '
    [inputs]
    | map(try fromjson catch empty)
    | map(select(type == "object"))
    | (reduce .[] as $l (0; . + (($l.output // 0) | if type == "number" then floor else 0 end))) as $total
    | (reduce .[] as $l ({}; .[$l.phase // "unknown"] += (($l.output // 0) | if type == "number" then floor else 0 end))) as $byphase
    | "total output tokens: \($total)",
      ($byphase | to_entries | sort_by(.key)[] | "- \(.key): \(.value)")
  ' < "$ledger" 2>/dev/null
  return 0
}

wv_pc_write_checkpoint() {
  local file="$1" trigger="$2" last_done
  last_done="none"
  case "$WV_MODE" in
    full|demo) last_done="$(wv_last_done_phase)" ;;
  esac

  {
    printf '# Wave %s checkpoint (PreCompact, trigger=%s)\n\n' "$WV_WAVE" "$trigger"
    # `--` is load-bearing: a format string starting with "- " (dash-space)
    # is otherwise parsed by bash's printf builtin as an unknown OPTION
    # (`printf: - : invalid option`), which fails silently here because the
    # whole block is redirected with `2>/dev/null` — the six lines below
    # this comment previously vanished from every checkpoint with no error
    # surfaced anywhere (AC-315 gap; see compact-315-content-verify.sh,
    # which reads the written file back and would have caught it).
    printf -- '- feature: %s\n' "$(printf '%s' "$WV_STATE" | jq -r '.feature // "unknown"' 2>/dev/null)"
    printf -- '- wave: %s\n' "$WV_WAVE"
    printf -- '- mode: %s\n' "$WV_MODE"
    printf -- '- enforce: %s\n' "$WV_ENFORCE"
    printf -- '- last phase done: %s\n' "$last_done"
    printf -- '- trigger: %s\n\n' "$trigger"
    printf '## Phases\n\n'
    wv_pc_phase_summary
    printf '\n## Artifacts present under .wave/\n\n'
    local inv
    inv="$(wv_pc_artifact_inventory)"
    if [ -n "$inv" ]; then
      printf '%s\n' "$inv"
    else
      printf '(none yet)\n'
    fi
    printf '\n## Ledger\n\n'
    wv_pc_ledger_summary
    printf '\n## Resume\n\n'
    printf 'Resume: cat "%s" and continue wave %s in mode %s from phase %s onward.\n' \
      "${file#"$WV_ROOT"/}" "$WV_WAVE" "$WV_MODE" "$last_done"
  } > "$file" 2>/dev/null
}

wv_main() {
  wv_parse_stdin || return 0
  [ "$WV_EVENT" = "PreCompact" ] || return 0
  wv_project_root || return 0
  wv_state_read || return 0

  local trigger
  trigger="$(wv_json '.trigger // "unknown"')"
  [ -n "$trigger" ] || trigger="unknown"

  local dir="$WV_WAVE_DIR/checkpoints"
  if ! mkdir -p "$dir" 2>/dev/null || [ ! -w "$dir" ]; then
    wv_warn W-STATE "could not create or write $dir, so no PreCompact checkpoint was recorded for this compaction"
    return 0
  fi

  local ts file
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  file="$dir/${ts}-precompact.md"
  # A collision (two compactions landing in the same UTC second) gets a
  # numeric suffix rather than silently overwriting an earlier checkpoint —
  # AC-319 requires that earlier checkpoints stay byte-identical.
  local n=2
  while [ -e "$file" ]; do
    file="$dir/${ts}-precompact-$n.md"
    n=$((n + 1))
  done

  wv_pc_write_checkpoint "$file" "$trigger"
  if [ ! -s "$file" ]; then
    wv_warn W-STATE "could not write $file, so no PreCompact checkpoint was recorded for this compaction"
  fi
  return 0
}

wv_main
# PreCompact has no additionalContext channel; any queued warning goes to
# stderr only (lib.sh's wv_emit_flush).
wv_emit_flush
exit 0
