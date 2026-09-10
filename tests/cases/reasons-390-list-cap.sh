#!/usr/bin/env bash
# tests/cases/reasons-390-list-cap.sh — AC-390's length bound against an input
# the corpus's own fixtures cannot produce.
#
# Two reasons interpolate a list whose length is the USER'S input: the staged
# planning documents a commit was refused for (W-COMMIT-DOC) and the unanswered
# OPEN: lines of a design review (W-DR-OPEN). Every fixture in the corpus happens
# to be small, so the corpus sweep's "<= 400 characters" would hold for the test
# data while a real commit staging thirty analysis files rendered a reason nobody
# reads — a bound that is a property of the fixtures is not a bound.
#
# So this case drives both rules with a list far past the cap and asserts three
# things per rule: the reason names the first few items, says how many it did not
# name, and is still inside the length bound. The third without the first two
# would be satisfied by a reason that named nothing at all.
#
# `set -u`, never `set -e`.
set -u

# shellcheck source=tests/lib/assert.sh
source "$(dirname "$0")/../lib/assert.sh"

name="${WV_CASE_NAME:-$(basename "$0" .sh)}"
log="${WV_CASE_LOG:-$WV_RUN_TMP/logs/$name.log}"
rc=0
fail() { printf 'ASSERT FAIL: %s\n' "$*" >&2; rc=1; }
printf 'RAN multi %s decision=multi\n' "$name" >> "$log"

# The same bound tests/tools/reason-corpus.sh enforces, read out of that file
# rather than restated, so the two cannot drift. An unreadable bound is a failed
# read, not a licence to pick one.
cap="$(command grep -m1 -oE 'WV_MAX_REASON=[0-9]+' "$WV_REPO_ROOT/tests/tools/reason-corpus.sh" | cut -d= -f2)"
case "$cap" in
  ''|*[!0-9]*) fail "could not read WV_MAX_REASON out of tests/tools/reason-corpus.sh (got '$cap')"; exit 1 ;;
esac
printf 'length bound read from reason-corpus.sh: %s characters\n' "$cap"

export LC_ALL=C.utf8   # the bound is stated in characters; pin the locale

reason_of() {
  printf '%s' "$WV_LAST_STDOUT" | jq -r \
    '.hookSpecificOutput.permissionDecisionReason // .reason // .hookSpecificOutput.additionalContext // empty'
}

# ---- W-COMMIT-DOC with twelve staged planning documents -------------------

WV_PROJECT="$(mkproj)"
seed_state state/full-fresh.json
mkdir -p "$WV_PROJECT/docs"
declare -a staged=()
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
  f="docs/plan-a-rather-long-analysis-document-name-$i.md"
  printf 'planning notes %s\n' "$i" > "$WV_PROJECT/$f"
  staged+=("$f")
done
git -C "$WV_PROJECT" add "${staged[@]}" >/dev/null 2>&1

case_json="$WV_RUN_TMP/$name-commit.json"
jq -n --arg cmd 'git commit -m "wip"' '{
  script: "pre-commit-guard.sh",
  stdin: {
    session_id: "1a2b0599-4617-4e73-a9c0-2bef462b2626",
    cwd: ".",
    hook_event_name: "PreToolUse",
    tool_name: "Bash",
    tool_input: {command: $cmd}
  },
  expect: {}
}' > "$case_json"

if run_hook pre-commit-guard.sh "$case_json"; then
  r="$(reason_of)"
  case "$r" in
    "[W-COMMIT-DOC] "*) : ;;
    *) fail "twelve staged planning docs: want a W-COMMIT-DOC deny, got '$r'" ;;
  esac
  [ "${#r}" -le "$cap" ] || \
    fail "twelve staged planning docs: the reason is ${#r} characters, over the $cap bound: '$r'"
  case "$r" in
    *'plan-a-rather-long-analysis-document-name-1.md'*) : ;;
    *) fail "twelve staged planning docs: the reason names none of them: '$r'" ;;
  esac
  case "$r" in
    *'more)'*) : ;;
    *) fail "twelve staged planning docs: the reason does not say how many it left unnamed: '$r'" ;;
  esac
  # And it must not name ALL of them: a reason that listed twelve would be inside
  # the bound only by accident of these particular filenames.
  case "$r" in
    *'plan-a-rather-long-analysis-document-name-12.md'*)
      fail "twelve staged planning docs: the reason names every one, so nothing is capped: '$r'" ;;
  esac
  printf 'W-COMMIT-DOC with 12 staged: %s characters\n' "${#r}"
else
  fail "W-COMMIT-DOC step: run_hook failed: $WV_LAST_STDERR"
fi

# ---- W-DR-OPEN with nine unanswered OPEN: lines ---------------------------

WV_PROJECT="$(mkproj)"
dr_state="$WV_RUN_TMP/$name-dr-state.json"
jq '.phases = {AC: {status: "done"}, ACB: {status: "done"}, DR: {status: "done"}} | .ui = true' \
  "$WV_TESTS_DIR/fixtures/state/valid-full.json" > "$dr_state" || { fail "could not build the DR state"; exit 1; }

dr_md=""
for i in 1 2 3 4 5 6 7 8 9; do
  dr_md="${dr_md}OPEN: question number $i about which breakpoint owns the drawer overlay\n"
done

dr_case="$WV_RUN_TMP/$name-dr.json"
jq -n --arg st "$dr_state" --arg dr "$(printf "$dr_md")" '{
  script: "pre-agent.sh",
  seed: {state: $st, files: {".wave/dr.md": $dr}},
  stdin: {
    session_id: "1a2b0599-4617-4e73-a9c0-2bef462b2626",
    cwd: ".",
    hook_event_name: "PreToolUse",
    tool_name: "Agent",
    tool_input: {
      description: "[W:1 P:TDE-RED R:lead] write the failing tests",
      subagent_type: "general-purpose",
      model: "sonnet"
    }
  },
  expect: {}
}' > "$dr_case"

if run_hook pre-agent.sh "$dr_case"; then
  r="$(reason_of)"
  case "$r" in
    "[W-DR-OPEN] "*) : ;;
    *) fail "nine OPEN lines: want a W-DR-OPEN deny, got '$r'" ;;
  esac
  [ "${#r}" -le "$cap" ] || \
    fail "nine OPEN lines: the reason is ${#r} characters, over the $cap bound: '$r'"
  case "$r" in
    *'question number 1 '*) : ;;
    *) fail "nine OPEN lines: the reason quotes none of them: '$r'" ;;
  esac
  case "$r" in
    *'more)'*) : ;;
    *) fail "nine OPEN lines: the reason does not say how many it left unquoted: '$r'" ;;
  esac
  case "$r" in
    *'question number 9 '*)
      fail "nine OPEN lines: the reason quotes every one, so nothing is capped: '$r'" ;;
  esac
  # The COUNT is not capped, only the quoted sample: "9 OPEN line(s)" is the
  # number an operator acts on.
  case "$r" in
    *'has 9 OPEN line(s)'*) : ;;
    *) fail "nine OPEN lines: the reason must still state the full count: '$r'" ;;
  esac
  printf 'W-DR-OPEN with 9 OPEN lines: %s characters\n' "${#r}"
else
  fail "W-DR-OPEN step: run_hook failed: $WV_LAST_STDERR"
fi

exit $rc
