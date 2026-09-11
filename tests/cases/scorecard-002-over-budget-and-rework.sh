#!/usr/bin/env bash
# tests/cases/scorecard-002-over-budget-and-rework.sh
#
# A seeded ledger with a phase over its (fanout-scaled) budget and a
# rounds>1 (rework) row: the table names the phase, shows a ratio above
# 1.00x for the over-budget phase, and a non-zero rework count for the
# reworked phase/role -- while an un-reworked row shows rework 0.
set -u

# shellcheck source=tests/lib/assert.sh
source "$(dirname "$0")/../lib/assert.sh"

name="$(basename "$0" .sh)"
log="${WV_CASE_LOG:-$WV_RUN_TMP/logs/$name.log}"
mkdir -p "$(dirname "$log")"

rc=0
fail() { printf 'ASSERT FAIL: %s\n' "$*" >&2; rc=1; }

WV_PROJECT="$(mkproj)"
: > "$WV_PROJECT/README.md"
git -C "$WV_PROJECT" add README.md
git -C "$WV_PROJECT" -c commit.gpgsign=false commit -q -m init
base_sha="$(git -C "$WV_PROJECT" rev-parse HEAD)"

seed_state state/valid-full.json
# valid-full.json's base_sha (2294917) is not a real object in this fresh
# repo; overwrite it with one `git diff --shortstat` can actually resolve,
# and seed rounds so TDE-GREEN/executor shows a rework and AC/reviewer does
# not.
jq --arg sha "$base_sha" \
   '.base_sha = $sha | .rounds = {"TDE-GREEN/executor": 2, "AC/reviewer": 1}' \
   "$WV_PROJECT/.wave/state.json" > "$WV_PROJECT/.wave/state.json.tmp"
mv "$WV_PROJECT/.wave/state.json.tmp" "$WV_PROJECT/.wave/state.json"

# hooks/budgets.tsv: TDE-GREEN=3000, fanout(TDE-GREEN)=1 -> effective 3000.
# 2000+2500=4500 > 3000 -> over budget.
cat > "$WV_PROJECT/.wave/ledger.jsonl" <<'LEDGER'
{"agent":"a1","phase":"AC","role":"reviewer","resolved":"opus","output":100,"input":10}
{"agent":"a2","phase":"TDE-GREEN","role":"executor","resolved":"sonnet","output":2000,"input":10}
{"agent":"a3","phase":"TDE-GREEN","role":"executor","resolved":"sonnet","output":2500,"input":10}
LEDGER

printf 'more\n' >> "$WV_PROJECT/README.md"
git -C "$WV_PROJECT" add README.md
git -C "$WV_PROJECT" -c commit.gpgsign=false commit -q -m changes

run_cli scripts/wave-scorecard.sh
[ "$CLI_EXIT" = "0" ] || fail "exit: want 0, got $CLI_EXIT (stderr: $CLI_STDERR)"

case "$CLI_STDOUT" in
  *"TDE-GREEN"*) : ;;
  *) fail "stdout does not mention TDE-GREEN: $CLI_STDOUT" ;;
esac

# The over-budget phase's ratio must read above 1.00x somewhere in its rows.
over_budget_row="$(printf '%s\n' "$CLI_STDOUT" | command grep '| TDE-GREEN |' | head -n1)"
[ -n "$over_budget_row" ] || fail "no TDE-GREEN table row found"
ratio_field="$(printf '%s' "$over_budget_row" | awk -F'|' '{print $7}' | tr -d ' ')"
case "$ratio_field" in
  *x)
    ratio_num="${ratio_field%x}"
    awk -v r="$ratio_num" 'BEGIN{exit !(r>1.0)}' \
      || fail "TDE-GREEN ratio $ratio_field is not above 1.00x"
    ;;
  *) fail "TDE-GREEN ratio field is not an 'Nx' shape: '$ratio_field'" ;;
esac

# The rework column: TDE-GREEN/executor (rounds=2) shows rework 1; AC/reviewer
# (rounds=1) shows rework 0.
tde_rework="$(printf '%s' "$over_budget_row" | awk -F'|' '{print $8}' | tr -d ' ')"
[ "$tde_rework" = "1" ] || fail "TDE-GREEN rework: want 1, got '$tde_rework'"

ac_row="$(printf '%s\n' "$CLI_STDOUT" | command grep '| AC |' | head -n1)"
[ -n "$ac_row" ] || fail "no AC table row found"
ac_rework="$(printf '%s' "$ac_row" | awk -F'|' '{print $8}' | tr -d ' ')"
[ "$ac_rework" = "0" ] || fail "AC rework: want 0, got '$ac_rework'"

# TDE-GREEN's own summary section names an actual per-changed-line figure
# (base_sha resolves in this fixture's real git history).
case "$CLI_STDOUT" in
  *"Output tokens per changed line: unavailable"*)
    fail "TDE-GREEN per-changed-line figure reported unavailable even though base_sha resolves"
    ;;
esac

[ -f "$WV_PROJECT/.wave/scorecard.md" ] || fail ".wave/scorecard.md was not written"
[ "$(cat "$WV_PROJECT/.wave/scorecard.md")" = "$CLI_STDOUT" ] \
  || fail "the written file and stdout disagree"

exit $rc
