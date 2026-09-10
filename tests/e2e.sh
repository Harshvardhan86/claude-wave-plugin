#!/usr/bin/env bash
# tests/e2e.sh — the real headless load proof (spec section 12, AC-378/379).
#
# `claude plugin validate .` (tests/cases/wiring-378-plugin-validate.sh) is
# necessary and explicitly not sufficient: it never catches the "Duplicate
# hooks file detected ... Hook load failed" failure mode that a `hooks`
# field in .claude-plugin/plugin.json produces (Global Constraint 1) —
# that mode was hit org-wide on 2026-09-09 with another plugin, and the
# published docs are silent on it. This script is the only thing that
# would catch a regression: it runs a real headless `claude` session with
# this repo loaded as a --plugin-dir and inspects its --debug-file log.
#
# Task 11 ships the load-proof section only (deliverable b of the task-11
# brief); Task 12 appends the rest of spec section 12's "End to end" bullet
# (the tagged-dispatch / commit-guard / additionalContext / no-state-file
# scenarios) to this same file, which is why this file is a standalone
# script under tests/, not a tests/cases/*.sh case: tests/run.sh never
# discovers it (it only walks tests/cases/**), exactly like
# tests/clean-clone-check.sh.
#
# Skips itself LOUDLY with exit 3 when `claude` is not on PATH — never a
# silent pass (tests/cases/README.md's "a suite that cannot run at all ...
# is reported SKIPPED, never counted as a pass").
#
# Measured platform fact (2.1.267, this file's own live run, 2026-09-10),
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
set -u

WV_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

wv_e2e_fail() {
  printf 'tests/e2e.sh: FAIL: %s\n' "$*" >&2
}

if ! command -v claude >/dev/null 2>&1; then
  printf 'tests/e2e.sh: SKIPPED — claude is not on PATH; the load proof was not run.\n' >&2
  exit 3
fi

plugin_name="$(jq -r '.name // empty' "$WV_REPO_ROOT/.claude-plugin/plugin.json" 2>/dev/null)"
if [ -z "$plugin_name" ]; then
  wv_e2e_fail "could not read .name from $WV_REPO_ROOT/.claude-plugin/plugin.json"
  exit 1
fi

wv_tmp="$(mktemp -d "${TMPDIR:-/tmp}/wave-plugin-e2e.XXXXXX")"
cleanup() { rm -rf "$wv_tmp"; }
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

exit $rc
