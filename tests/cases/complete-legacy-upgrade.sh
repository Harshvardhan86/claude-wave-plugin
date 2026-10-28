#!/usr/bin/env bash
# tests/cases/complete-legacy-upgrade.sh — a wave in flight across the 0.3.0
# upgrade completes under the same policy the order gate applies.
#
# THE LEGACY DISCRIMINATOR (scripts/hooks/lib.sh wv_row_superseded): a row is
# superseded when ALL of
#   1. state.json has no `vocabulary` key — every 0.3.0 wave-init writes one
#      ("unknown" by default), so its absence means the wave was started by an
#      earlier plugin;
#   2. the row has no entry at all in `.phases` (never dispatched);
#   3. a row that names it in its `after` is recorded done — the wave was
#      already past the row's position when it was upgraded. This is the order
#      walk's own stop (pre-agent.sh wv_after_unmet_walk: a predecessor the
#      state records as done ends the walk), so the gate never asks for it.
# A superseded row is settled for completeness and for the advisory, and a
# `done:` condition naming it is not met (BEN-CLOSE skipped).
#
# Legs:
#   lib      the release review's reproduction: the 0.2.1 table's 25 phase rows all done,
#            no vocabulary key, behaviour_change true -> complete, BEN settled,
#            BEN-CLOSE not met, next allowed none. Controls: behaviour_change
#            false / absent complete; the SAME map in a 0.3.0 wave (vocabulary
#            present, including a present empty string) is NOT complete and the
#            advisory names BEN; a legacy BEN
#            that was dispatched is not superseded; a legacy wave whose AC is
#            not done still owes BEN; demo legacy complete; solo never.
#   hook     the closing SubagentStop (CL) over the legacy shape closes the wave
#            `unverified` with W-UNDELIVERED then W-SCORECARD; the 0.3.0 shape
#            stays active and announces nothing; behaviour_change false closes
#            `not-applicable` silently of W-UNDELIVERED.
set -u

# shellcheck source=tests/lib/assert.sh
source "$(dirname "$0")/../lib/assert.sh"

name="${WV_CASE_NAME:-$(basename "$0" .sh)}"
log="${WV_CASE_LOG:-$WV_RUN_TMP/logs/$name.log}"
mkdir -p "$(dirname "$log")"
rc=0
fail() { printf 'ASSERT FAIL: %s\n' "$*" >&2; rc=1; }
printf 'RAN lib.sh %s decision=multi\n' "$name" >> "$log"

# shellcheck source=scripts/hooks/lib.sh
source "$WV_REPO_ROOT/scripts/hooks/lib.sh"

# The 0.2.1 table's when=phase rows (hooks/phases.tsv at that release), pinned
# here rather than read from history: the mutation drivers run this case in a
# copy of the tree with no git history.
OLD_ROWS="AC ACB DR TDE-RED TDE-GREEN CR BC BF-BC SEA BF-SEA DS BF-DS BSEA BF-BSEA OA TEET-TC TEET BF-TEET BTEET BTEET-X BF-BTEET VB COMMIT CL CCP"

old_map() {
  # old_map [code-to-leave-out...] -> {code: {status: done}} over OLD_ROWS.
  local c skip
  for c in $OLD_ROWS; do
    for skip in "$@"; do [ "$c" = "$skip" ] && continue 2; done
    printf '%s\n' "$c"
  done | jq -R . | jq -s 'map({(.): {status: "done", at: "2026-09-09T12:10:00Z", agent: "a0"}}) | add'
}

load() {
  # load <label> <jq-filter applied to a minimal schema-1 state>
  local label="$1" filter="$2" st="$WV_RUN_TMP/$name-$1.json"
  jq -n "{schema: 1, wave: \"1\", status: \"active\", mode: \"full\", enforce: \"block\",
          ui: false, cr_enabled: false, behaviour_change: true,
          started: \"2026-09-09T12:00:00Z\", phases: {}, active: {}, pending: {}, rounds: {}}
         | $filter" > "$st" || { fail "$label: could not build the state"; return 1; }
  WV_PROJECT="$(mkproj)"
  seed_state "$st" || { fail "$label: seed"; return 1; }
  CLAUDE_PROJECT_DIR="$WV_PROJECT"
  wv_project_root || { fail "$label: wv_project_root"; return 1; }
  wv_state_read || { fail "$label: wv_state_read"; return 1; }
}

expect_complete() {
  local label="$1" want="$2"
  if wv_wave_complete; then
    [ "$want" = "yes" ] || fail "$label: wv_wave_complete returned 0, want not complete"
  else
    [ "$want" = "no" ] || fail "$label: wv_wave_complete returned non-zero, want complete"
  fi
}

expect_next() {
  local label="$1" want="$2" got
  got="$(wv_next_allowed_phase)"
  [ "$got" = "$want" ] || fail "$label: wv_next_allowed_phase is '$got', want '$want'"
}

# ---- lib: the release review's reproduction -----------------------------------------------
OLD="$(old_map)"
if load legacy-bc-true ".phases = $OLD"; then
  expect_complete legacy-bc-true yes
  wv_up_phase_settled BEN || fail "legacy-bc-true: BEN must be settled (superseded)"
  wv_row_superseded BEN || fail "legacy-bc-true: wv_row_superseded BEN must hold"
  wv_up_condition_met BEN-CLOSE
  [ "$?" = "1" ] || fail "legacy-bc-true: BEN-CLOSE's done:BEN must be not met"
  expect_next legacy-bc-true none
  [ "$(wv_delivery_verdict)" = "unverified" ] || fail "legacy-bc-true: verdict must be unverified"
fi
if load legacy-bc-false ".phases = $OLD | .behaviour_change = false"; then
  expect_complete legacy-bc-false yes
fi
if load legacy-bc-absent ".phases = $OLD | del(.behaviour_change)"; then
  expect_complete legacy-bc-absent yes
fi

# The new-wave negative control: identical map, vocabulary answered.
for v in false true; do
  if load "new-vocab-$v" ".phases = $OLD | .vocabulary = $v"; then
    expect_complete "new-vocab-$v" no
    wv_row_superseded BEN && fail "new-vocab-$v: a 0.3.0 wave must never supersede BEN"
    wv_up_phase_settled BEN && fail "new-vocab-$v: BEN must not be settled"
  fi
done
if load new-vocab-false-next ".phases = $OLD | .vocabulary = false"; then
  expect_next new-vocab-false-next BEN
fi
if load new-vocab-unknown ".phases = $OLD | .vocabulary = \"unknown\""; then
  expect_complete new-vocab-unknown no
fi
# Present-but-empty is a PRESENT key: the discriminator tests key absence on
# the state itself, never an empty scalar (wv_state_read maps both to "").
if load new-vocab-empty ".phases = $OLD | .vocabulary = \"\" | .created_by = \"0.3.0\""; then
  wv_row_superseded BEN && fail "new-vocab-empty: a present empty vocabulary key must not supersede BEN"
  wv_up_phase_settled BEN && fail "new-vocab-empty: BEN must not be settled"
  expect_complete new-vocab-empty no
  expect_next new-vocab-empty BEN
fi

# A legacy BEN that was dispatched is not absent: it must finish.
if load legacy-ben-dispatched ".phases = ($OLD + {BEN: {status: \"dispatched\"}})"; then
  wv_row_superseded BEN && fail "legacy-ben-dispatched: a dispatched BEN is not superseded"
  expect_complete legacy-ben-dispatched no
fi
# A legacy wave whose AC is not done still owes BEN before AC (design 10).
if load legacy-ac-pending ".phases = {}"; then
  wv_row_superseded BEN && fail "legacy-ac-pending: nothing done after BEN, so BEN is not superseded"
  expect_next legacy-ac-pending BEN
fi
# Demo: BEN is full-only, the five demo rows settle the wave as before.
if load legacy-demo ".mode = \"demo\" | .phases = $(old_map | jq -c 'with_entries(select(.key == "AC" or .key == "DR" or .key == "TDE-RED" or .key == "TDE-GREEN" or .key == "TEET"))')"; then
  expect_complete legacy-demo yes
  [ "$(wv_delivery_verdict)" = "not-applicable" ] || fail "legacy-demo: verdict must be not-applicable"
fi
# Solo: never complete through the table.
if load legacy-solo ".mode = \"solo\" | .phases = $OLD"; then
  expect_complete legacy-solo no
fi

# ---- hook: the closing SubagentStop --------------------------------------------
CASE="$WV_TESTS_DIR/cases/undelivered-close-unverified.json"
FIXTURE="$WV_TESTS_DIR/fixtures/state/full-closing-cl-bc.json"

tokens() { printf '%s' "$1" | command grep -oE 'W-[A-Z0-9-]+' | tr '\n' ' ' | sed -E 's/ +$//'; }

stop_over() {
  # stop_over <label> <jq-filter over full-closing-cl-bc.json>
  local label="$1" filter="$2" st="$WV_RUN_TMP/$name-$1-stop-state.json" c="$WV_RUN_TMP/$name-$1-stop.json"
  jq "$filter" "$FIXTURE" > "$st" || { fail "$label: could not build the state"; return 1; }
  jq --arg st "$st" '.seed.state = $st' "$CASE" > "$c" || { fail "$label: could not build the case"; return 1; }
  WV_PROJECT=""
  run_hook subagent-stop.sh "$c" || { fail "$label: run_hook: $WV_LAST_STDERR"; return 1; }
  [ -z "$WV_LAST_STDOUT" ] || fail "$label: stdout must stay empty, got '$WV_LAST_STDOUT'"
}

# The 0.2.1-shaped closing wave: no vocabulary key, no BEN / BEN-CLOSE entry.
LEGACY='del(.vocabulary) | .behaviour_change = true | del(.phases.BEN) | del(.phases["BEN-CLOSE"])'
if stop_over hook-legacy "$LEGACY"; then
  got="$(tokens "$WV_LAST_STDERR")"
  [ "$got" = "W-UNDELIVERED W-SCORECARD" ] \
    || fail "hook-legacy: want stderr [W-UNDELIVERED W-SCORECARD], got [$got] in '$WV_LAST_STDERR'"
  assert_stderr_contains 'never checked at close' || fail "hook-legacy: the unverified explanation is missing"
  assert_state '.status == "closed" and .delivery == "unverified" and .ended != null' \
    || fail "hook-legacy: the wave must close with delivery unverified"
fi
if stop_over hook-new "$LEGACY | .vocabulary = false"; then
  assert_state '.status == "active" and (has("delivery") | not)' \
    || fail "hook-new: a 0.3.0 wave with BEN pending must stay active with no verdict"
  case "$WV_LAST_STDERR" in
    *W-UNDELIVERED*|*W-SCORECARD*) fail "hook-new: nothing may be announced, got '$WV_LAST_STDERR'" ;;
  esac
fi
if stop_over hook-legacy-bcfalse "$LEGACY | .behaviour_change = false"; then
  assert_state '.status == "closed" and .delivery == "not-applicable"' \
    || fail "hook-legacy-bcfalse: the wave must close not-applicable"
  case "$WV_LAST_STDERR" in
    *W-UNDELIVERED*) fail "hook-legacy-bcfalse: no W-UNDELIVERED for not-applicable, got '$WV_LAST_STDERR'" ;;
  esac
fi

exit $rc
