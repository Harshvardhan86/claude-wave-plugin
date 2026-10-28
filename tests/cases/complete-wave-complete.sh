#!/usr/bin/env bash
# tests/cases/complete-wave-complete.sh — wave complete (design section 9).
#
# Every when=phase row of the active mode is settled (done, or skipped by
# mode or by a false condition). An unanswered flag is not settled. anytime
# rows never count. FINDINGS: 0 skips the BF- row; FINDINGS: 2 with that
# row not done does not. Demo is complete when its phase rows are settled
# (TEET done, predecessors done or skipped).
set -u

# shellcheck source=tests/lib/assert.sh
source "$(dirname "$0")/../lib/assert.sh"

name="${WV_CASE_NAME:-$(basename "$0" .sh)}"
log="${WV_CASE_LOG:-$WV_RUN_TMP/logs/$name.log}"
rc=0
fail() { printf 'ASSERT FAIL: %s\n' "$*" >&2; rc=1; }
printf 'RAN lib.sh %s decision=multi\n' "$name" >> "$log"

# shellcheck source=scripts/hooks/lib.sh
source "$WV_REPO_ROOT/scripts/hooks/lib.sh"

ALWAYS="AC ACB TDE-RED TDE-GREEN BC SEA DS BSEA OA TEET-TC TEET BTEET BTEET-X VB COMMIT CL CCP"

done_map() {
  # done_map [extra codes...] -> jq object of {code: {status:done,...}}
  local c
  {
    printf '%s\n' $ALWAYS
    printf '%s\n' "$@"
  } | awk 'NF && !seen[$0]++' | jq -R . | jq -s '
    map({(.): {status:"done", at:"2026-09-09T12:10:00Z", agent:"a0"}}) | add
  '
}

seed_clean_findings() {
  # Every scan's findings file reads FINDINGS: 0 (hooks/phases.tsv `findings`
  # column). A done scan always has its file in a real wave — it is the
  # scan's own artifact — and a done scan WITHOUT one is the gate's
  # W-ARTIFACT case, which completeness must not read as skipped (see the missing-findings case below).
  local code
  mkdir -p "$WV_PROJECT/.wave/findings"
  for code in $(awk -F'\t' 'NR > 1 && $12 != "" && $12 != "-" { print $12 }' "$WV_REPO_ROOT/hooks/phases.tsv"); do
    printf 'FINDINGS: 0\n' > "$WV_PROJECT/.wave/findings/$code.md"
  done
}

load_state() {
  local st="$1"
  WV_PROJECT="$(mkproj)"
  seed_state "$st" || return 1
  seed_clean_findings
  CLAUDE_PROJECT_DIR="$WV_PROJECT"
  wv_project_root || { fail "wv_project_root failed for $st"; return 1; }
  wv_state_read || { fail "wv_state_read failed for $st"; return 1; }
}

expect_complete() {
  local label="$1" want="$2"
  if wv_wave_complete; then
    [ "$want" = "yes" ] || fail "$label: wv_wave_complete returned 0, want not-complete"
  else
    [ "$want" = "no" ] || fail "$label: wv_wave_complete returned $?, want complete"
  fi
}

# ---- skipped conditional (vocabulary=false) does not block the close ------
st="$WV_RUN_TMP/$name-skipped.json"
jq --argjson ph "$(done_map)" '
  .ui = false | .behaviour_change = false | .cr_enabled = false
  | .vocabulary = false | .phases = $ph
' "$WV_TESTS_DIR/fixtures/state/valid-full.json" > "$st" || exit 1
load_state "$st"
expect_complete "skipped-conditional" yes

# ---- unanswered vocabulary DOES block --------------------------------------
st="$WV_RUN_TMP/$name-unanswered.json"
jq --argjson ph "$(done_map)" '
  .ui = false | .behaviour_change = false | .cr_enabled = false
  | .vocabulary = "unknown" | .phases = $ph
' "$WV_TESTS_DIR/fixtures/state/valid-full.json" > "$st" || exit 1
load_state "$st"
expect_complete "unanswered-vocabulary" no

# ---- FINDINGS: 0 does not block (BF-BC is skipped) -------------------------
st="$WV_RUN_TMP/$name-find0.json"
jq --argjson ph "$(done_map)" '
  .ui = false | .behaviour_change = false | .cr_enabled = false
  | .vocabulary = false | .phases = $ph
' "$WV_TESTS_DIR/fixtures/state/valid-full.json" > "$st" || exit 1
load_state "$st"
mkdir -p "$WV_PROJECT/.wave/findings"
printf 'FINDINGS: 0\n' > "$WV_PROJECT/.wave/findings/BC.md"
expect_complete "findings-zero" yes

# ---- FINDINGS: 2 with BF-BC not done DOES block ----------------------------
st="$WV_RUN_TMP/$name-find2.json"
jq --argjson ph "$(done_map)" '
  .ui = false | .behaviour_change = false | .cr_enabled = false
  | .vocabulary = false | .phases = $ph
' "$WV_TESTS_DIR/fixtures/state/valid-full.json" > "$st" || exit 1
load_state "$st"
mkdir -p "$WV_PROJECT/.wave/findings"
printf 'FINDINGS: 2\n' > "$WV_PROJECT/.wave/findings/BC.md"
expect_complete "findings-two-bf-not-done" no

# ---- FINDINGS: 2 with BF-BC done is complete --------------------------------
st="$WV_RUN_TMP/$name-find2-done.json"
jq --argjson ph "$(done_map BF-BC)" '
  .ui = false | .behaviour_change = false | .cr_enabled = false
  | .vocabulary = false | .phases = $ph
' "$WV_TESTS_DIR/fixtures/state/valid-full.json" > "$st" || exit 1
load_state "$st"
mkdir -p "$WV_PROJECT/.wave/findings"
printf 'FINDINGS: 2\n' > "$WV_PROJECT/.wave/findings/BC.md"
expect_complete "findings-two-bf-done" yes

# ---- demo: TEET done (and the other demo phase rows settled) ---------------
load_state "$WV_TESTS_DIR/fixtures/state/demo-teet-done.json"
expect_complete "demo-teet-done" yes

# ---- demo: TEET not done is not complete -----------------------------------
load_state "$WV_TESTS_DIR/fixtures/state/demo-through-green.json"
expect_complete "demo-teet-not-done" no

# ---- AD done with nothing else done is NOT complete (anytime never counts)
st="$WV_RUN_TMP/$name-ad-only.json"
jq '.phases = {AD:{status:"done",at:"2026-09-09T12:10:00Z",agent:"a0"}}' \
  "$WV_TESTS_DIR/fixtures/state/valid-full.json" > "$st" || exit 1
load_state "$st"
expect_complete "ad-only" no

# ---- a DONE scan whose findings file is MISSING is not settled ---------
# The order gate raises W-ARTIFACT there (pre-agent.sh wv_condition_met,
# findings: arm), it does not skip the BF- row, so completeness must not
# either. Same state as findings-zero with BC's file removed.
st="$WV_RUN_TMP/$name-find-missing.json"
jq --argjson ph "$(done_map)" '
  .ui = false | .behaviour_change = false | .cr_enabled = false
  | .vocabulary = false | .phases = $ph
' "$WV_TESTS_DIR/fixtures/state/valid-full.json" > "$st" || exit 1
load_state "$st"
rm -f "$WV_PROJECT/.wave/findings/BC.md"
expect_complete "done-scan-missing-findings" no
# ...and a scan that is NOT done with no file still skips its BF- row the
# usual way when the scan itself is skipped (ES under vocabulary false).
rm -f "$WV_PROJECT/.wave/findings/ES.md"
printf 'FINDINGS: 0\n' > "$WV_PROJECT/.wave/findings/BC.md"
expect_complete "skipped-scan-no-findings" yes

# ---- done + stale:true is settled, exactly as the gate reads it --------
# pre-agent.sh wv_phase_done answers from `.status` alone and never consults
# `stale`, so a stale-but-done successor of a redo does not hold the gate;
# completeness agrees (stop-stale-gate-agreement proves the gate side).
st="$WV_RUN_TMP/$name-stale.json"
jq --argjson ph "$(done_map)" '
  .ui = false | .behaviour_change = false | .cr_enabled = false
  | .vocabulary = false | .phases = $ph | .phases.OA.stale = true | .phases.CL.stale = true
' "$WV_TESTS_DIR/fixtures/state/valid-full.json" > "$st" || exit 1
load_state "$st"
expect_complete "done-and-stale" yes

# ---- solo is never complete via the table ----------------------------------
st="$WV_RUN_TMP/$name-solo.json"
jq --argjson ph "$(done_map)" '.mode = "solo" | .phases = $ph' \
  "$WV_TESTS_DIR/fixtures/state/valid-full.json" > "$st" || exit 1
load_state "$st"
expect_complete "solo" no

exit $rc
