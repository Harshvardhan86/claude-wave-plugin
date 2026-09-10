#!/usr/bin/env bash
# scripts/wave-scorecard.sh — renders .wave/ledger.jsonl as a scorecard
# (spec section 9): phase, role, model, output tokens, budget, ratio, rework
# count, plus (for TDE-GREEN) output tokens per changed line from
# `git diff --shortstat <base_sha>` and the passing-test count from
# .wave/green.md.
#
# Usage:
#   wave-scorecard.sh [--out <path>]
#
# Default output path is <project>/.wave/scorecard.md (the path
# scripts/hooks/stop.sh's W-SCORECARD pointer names); --out overrides it.
# The table is ALSO printed to stdout, plain text, so a human running this
# by hand sees it immediately without opening the file.
#
# This is a lifecycle script, not a hook: it prints plain human-readable
# text, uses `set -u` (never `set -e`, Global Constraint 8), and exits 0
# with a clear message when there is no project, no wave, or no ledger to
# score -- a scorecard with nothing to show is not an error.
#
# Design choices this script makes that spec section 9 leaves open (no AC
# in ac-final.md governs the scorecard's exact rendering), recorded here
# rather than only in the task report:
#   - One table row per ledger line (the ledger IS the source the table
#     renders), not one row per phase: a fanned-out phase or a reworked one
#     legitimately has more than one agent, and collapsing them would hide
#     exactly the rework this table exists to surface.
#   - "Budget" and "Ratio" are phase-level (hooks/budgets.tsv has no
#     per-role column): the budget shown on every row of a phase is that
#     phase's EFFECTIVE budget (its budgets.tsv row x its phases.tsv fanout
#     column, spec section 9), and the ratio is that phase's cumulative
#     ledger output divided by the effective budget -- the same figure
#     pre-agent.sh's own W-BUDGET gate would compute, so this table and that
#     gate can never quietly disagree.
#   - "Rework count" is rounds - 1 for that phase/role (state.json's
#     rounds["<phase>/<role>"], read verbatim from lib.sh's own key shape):
#     round 1 is the first attempt, not yet a rework: a phase/role that ran
#     once shows rework 0, one that had to run twice shows rework 1.
set -u

WV_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/hooks/lib.sh
source "$WV_SCRIPT_DIR/hooks/lib.sh"

wv_die() {
  printf 'wave-scorecard.sh: %s\n' "$*" >&2
  exit 1
}

out_path=""
while [ $# -gt 0 ]; do
  case "$1" in
    --out)
      [ $# -ge 2 ] || wv_die "--out requires a value"
      out_path="$2"; shift 2 ;;
    *)
      wv_die "unknown argument: $1" ;;
  esac
done

# ---------------------------------------------------------------------------
# 1. Project root. Reuses lib.sh's wv_project_root (CLAUDE_PROJECT_DIR, else
#    cwd with a worktree suffix stripped, else the nearest ancestor holding
#    .wave/state.json) -- a closed wave still has a state.json, so this
#    keeps working after the wave is closed, which is exactly when a human
#    is most likely to run this by hand.
# ---------------------------------------------------------------------------

if ! wv_project_root; then
  printf 'wave-scorecard.sh: no project with a .wave/state.json was found from %s; nothing to score.\n' "$PWD"
  exit 0
fi

wave_dir="$WV_ROOT/.wave"
ledger="$wave_dir/ledger.jsonl"
state_file="$wave_dir/state.json"

if [ ! -s "$ledger" ]; then
  printf 'wave-scorecard.sh: no ledger at %s; nothing has been dispatched yet.\n' "$ledger"
  exit 0
fi

[ -n "$out_path" ] || out_path="$wave_dir/scorecard.md"

# ---------------------------------------------------------------------------
# 2. hooks/phases.tsv (fanout per phase) and hooks/budgets.tsv (output-token
#    budget per phase), both read from the PLUGIN directory (WV_PLUGIN_DIR,
#    set by lib.sh), never the project root -- these are the framework's own
#    policy data, not per-project state.
# ---------------------------------------------------------------------------

wv_sc_fanout_for() {
  # Reuses lib.sh's own wv_row_get/WV_COL_FANOUT (section 7b) rather than
  # re-parsing hooks/phases.tsv by hand: tab is IFS WHITESPACE, so a bare
  # `IFS=$'\t' read` collapses the empty "after" cell on the AC/AD rows and
  # silently shifts every column after it (lib.sh's wv_row_line docstring) --
  # exactly the bug a from-scratch parser here would reintroduce.
  local phase="$1" fo
  fo="$(wv_row_get "$phase" "$WV_COL_FANOUT" 2>/dev/null)"
  printf '%s' "${fo:-1}"
}

wv_sc_budget_for() {
  local phase="$1" code tokens
  local budgets_tsv="$WV_PLUGIN_DIR/hooks/budgets.tsv"
  [ -f "$budgets_tsv" ] || { printf ''; return; }
  while IFS=$'\t' read -r code tokens; do
    case "$code" in ''|'#'*|code) continue ;; esac
    if [ "$code" = "$phase" ]; then
      printf '%s' "$tokens"
      return
    fi
  done < "$budgets_tsv"
  printf ''
}

# ---------------------------------------------------------------------------
# 3. Read the ledger: skip lines that do not parse (a torn or interleaved
#    line is a lock defect elsewhere, never a reason for this script to
#    crash -- Global Constraint 8).
# ---------------------------------------------------------------------------

wv_sc_rounds_for() {
  # wv_sc_rounds_for <phase> <role> -> state.rounds["<phase>/<role>"], or
  # empty when state.json is unreadable or the key is absent.
  local phase="$1" role="$2"
  [ -f "$state_file" ] || { printf ''; return; }
  jq -r --arg k "$phase/$role" '.rounds[$k] // empty' "$state_file" 2>/dev/null
}

declare -A wv_sc_phase_total=()

# First pass: per-phase output total (for the ratio column).
while IFS= read -r line; do
  [ -n "$line" ] || continue
  jq -e . >/dev/null 2>&1 <<<"$line" || continue
  phase="$(jq -r '.phase // "unknown"' <<<"$line")"
  output="$(jq -r '.output // 0' <<<"$line")"
  case "$output" in ''|*[!0-9]*) output=0 ;; esac
  wv_sc_phase_total["$phase"]=$(( ${wv_sc_phase_total["$phase"]:-0} + output ))
done < "$ledger"

wv_sc_ratio_for() {
  # wv_sc_ratio_for <phase> -> "<total>/<effective-budget>" or "-" when the
  # phase has no budget row (spec section 9: "a phase with no budget row ...
  # never produces a W-BUDGET deny" -- the scorecard mirrors that: no budget
  # means no ratio, not a divide-by-zero).
  local phase="$1" total budget fanout effective
  total="${wv_sc_phase_total[$phase]:-0}"
  budget="$(wv_sc_budget_for "$phase")"
  if [ -z "$budget" ] || [ "$budget" = "0" ]; then
    printf '-'
    return
  fi
  fanout="$(wv_sc_fanout_for "$phase")"
  case "$fanout" in ''|*[!0-9]*) fanout=1 ;; esac
  effective=$(( budget * fanout ))
  [ "$effective" -gt 0 ] || { printf '-'; return; }
  awk -v t="$total" -v e="$effective" 'BEGIN { printf "%.2fx", t / e }'
}

# ---------------------------------------------------------------------------
# 4. Render the table.
# ---------------------------------------------------------------------------

wv_sc_out=""
wv_sc_append() { wv_sc_out="${wv_sc_out}$*"$'\n'; }

wv_wave_id="$(jq -r '.wave // "unknown"' "$state_file" 2>/dev/null)"
[ -n "$wv_wave_id" ] && [ "$wv_wave_id" != "null" ] || wv_wave_id="unknown"

wv_sc_append "# Wave $wv_wave_id scorecard"
wv_sc_append ""
wv_sc_append "| Phase | Role | Model | Output Tokens | Budget | Ratio | Rework |"
wv_sc_append "|---|---|---|---|---|---|---|"

n_rows=0
while IFS= read -r line; do
  [ -n "$line" ] || continue
  jq -e . >/dev/null 2>&1 <<<"$line" || continue
  n_rows=$((n_rows + 1))
  phase="$(jq -r '.phase // "unknown"' <<<"$line")"
  role="$(jq -r '.role // "unknown"' <<<"$line")"
  model="$(jq -r '.resolved // "unknown"' <<<"$line")"
  output="$(jq -r '.output // 0' <<<"$line")"
  case "$output" in ''|*[!0-9]*) output=0 ;; esac

  budget="$(wv_sc_budget_for "$phase")"
  fanout="$(wv_sc_fanout_for "$phase")"
  case "$fanout" in ''|*[!0-9]*) fanout=1 ;; esac
  if [ -n "$budget" ] && [ "$budget" != "0" ]; then
    effective_budget=$(( budget * fanout ))
  else
    effective_budget="-"
  fi
  ratio="$(wv_sc_ratio_for "$phase")"

  rounds="$(wv_sc_rounds_for "$phase" "$role")"
  case "$rounds" in ''|*[!0-9]*) rework=0 ;; *) rework=$(( rounds > 0 ? rounds - 1 : 0 )) ;; esac

  wv_sc_append "| $phase | $role | $model | $output | $effective_budget | $ratio | $rework |"
done < "$ledger"

wv_sc_append ""

# ---------------------------------------------------------------------------
# 5. TDE-GREEN: output tokens per changed line, and the passing-test count.
# ---------------------------------------------------------------------------

tde_green_output="${wv_sc_phase_total[TDE-GREEN]:-0}"
base_sha="$(jq -r '.base_sha // empty' "$state_file" 2>/dev/null)"

changed_lines=""
if [ -n "$base_sha" ]; then
  shortstat="$(git -C "$WV_ROOT" diff --shortstat "$base_sha" 2>/dev/null)"
  ins="$(printf '%s' "$shortstat" | command grep -oE '[0-9]+ insertion' | command grep -oE '[0-9]+')"
  del="$(printf '%s' "$shortstat" | command grep -oE '[0-9]+ deletion' | command grep -oE '[0-9]+')"
  [ -n "$ins" ] || ins=0
  [ -n "$del" ] || del=0
  changed_lines=$(( ins + del ))
fi

wv_sc_append "## TDE-GREEN"
wv_sc_append ""
if [ "$tde_green_output" -gt 0 ] && [ -n "$changed_lines" ] && [ "$changed_lines" -gt 0 ]; then
  per_line="$(awk -v t="$tde_green_output" -v c="$changed_lines" 'BEGIN { printf "%.2f", t / c }')"
  wv_sc_append "- Output tokens: $tde_green_output"
  wv_sc_append "- Changed lines since $base_sha (\`git diff --shortstat\`): $changed_lines"
  wv_sc_append "- Output tokens per changed line: $per_line"
else
  wv_sc_append "- Output tokens: $tde_green_output"
  wv_sc_append "- Output tokens per changed line: unavailable (no base_sha, no diff, or no TDE-GREEN spend yet)"
fi

wv_sc_append ""
wv_sc_append "## Passing tests"
wv_sc_append ""

green_md="$wave_dir/green.md"
passing=""
if [ -f "$green_md" ]; then
  marker="$(command grep -oE '^GREEN-VERIFIED passing=[1-9][0-9]* failing=0$' "$green_md" 2>/dev/null | head -n1)"
  if [ -n "$marker" ]; then
    passing="$(printf '%s' "$marker" | command grep -oE 'passing=[0-9]+' | command grep -oE '[0-9]+')"
  fi
fi

if [ -n "$passing" ]; then
  wv_sc_append "- Passing tests (from $green_md): $passing"
else
  wv_sc_append "- Passing tests: unknown ($green_md is absent or has no GREEN-VERIFIED marker yet)"
fi

# ---------------------------------------------------------------------------
# 6. Write + print.
# ---------------------------------------------------------------------------

mkdir -p "$(dirname "$out_path")" 2>/dev/null
if ! printf '%s' "$wv_sc_out" > "$out_path" 2>/dev/null; then
  printf 'wave-scorecard.sh: could not write %s; printing to stdout only.\n' "$out_path" >&2
fi

printf '%s' "$wv_sc_out"
exit 0
