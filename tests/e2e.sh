#!/usr/bin/env bash
# tests/e2e.sh — the real headless load proof (spec section 12, AC-378/379)
# PLUS (Task 12) six real headless-session scenarios that prove the hooks
# actually fire and decide inside the real `claude` harness, not only when
# fed by tests/run.sh's fixture-driven cases.
#
# AC coverage note (the task-12 brief's seven "End to end" scenarios,
# AC-380..387): AC-380/381/382/383/385 are each a dedicated scenario below
# (a/b/c/e/f). AC-386 ("a real trailer-bearing commit refused") is a plain
# `git commit -F file` against the installed `.git/hooks/commit-msg` — no
# `claude` session is involved in that mechanism at all, and it is already
# covered, unit-fixture style, by tests/cases/commitmsg-313-trailer-refused.sh
# (which this file does not duplicate). AC-384 (the additionalContext-vs-
# deny channel probe for `enforce:"warn"`) is NOT covered by a live session
# in this file: proving it live means letting an untagged dispatch actually
# proceed to a real subagent (the same cost profile as scenario c/e), which
# would not fit this file's own ≤10-minute total budget alongside the six
# scenarios below — flagged as a concern in the task-12 report rather than
# silently dropped.
#
# Usage: tests/e2e.sh [--keep]
#   --keep   do not delete the scratch git projects / debug log this run
#            creates; print their paths instead, for post-mortem debugging.
#
# `claude plugin validate .` (tests/cases/wiring-378-plugin-validate.sh) is
# necessary and explicitly not sufficient: it never catches the "Duplicate
# hooks file detected ... Hook load failed" failure mode that a `hooks`
# field in .claude-plugin/plugin.json produces (Global Constraint 1) —
# that mode was hit org-wide on 2026-09-09 with another plugin, and the
# published docs are silent on it. This script is the only thing that
# would catch a regression: it runs real headless `claude` sessions with
# this repo loaded as a --plugin-dir and inspects both the client's
# --debug-file log (the load proof) and the session transcripts under the
# account's `projects/` directory (the five scenarios).
#
# Task 11 shipped the load-proof section only (deliverable b of the
# task-11 brief); this task (12) appends the rest: real dispatch/edit
# scenarios that prove pre-agent.sh, post-agent.sh, subagent-stop.sh and
# pre-edit.sh actually fire and decide in a live session.
#
# Skips itself LOUDLY with exit 3 — never a silent pass — in two cases:
#   1. `claude` is not on PATH.
#   2. `claude` refuses non-interactive auth (the exact error is printed).
# Both print a banner naming every assertion that was not run, so a reader
# can tell "this box cannot run the proof" from "the proof failed".
#
# Measured platform fact (2.1.267, this file's own live runs, 2026-09-10),
# recorded here because it changes what this proof can literally assert:
# even with `--debug --debug-file <path>` (every category, no filter), this
# client's debug log never names an event (PreToolUse/SubagentStop/...)
# next to a plugin name — not for a hook that fires silently (this plugin's
# own scripts correctly produce no output outside an active wave, so there
# is nothing for the log to echo), and not even when the probe drives a
# real Bash tool call. The log's only per-plugin evidence is at plugin-load
# time: "Read hooks.json for plugin <name> (enabled=true): <path>" and
# "Loading hooks from plugin: <name>", plus one aggregate
# "Registered N hooks from M plugins" count across every enabled plugin.
# AC-379's letter ("a line showing this plugin's hooks registered for at
# least PreToolUse and SubagentStop") is therefore satisfied to the extent
# the live platform exposes it: this script asserts both per-plugin lines
# plus the aggregate count, and leans on tests/cases/wiring-368/369 (static,
# every run) to prove hooks.json itself declares PreToolUse and SubagentStop
# entries — the live log cannot be asked a question it never answers.
#
# Second measured platform fact (2.1.267, 2026-09-10, this file's own dry
# runs while building the five scenarios below): the `Agent` tool this
# plugin's hooks match on (`^Agent$` in hooks/hooks.json) is what the
# harness matches hooks against, but the SAME tool call is echoed back in
# `--output-format json`'s own `permission_denials` array (and in a normal
# transcript entry) under the display name `Task`. This is not a mismatch
# to fix: the hook fires correctly against `Agent` (proved below — every
# PreToolUse(Agent) deny this file drives is observed both in the JSON
# result's prose and in the transcript's `tool_result`), it is simply the
# client's own two names for the one tool.
#
# Third measured fact: a `Write` to a file that already exists on disk and
# has not yet been read via the `Read` tool in the SAME session is refused
# by a built-in client safety guard ("File has not been read yet.") BEFORE
# the tool call ever reaches this plugin's PreToolUse(Write) hook at all —
# so scenario (d) below has the driven session `cat` the target file via
# Bash first (which is not gated: pre-bash.sh only judges build/test
# commands) to clear that built-in guard and let pre-edit.sh's own W-EDIT
# gate be the thing that denies the Write.
set -u

WV_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

WV_KEEP=0
for wv_arg in "$@"; do
  case "$wv_arg" in
    --keep) WV_KEEP=1 ;;
    *)
      printf 'tests/e2e.sh: unknown argument: %s (only --keep is accepted)\n' "$wv_arg" >&2
      exit 1
      ;;
  esac
done

wv_e2e_fail() {
  printf 'tests/e2e.sh: FAIL: %s\n' "$*" >&2
}

# ---------------------------------------------------------------------------
# The assertion list, used only to render the SKIPPED banner so a reader can
# see exactly what did not run — never used to decide anything.
# ---------------------------------------------------------------------------

WV_E2E_ASSERTIONS=(
  "load-proof: hooks/hooks.json loads with no 'Duplicate hooks'/'Hook load failed', and this plugin's per-plugin load lines plus the aggregate registered-hook count appear in --debug-file"
  "scenario-a (AC-380): an UNTAGGED Agent dispatch during an active wave (mode full, ui/behaviour_change/cr_enabled all false, enforce block) is denied, the transcript's tool_result carries the [W-TAG] reason, and no subagent transcript directory is created for it"
  "scenario-b (AC-381): [W:1 P:AC R:lead] dispatched with model \"haiku\" is denied, the transcript's tool_result carries the [W-TIER] reason naming \"opus\""
  "scenario-c (AC-382): [W:1 P:AD R:executor] dispatched with model \"haiku\" (AD has no predecessors, so no extra state-seeding is needed) is ALLOWED, the subagent runs, .wave/ledger.jsonl gets exactly one AD/executor line with tier_ok true and a real resolved model, state.active records a real agentId + resolvedModel written by post-agent.sh, and state.phases.AD.status == \"done\""
  "scenario-d: a main-session Write to a git-tracked src/x.ts during the wave is denied with [W-EDIT] and the file is left unchanged; a Write to .wave/notes.md in the same session is allowed and the file exists afterwards"
  "scenario-e (AC-383): with no .wave/ directory at all, the same untagged Agent dispatch that scenario (a) denies is ALLOWED — the negative control proving \"no wave, no hooks\" in the real harness, and no .wave/ directory is created by the dispatch"
  "scenario-f (AC-385): /<plugin>:wave-start \"x\" run WITHOUT --dangerously-skip-permissions needs zero permission decisions (commands/wave-start.md's own allowed-tools pre-approves its wave-init.sh/wave-set.sh calls) and produces .wave/state.json"
)

wv_e2e_print_skip_banner() {
  # wv_e2e_print_skip_banner <reason> — the loud SKIPPED banner. Every
  # caller of this function must follow it with `exit 3`.
  printf 'tests/e2e.sh: SKIPPED — %s\n' "$1" >&2
  printf 'tests/e2e.sh: the following assertions were NOT run:\n' >&2
  local a
  for a in "${WV_E2E_ASSERTIONS[@]}"; do
    printf '  - %s\n' "$a" >&2
  done
}

wv_e2e_looks_like_auth_error() {
  # wv_e2e_looks_like_auth_error <text> — true when <text> names a
  # non-interactive-auth refusal rather than a genuine bug in this plugin
  # or this script. Matched loosely and case-insensitively on purpose: the
  # cost of a false positive here is a SKIP instead of a FAIL, which is the
  # safer of the two wrong answers for a claim this script cannot verify
  # without live credentials.
  command grep -qiE \
    'invalid api key|please run .?claude login|not authenticated|unauthorized|authentication_error|401|no api key found|please set your api key|login required' \
    <<<"$1"
}

if ! command -v claude >/dev/null 2>&1; then
  wv_e2e_print_skip_banner "claude is not on PATH; none of the live headless proofs below were run"
  exit 3
fi

plugin_name="$(jq -r '.name // empty' "$WV_REPO_ROOT/.claude-plugin/plugin.json" 2>/dev/null)"
if [ -z "$plugin_name" ]; then
  wv_e2e_fail "could not read .name from $WV_REPO_ROOT/.claude-plugin/plugin.json"
  exit 1
fi

wv_tmp="$(mktemp -d "${TMPDIR:-/tmp}/wave-plugin-e2e.XXXXXX")"
declare -a WV_E2E_SCRATCH_DIRS=()

cleanup() {
  if [ "$WV_KEEP" = "1" ]; then
    printf 'tests/e2e.sh: --keep was given; leaving these paths on disk:\n' >&2
    printf '  %s\n' "$wv_tmp" >&2
    local d
    for d in "${WV_E2E_SCRATCH_DIRS[@]:-}"; do
      [ -n "$d" ] && printf '  %s\n' "$d" >&2
    done
    return 0
  fi
  rm -rf "$wv_tmp" "${WV_E2E_SCRATCH_DIRS[@]:-}"
}
trap cleanup EXIT

log="$wv_tmp/debug.log"
proj="$wv_tmp/scratch-proj"
mkdir -p "$proj"
git -C "$proj" init -q

# --- the load proof itself --------------------------------------------

out="$(cd "$proj" && timeout 120 claude --debug-file "$log" --plugin-dir "$WV_REPO_ROOT" \
  -p 'reply with the single word OK' --model haiku 2>&1)"
run_rc=$?

rc=0

if [ "$run_rc" != "0" ]; then
  if wv_e2e_looks_like_auth_error "$out"; then
    wv_e2e_print_skip_banner "claude refused non-interactive auth: $out"
    exit 3
  fi
  wv_e2e_fail "claude exited $run_rc: $out"
  rc=1
fi

if [ ! -s "$log" ]; then
  wv_e2e_fail "$log is empty or was not written"
  rc=1
fi

if command grep -qF 'Duplicate hooks' "$log" 2>/dev/null; then
  wv_e2e_fail "debug log contains 'Duplicate hooks': $(command grep -F 'Duplicate hooks' "$log")"
  rc=1
fi

if command grep -qF 'Hook load failed' "$log" 2>/dev/null; then
  wv_e2e_fail "debug log contains 'Hook load failed': $(command grep -F 'Hook load failed' "$log")"
  rc=1
fi

read_line="$(command grep -F "Read hooks.json for plugin $plugin_name " "$log" 2>/dev/null | head -n1)"
if [ -z "$read_line" ]; then
  wv_e2e_fail "debug log has no 'Read hooks.json for plugin $plugin_name ...' line"
  rc=1
fi

loading_line="$(command grep -F "Loading hooks from plugin: $plugin_name" "$log" 2>/dev/null | head -n1)"
if [ -z "$loading_line" ]; then
  wv_e2e_fail "debug log has no 'Loading hooks from plugin: $plugin_name' line"
  rc=1
fi

registered_line="$(command grep -E 'Registered [0-9]+ hooks from [0-9]+ plugins' "$log" 2>/dev/null | head -n1)"
if [ -z "$registered_line" ]; then
  wv_e2e_fail "debug log has no 'Registered N hooks from M plugins' line"
  rc=1
else
  registered_n="$(printf '%s' "$registered_line" | command grep -oE 'Registered [0-9]+' | command grep -oE '[0-9]+')"
  our_hook_count="$(jq '[.hooks[][]?.hooks[]?] | length' "$WV_REPO_ROOT/hooks/hooks.json" 2>/dev/null)"
  if [ -z "$registered_n" ] || [ -z "$our_hook_count" ] || [ "$registered_n" -lt "$our_hook_count" ]; then
    wv_e2e_fail "registered count ($registered_n) is smaller than this plugin's own hook count ($our_hook_count); this plugin's hooks cannot all be included"
    rc=1
  fi
fi

if [ "$rc" = "0" ]; then
  printf 'tests/e2e.sh: LOAD-PROOF PASS\n'
  printf '  %s\n' "$read_line"
  printf '  %s\n' "$loading_line"
  printf '  %s\n' "$registered_line"
  printf '  (log: %s)\n' "$log"
else
  printf 'tests/e2e.sh: LOAD-PROOF FAIL — see the wave-plugin: FAIL lines above.\n' >&2
  printf '  (log kept at: %s — trap will still remove it on exit; rerun with a copy if needed)\n' "$log" >&2
fi

# ===========================================================================
# Task 12: the five real dispatch/edit scenarios. Each drives its own
# headless `claude -p` session, with this repo as a --plugin-dir, against a
# FRESH scratch git project under mktemp (never the load-proof's own $proj),
# and asserts against BOTH the session's --output-format json result AND the
# session transcript located via its session_id.
# ===========================================================================

WV_SC_PASS=0
WV_SC_FAIL=0

wv_sc_pass() {
  printf 'tests/e2e.sh: PASS %s\n' "$1"
  WV_SC_PASS=$((WV_SC_PASS + 1))
}

wv_sc_fail() {
  printf 'tests/e2e.sh: FAIL %s: %s\n' "$1" "$2" >&2
  WV_SC_FAIL=$((WV_SC_FAIL + 1))
}

wv_e2e_new_scratch() {
  # wv_e2e_new_scratch -> a fresh scratch git project on stdout, with one
  # committed file (README.md) so "tracked by git" is meaningful later.
  #
  # NOT registered in WV_E2E_SCRATCH_DIRS here: every caller assigns this
  # function's output via `d="$(wv_e2e_new_scratch)"`, and a `$(...)`
  # command substitution runs in a SUBSHELL — an append to the array made
  # inside this function would mutate only that subshell's copy and vanish
  # the instant the substitution returns (measured while building this
  # file: it left every scratch project un-registered and the cleanup trap
  # silently deleted only its own $wv_tmp). Each call site registers the
  # path itself, in the shell that will actually still be running at EXIT.
  local d
  d="$(mktemp -d "${TMPDIR:-/tmp}/wave-plugin-e2e-scenario.XXXXXX")"
  git -C "$d" init -q
  git -C "$d" config user.email "wave-plugin-e2e@example.com"
  git -C "$d" config user.name "wave-plugin-e2e"
  printf 'wave-plugin e2e scratch project\n' > "$d/README.md"
  git -C "$d" add README.md >/dev/null
  git -C "$d" commit -q -m "init" >/dev/null
  printf '%s' "$d"
}

wv_e2e_seed_wave() {
  # wv_e2e_seed_wave <dir> — starts an active wave 1, mode full, matching
  # AC-380's GIVEN clause exactly: ui:false, behaviour_change:false,
  # cr_enabled:false, enforce block, no phase done yet. wave-init.sh has no
  # --behaviour-change flag (state.json's behaviour_change is always
  # written "unknown" by wave-init.sh itself, spec section 4), so it is set
  # to false separately through scripts/wave-set.sh, the same locked
  # read-modify-write every lifecycle script uses — not a hand-rolled jq
  # edit, per the brief's "document how".
  local d="$1"
  local out
  if ! out="$(cd "$d" && "$WV_REPO_ROOT/scripts/wave-init.sh" --wave 1 --mode full --no-ui --no-cr --feature "e2e-test" 2>&1)"; then
    printf 'tests/e2e.sh: could not seed a wave in %s: %s\n' "$d" "$out" >&2
    return 1
  fi
  if ! out="$(cd "$d" && "$WV_REPO_ROOT/scripts/wave-set.sh" behaviour-change false 2>&1)"; then
    printf 'tests/e2e.sh: could not set behaviour-change false in %s: %s\n' "$d" "$out" >&2
    return 1
  fi
  return 0
}

WV_E2E_JSON=""
WV_E2E_RC=0

wv_e2e_run_session() {
  # wv_e2e_run_session <dir> <prompt> <timeout-secs> <errfile> — runs a real
  # headless session with this repo as --plugin-dir, model haiku throughout
  # (the orchestrating session AND every dispatch this file's prompts name),
  # --dangerously-skip-permissions (there is no terminal to answer a
  # permission prompt in -p mode, and the whole point is to reach this
  # plugin's OWN gates rather than the generic permission system's). Sets
  # WV_E2E_JSON (stdout) and WV_E2E_RC; stderr goes to <errfile> so a
  # non-JSON stdout is never produced by interleaved noise.
  local d="$1" prompt="$2" secs="$3" errfile="$4"
  WV_E2E_JSON="$(cd "$d" && timeout "$secs" claude -p "$prompt" --model haiku \
    --plugin-dir "$WV_REPO_ROOT" --dangerously-skip-permissions \
    --output-format json < /dev/null 2>"$errfile")"
  WV_E2E_RC=$?
}

wv_e2e_run_session_no_bypass() {
  # wv_e2e_run_session_no_bypass <dir> <prompt> <timeout-secs> <errfile> —
  # the same as wv_e2e_run_session but WITHOUT
  # --dangerously-skip-permissions. Used only by scenario (f)/AC-385, whose
  # whole point is that NO permission prompt is needed for
  # /wave-start's own wave-init.sh / wave-set.sh calls (commands/wave-start.md's
  # front-matter `allowed-tools` pre-approves exactly those two invocations) —
  # a run under the bypass flag would make that assertion vacuous, since the
  # bypass flag would suppress a real prompt just as effectively as a correct
  # allowed-tools entry would.
  local d="$1" prompt="$2" secs="$3" errfile="$4"
  WV_E2E_JSON="$(cd "$d" && timeout "$secs" claude -p "$prompt" --model haiku \
    --plugin-dir "$WV_REPO_ROOT" \
    --output-format json < /dev/null 2>"$errfile")"
  WV_E2E_RC=$?
}

wv_e2e_find_transcript() {
  # wv_e2e_find_transcript <session-id> -> the transcript .jsonl path on
  # stdout, or empty. Searched across both locations this box is known to
  # use (a nested claude session's own CLAUDE_CONFIG_DIR is not honoured by
  # a further-nested nohup'd `claude -p`, measured while building this
  # file: the account's projects/ dir was NOT where these scratch sessions'
  # transcripts landed — the default $HOME/.claude/projects/ was), so both
  # roots are always searched rather than assumed.
  local sid="$1" found
  shopt -s nullglob
  found="$(find "$HOME/.claude/projects" "$HOME/.config/claude-accounts"/*/projects \
    -maxdepth 2 -type f -name "${sid}.jsonl" 2>/dev/null | head -n1)"
  shopt -u nullglob
  printf '%s' "$found"
}

wv_e2e_session_id() {
  printf '%s' "$WV_E2E_JSON" | jq -r '.session_id // empty' 2>/dev/null
}

# ---------------------------------------------------------------------------
# Scenario (a) / AC-380: untagged dispatch during an active wave is denied.
# ---------------------------------------------------------------------------

wv_e2e_scenario_a() {
  local name="scenario-a-untagged-denied"
  local d sid transcript match errfile
  d="$(wv_e2e_new_scratch)"
  WV_E2E_SCRATCH_DIRS+=("$d")
  wv_e2e_seed_wave "$d" || { wv_sc_fail "$name" "could not seed the wave"; return; }
  errfile="$d/.e2e-stderr.log"

  local prompt='Use the Agent tool exactly once to dispatch a subagent with these exact parameters: subagent_type="general-purpose", model="haiku", description="probe untagged", prompt="Reply with the single word: DONE". Do not add any bracket tag, prefix, or other text to the description or prompt. Do this immediately without asking any questions or explaining your plan.'
  wv_e2e_run_session "$d" "$prompt" 90 "$errfile"

  if [ -z "$WV_E2E_JSON" ]; then
    if wv_e2e_looks_like_auth_error "$(cat "$errfile" 2>/dev/null)"; then
      wv_e2e_print_skip_banner "claude refused non-interactive auth during $name: $(cat "$errfile" 2>/dev/null)"
      exit 3
    fi
    wv_sc_fail "$name" "empty output (rc=$WV_E2E_RC); stderr: $(cat "$errfile" 2>/dev/null)"
    return
  fi

  sid="$(wv_e2e_session_id)"
  [ -n "$sid" ] || { wv_sc_fail "$name" "no session_id in output: $WV_E2E_JSON"; return; }

  transcript="$(wv_e2e_find_transcript "$sid")"
  [ -n "$transcript" ] || { wv_sc_fail "$name" "no transcript found for session $sid"; return; }

  match="$(command grep -o '\[W-TAG\][^"\\]*' "$transcript" 2>/dev/null | head -n1)"
  if [ -z "$match" ]; then
    wv_sc_fail "$name" "transcript $transcript carries no [W-TAG] tool_result text"
    return
  fi

  local sessdir="${transcript%.jsonl}"
  if [ -d "$sessdir/subagents" ] && [ -n "$(ls -A "$sessdir/subagents" 2>/dev/null)" ]; then
    wv_sc_fail "$name" "a subagent transcript exists at $sessdir/subagents despite the untagged dispatch being denied"
    return
  fi

  wv_sc_pass "$name"
  printf '  prompt: %s\n' "$prompt"
  printf '  session: %s (%s)\n' "$sid" "$transcript"
  printf '  matched transcript line: %s\n' "$match"
}

# ---------------------------------------------------------------------------
# Scenario (b) / AC-381: [W:1 P:AC R:lead] with model haiku is denied W-TIER
# naming opus.
# ---------------------------------------------------------------------------

wv_e2e_scenario_b() {
  local name="scenario-b-tier-denied"
  local d sid transcript match errfile
  d="$(wv_e2e_new_scratch)"
  WV_E2E_SCRATCH_DIRS+=("$d")
  wv_e2e_seed_wave "$d" || { wv_sc_fail "$name" "could not seed the wave"; return; }
  errfile="$d/.e2e-stderr.log"

  local prompt='Use the Agent tool exactly once to dispatch a subagent with these exact parameters: subagent_type="general-purpose", model="haiku", description="[W:1 P:AC R:lead] probe tier", prompt="Reply with the single word: DONE". Do this immediately without asking any questions. If the dispatch is denied, do not retry with a different model; just report the denial reason.'
  wv_e2e_run_session "$d" "$prompt" 90 "$errfile"

  if [ -z "$WV_E2E_JSON" ]; then
    if wv_e2e_looks_like_auth_error "$(cat "$errfile" 2>/dev/null)"; then
      wv_e2e_print_skip_banner "claude refused non-interactive auth during $name: $(cat "$errfile" 2>/dev/null)"
      exit 3
    fi
    wv_sc_fail "$name" "empty output (rc=$WV_E2E_RC); stderr: $(cat "$errfile" 2>/dev/null)"
    return
  fi

  sid="$(wv_e2e_session_id)"
  [ -n "$sid" ] || { wv_sc_fail "$name" "no session_id in output: $WV_E2E_JSON"; return; }

  transcript="$(wv_e2e_find_transcript "$sid")"
  [ -n "$transcript" ] || { wv_sc_fail "$name" "no transcript found for session $sid"; return; }

  match="$(command grep -o '\[W-TIER\][^"\\]*' "$transcript" 2>/dev/null | head -n1)"
  if [ -z "$match" ]; then
    wv_sc_fail "$name" "transcript $transcript carries no [W-TIER] tool_result text"
    return
  fi
  case "$match" in
    *opus*) : ;;
    *)
      wv_sc_fail "$name" "the [W-TIER] reason did not name opus: $match"
      return
      ;;
  esac

  wv_sc_pass "$name"
  printf '  prompt: %s\n' "$prompt"
  printf '  session: %s (%s)\n' "$sid" "$transcript"
  printf '  matched transcript line: %s\n' "$match"
}

# ---------------------------------------------------------------------------
# Scenario (c) / AC-382: [W:1 P:AD R:executor] with model haiku is allowed
# and ledgered. AD (hooks/phases.tsv) is the cheapest row whose tier haiku
# satisfies: its `after` column is EMPTY (it is the mode's terminal, anytime
# row — see scripts/wave-close.sh's own derivation, "AD for full mode by
# construction"), so no predecessor phases need to be marked done at all —
# the brief's "seed state so its `after` predecessors are done" is
# vacuously satisfied by AD having none, which is why it was picked over
# AC/lead (opus, and first in the DAG) or VB (after BTEET-X, BF-BTEET — a
# long predecessor chain that would need real phases marked done).
# ---------------------------------------------------------------------------

# wv_e2e_scenario_c_attempt sets these; the wrapper below reads them.
WV_SC_C_OK=0
WV_SC_C_RACE=0
WV_SC_C_MSG=""
WV_SC_C_DETAIL=""

wv_e2e_scenario_c_attempt() {
  local name="scenario-c-allowed-ledgered"
  local d sid transcript errfile
  WV_SC_C_OK=0
  WV_SC_C_RACE=0
  WV_SC_C_MSG=""
  WV_SC_C_DETAIL=""

  d="$(wv_e2e_new_scratch)"
  WV_E2E_SCRATCH_DIRS+=("$d")
  wv_e2e_seed_wave "$d" || { WV_SC_C_MSG="could not seed the wave"; return; }
  errfile="$d/.e2e-stderr.log"

  local prompt='Use the Agent tool exactly once to dispatch a subagent with these exact parameters: subagent_type="general-purpose", model="haiku", description="[W:1 P:AD R:executor] probe allowed", prompt="Reply with the single word: DONE". Do this immediately without asking any questions.'
  wv_e2e_run_session "$d" "$prompt" 90 "$errfile"

  if [ -z "$WV_E2E_JSON" ]; then
    if wv_e2e_looks_like_auth_error "$(cat "$errfile" 2>/dev/null)"; then
      wv_e2e_print_skip_banner "claude refused non-interactive auth during $name: $(cat "$errfile" 2>/dev/null)"
      exit 3
    fi
    WV_SC_C_MSG="empty output (rc=$WV_E2E_RC); stderr: $(cat "$errfile" 2>/dev/null)"
    return
  fi

  sid="$(wv_e2e_session_id)"
  [ -n "$sid" ] || { WV_SC_C_MSG="no session_id in output: $WV_E2E_JSON"; return; }
  transcript="$(wv_e2e_find_transcript "$sid")"
  [ -n "$transcript" ] || { WV_SC_C_MSG="no transcript found for session $sid"; return; }

  local denials
  denials="$(printf '%s' "$WV_E2E_JSON" | jq '.permission_denials | length' 2>/dev/null)"
  if [ "$denials" != "0" ]; then
    WV_SC_C_MSG="the correctly tagged AD/executor/haiku dispatch was denied $denials time(s); result: $(printf '%s' "$WV_E2E_JSON" | jq -r '.result')"
    return
  fi

  local ledger="$d/.wave/ledger.jsonl"
  if [ ! -f "$ledger" ]; then
    WV_SC_C_MSG="$ledger was never written"
    return
  fi

  local count tier_ok tier_verified turns resolved
  count="$(jq -s '[.[] | select(.phase == "AD" and .role == "executor")] | length' "$ledger" 2>/dev/null)"
  if [ "$count" != "1" ]; then
    WV_SC_C_MSG="$ledger has $count line(s) for phase AD / role executor, expected exactly 1: $(cat "$ledger")"
    return
  fi

  tier_ok="$(jq -sr '[.[] | select(.phase == "AD" and .role == "executor")][0].tier_ok' "$ledger" 2>/dev/null)"
  tier_verified="$(jq -sr '[.[] | select(.phase == "AD" and .role == "executor")][0].tier_verified' "$ledger" 2>/dev/null)"
  turns="$(jq -sr '[.[] | select(.phase == "AD" and .role == "executor")][0].turns' "$ledger" 2>/dev/null)"
  if [ "$tier_ok" != "true" ]; then
    # A specific, previously-observed signature (measured while building this
    # file, ~1 in 5 real runs): SubagentStop fires and subagent-stop.sh reads
    # the subagent's OWN transcript before its last assistant turn(s) are
    # flushed to disk — turns/output/tier_verified all come back zero/false
    # even though the transcript, inspected moments later, holds a complete,
    # well-formed assistant turn with the right model. This is a real
    # SubagentStop-vs-transcript-flush race in the live async harness, not a
    # bug in this plugin's tier comparison logic (subagent-stop.sh's own
    # header already documents "the last line of a live transcript is
    # routinely a mid-write fragment ... skipped rather than fatal" for the
    # milder, partial-line version of the same class of race) and not
    # something a bash hook script can fix by retrying internally (it has no
    # channel to delay SubagentStop). Retried ONCE, in a brand new scratch
    # project, ONLY when this exact signature is seen; any other assertion
    # failing below is a hard failure, never retried.
    if [ "$tier_verified" = "false" ] && [ "$turns" = "0" ]; then
      WV_SC_C_RACE=1
      WV_SC_C_MSG="the ledger line's tier_ok is \"$tier_ok\" with tier_verified=false and turns=0 — SubagentStop/transcript-flush race signature: $(cat "$ledger")"
      return
    fi
    WV_SC_C_MSG="the ledger line's tier_ok is \"$tier_ok\" (tier_verified=$tier_verified, turns=$turns), expected true: $(cat "$ledger")"
    return
  fi

  resolved="$(jq -sr '[.[] | select(.phase == "AD" and .role == "executor")][0].resolved' "$ledger" 2>/dev/null)"
  case "$resolved" in
    ''|null|unknown)
      WV_SC_C_MSG="the ledger line's resolved model is \"$resolved\", expected a real model id"
      return
      ;;
  esac

  local state="$d/.wave/state.json"
  local active_count active_resolved active_id
  active_count="$(jq '[.active[] | select(.phase == "AD" and .role == "executor")] | length' "$state" 2>/dev/null)"
  if [ "$active_count" != "1" ]; then
    WV_SC_C_MSG="$state has $active_count active record(s) for phase AD / role executor, expected exactly 1"
    return
  fi
  active_resolved="$(jq -r '[.active[] | select(.phase == "AD" and .role == "executor")][0].resolved_model' "$state" 2>/dev/null)"
  active_id="$(jq -r '.active | to_entries[] | select(.value.phase == "AD" and .value.role == "executor") | .key' "$state" 2>/dev/null)"
  case "$active_resolved" in
    ''|null|unknown)
      WV_SC_C_MSG="state.active's AD/executor record has resolved_model \"$active_resolved\", expected a real model id (post-agent.sh should have written it)"
      return
      ;;
  esac
  [ -n "$active_id" ] || { WV_SC_C_MSG="state.active has no agentId key for the AD/executor record"; return; }

  # AC-382's other half, preserved by the AD substitution: the phase itself
  # must be recorded done, not just the per-agent active/ledger records.
  # subagent-stop.sh writes this at the closing role's stop once the
  # artifact check passes (AD's artifact/marker are both "-", so it passes
  # trivially — see the header comment above this function).
  local phase_status
  phase_status="$(jq -r '.phases.AD.status // empty' "$state" 2>/dev/null)"
  if [ "$phase_status" != "done" ]; then
    WV_SC_C_MSG="state.phases.AD.status is \"${phase_status:-<absent>}\", expected \"done\" (found via jq -r '.phases.AD.status' on $state)"
    return
  fi

  WV_SC_C_OK=1
  WV_SC_C_DETAIL="$(printf '  prompt: %s\n  session: %s (%s)\n  ledger line: %s\n  state.active[%s]: phase=AD role=executor resolved_model=%s\n  state.phases.AD.status: %s\n' \
    "$prompt" "$sid" "$transcript" \
    "$(jq -sc '[.[] | select(.phase == "AD" and .role == "executor")][0]' "$ledger" 2>/dev/null)" \
    "$active_id" "$active_resolved" "$phase_status")"
}

wv_e2e_scenario_c() {
  local name="scenario-c-allowed-ledgered"
  local attempt
  for attempt in 1 2; do
    wv_e2e_scenario_c_attempt
    if [ "$WV_SC_C_OK" = "1" ]; then
      wv_sc_pass "$name"
      printf '%s\n' "$WV_SC_C_DETAIL"
      [ "$attempt" = "1" ] || printf '  (note: passed on retry attempt %d after a SubagentStop/transcript-flush race on attempt 1)\n' "$attempt"
      return
    fi
    if [ "$WV_SC_C_RACE" = "1" ] && [ "$attempt" = "1" ]; then
      printf 'tests/e2e.sh: %s attempt 1 hit a known SubagentStop/transcript-flush race — retrying once in a fresh scratch project: %s\n' "$name" "$WV_SC_C_MSG" >&2
      continue
    fi
    wv_sc_fail "$name" "$WV_SC_C_MSG"
    return
  done
}

# ---------------------------------------------------------------------------
# Scenario (d): main-session Write gate. src/x.ts is denied W-EDIT (tracked,
# outside .wave/); .wave/notes.md is allowed.
# ---------------------------------------------------------------------------

wv_e2e_scenario_d() {
  local name="scenario-d-write-edit-gate"
  local d sid transcript match errfile abs_x abs_notes
  d="$(wv_e2e_new_scratch)"
  WV_E2E_SCRATCH_DIRS+=("$d")
  mkdir -p "$d/src"
  printf 'old\n' > "$d/src/x.ts"
  ( cd "$d" && git add src/x.ts && git commit -q -m "add x.ts" ) >/dev/null 2>&1
  wv_e2e_seed_wave "$d" || { wv_sc_fail "$name" "could not seed the wave"; return; }
  errfile="$d/.e2e-stderr.log"
  abs_x="$d/src/x.ts"
  abs_notes="$d/.wave/notes.md"

  # Step 1 (`cat` via Bash, not the Read tool) exists solely to satisfy the
  # client's own built-in "File has not been read yet" Write guard, which
  # would otherwise refuse the Write before this plugin's hook ever saw it
  # (see the file header's "Third measured fact"). pre-bash.sh does not gate
  # a plain `cat`.
  local prompt
  prompt="Step 1: run \`cat $abs_x\` using the Bash tool. Step 2: use the Write tool exactly once to overwrite $abs_x with content \"new content\". If it is denied, report the exact denial reason and do not retry it. Step 3: use the Write tool exactly once to create $abs_notes with content \"note\". Do all three steps immediately without asking questions, then stop."
  wv_e2e_run_session "$d" "$prompt" 90 "$errfile"

  if [ -z "$WV_E2E_JSON" ]; then
    if wv_e2e_looks_like_auth_error "$(cat "$errfile" 2>/dev/null)"; then
      wv_e2e_print_skip_banner "claude refused non-interactive auth during $name: $(cat "$errfile" 2>/dev/null)"
      exit 3
    fi
    wv_sc_fail "$name" "empty output (rc=$WV_E2E_RC); stderr: $(cat "$errfile" 2>/dev/null)"
    return
  fi

  sid="$(wv_e2e_session_id)"
  [ -n "$sid" ] || { wv_sc_fail "$name" "no session_id in output: $WV_E2E_JSON"; return; }
  transcript="$(wv_e2e_find_transcript "$sid")"
  [ -n "$transcript" ] || { wv_sc_fail "$name" "no transcript found for session $sid"; return; }

  match="$(command grep -o '\[W-EDIT\][^"\\]*' "$transcript" 2>/dev/null | head -n1)"
  if [ -z "$match" ]; then
    wv_sc_fail "$name" "transcript $transcript carries no [W-EDIT] tool_result text"
    return
  fi

  local content
  content="$(cat "$abs_x" 2>/dev/null)"
  if [ "$content" != "old" ]; then
    wv_sc_fail "$name" "src/x.ts content is \"$content\", expected the untouched \"old\" (the denied Write must not have landed)"
    return
  fi

  if [ ! -f "$abs_notes" ]; then
    wv_sc_fail "$name" "$abs_notes was not created (the .wave/ Write should have been allowed)"
    return
  fi

  wv_sc_pass "$name"
  printf '  prompt: %s\n' "$prompt"
  printf '  session: %s (%s)\n' "$sid" "$transcript"
  printf '  matched transcript line: %s\n' "$match"
  printf '  src/x.ts unchanged (%s); .wave/notes.md exists\n' "$content"
}

# ---------------------------------------------------------------------------
# Scenario (e) / AC-383: no .wave/ at all -> the same untagged dispatch is
# allowed (negative control: no wave, no hooks).
# ---------------------------------------------------------------------------

wv_e2e_scenario_e() {
  local name="scenario-e-no-wave-allowed"
  local d sid errfile
  d="$(wv_e2e_new_scratch)"
  WV_E2E_SCRATCH_DIRS+=("$d")
  # Deliberately no wv_e2e_seed_wave call: no .wave/ directory at all.
  errfile="$d/.e2e-stderr.log"

  local prompt='Use the Agent tool exactly once to dispatch a subagent with these exact parameters: subagent_type="general-purpose", model="haiku", description="probe nowave", prompt="Reply with the single word: DONE". Do this immediately without asking any questions.'
  wv_e2e_run_session "$d" "$prompt" 90 "$errfile"

  if [ -z "$WV_E2E_JSON" ]; then
    if wv_e2e_looks_like_auth_error "$(cat "$errfile" 2>/dev/null)"; then
      wv_e2e_print_skip_banner "claude refused non-interactive auth during $name: $(cat "$errfile" 2>/dev/null)"
      exit 3
    fi
    wv_sc_fail "$name" "empty output (rc=$WV_E2E_RC); stderr: $(cat "$errfile" 2>/dev/null)"
    return
  fi

  sid="$(wv_e2e_session_id)"
  [ -n "$sid" ] || { wv_sc_fail "$name" "no session_id in output: $WV_E2E_JSON"; return; }

  local denials
  denials="$(printf '%s' "$WV_E2E_JSON" | jq '.permission_denials | length' 2>/dev/null)"
  if [ "$denials" != "0" ]; then
    wv_sc_fail "$name" "the untagged dispatch was denied $denials time(s) with no .wave/ present at all; result: $(printf '%s' "$WV_E2E_JSON" | jq -r '.result')"
    return
  fi

  if [ -e "$d/.wave" ]; then
    wv_sc_fail "$name" "$d/.wave was created even though no wave was ever started — minimum-disturbance guarantee violated"
    return
  fi

  wv_sc_pass "$name"
  printf '  prompt: %s\n' "$prompt"
  printf '  session: %s\n' "$sid"
  printf '  permission_denials: 0; .wave/ absent after the dispatch\n'
}

# ---------------------------------------------------------------------------
# Scenario (f) / AC-385: `/wave-start "x"` runs with no permission prompt and
# produces .wave/state.json. Deliberately run WITHOUT
# --dangerously-skip-permissions (wv_e2e_run_session_no_bypass) — the bypass
# flag would make "no permission prompt" true for the wrong reason.
# commands/wave-start.md's own front-matter `allowed-tools` pre-approves the
# wave-init.sh / wave-set.sh Bash invocations it makes, which is the actual
# mechanism this scenario is proving works in the real harness.
# ---------------------------------------------------------------------------

wv_e2e_scenario_f() {
  local name="scenario-f-wave-start-no-prompt"
  local d sid errfile
  d="$(wv_e2e_new_scratch)"
  WV_E2E_SCRATCH_DIRS+=("$d")
  errfile="$d/.e2e-stderr.log"

  local prompt="/${plugin_name}:wave-start \"e2e probe feature\""
  wv_e2e_run_session_no_bypass "$d" "$prompt" 90 "$errfile"

  if [ -z "$WV_E2E_JSON" ]; then
    if wv_e2e_looks_like_auth_error "$(cat "$errfile" 2>/dev/null)"; then
      wv_e2e_print_skip_banner "claude refused non-interactive auth during $name: $(cat "$errfile" 2>/dev/null)"
      exit 3
    fi
    wv_sc_fail "$name" "empty output (rc=$WV_E2E_RC); stderr: $(cat "$errfile" 2>/dev/null)"
    return
  fi

  sid="$(wv_e2e_session_id)"
  [ -n "$sid" ] || { wv_sc_fail "$name" "no session_id in output: $WV_E2E_JSON"; return; }

  local denials
  denials="$(printf '%s' "$WV_E2E_JSON" | jq '.permission_denials | length' 2>/dev/null)"
  if [ "$denials" != "0" ]; then
    wv_sc_fail "$name" "/${plugin_name}:wave-start needed $denials permission decision(s) without --dangerously-skip-permissions; result: $(printf '%s' "$WV_E2E_JSON" | jq -r '.result')"
    return
  fi

  if [ ! -f "$d/.wave/state.json" ]; then
    wv_sc_fail "$name" "$d/.wave/state.json was not produced; result: $(printf '%s' "$WV_E2E_JSON" | jq -r '.result')"
    return
  fi

  local wave_val
  wave_val="$(jq -r '.wave // empty' "$d/.wave/state.json" 2>/dev/null)"
  [ -n "$wave_val" ] || { wv_sc_fail "$name" "$d/.wave/state.json has no .wave key: $(cat "$d/.wave/state.json")"; return; }

  wv_sc_pass "$name"
  printf '  prompt: %s\n' "$prompt"
  printf '  session: %s\n' "$sid"
  printf '  permission_denials: 0; %s/.wave/state.json produced (wave=%s)\n' "$d" "$wave_val"
}

wv_e2e_scenario_a
wv_e2e_scenario_b
wv_e2e_scenario_c
wv_e2e_scenario_d
wv_e2e_scenario_e
wv_e2e_scenario_f

printf 'tests/e2e.sh: scenarios total=%d passed=%d failed=%d\n' \
  "$((WV_SC_PASS + WV_SC_FAIL))" "$WV_SC_PASS" "$WV_SC_FAIL"

if [ "$rc" != "0" ] || [ "$WV_SC_FAIL" != "0" ]; then
  exit 1
fi
exit 0
