#!/usr/bin/env bash
# tests/cases/wiring-379-load-proof-wired.sh — AC-379 (the wiring half).
#
# AC-379's behavioural claim — a real headless `claude --debug-file <log>
# --plugin-dir . -p ok` run exits 0 and its log carries no "Duplicate hooks"
# / "Hook load failed" and does carry this plugin's registration — is
# proven by actually running tests/e2e.sh (deliverable b of the task-11
# brief); that run is live (spawns a real model session) and its evidence is
# quoted verbatim in the task report, run once by hand rather than on every
# `tests/run.sh` invocation, so that the fast unit sweep this case lives in
# stays fast and does not require live `claude` auth on every dev loop or
# CI box.
#
# This case is the STATIC half: it proves tests/e2e.sh is actually built to
# perform that proof (skip-guarded, invokes claude with the right flags,
# fails closed on both banned strings) rather than merely existing. It runs
# on every `tests/run.sh` invocation and does not itself spawn `claude`.
set -u

# shellcheck source=tests/lib/assert.sh
source "$(dirname "$0")/../lib/assert.sh"

name="$(basename "$0" .sh)"
log="${WV_CASE_LOG:-$WV_RUN_TMP/logs/$name.log}"
mkdir -p "$(dirname "$log")"

rc=0
fail() { printf 'ASSERT FAIL: %s\n' "$*" >&2; rc=1; }

e2e="$WV_REPO_ROOT/tests/e2e.sh"

if [ ! -f "$e2e" ]; then
  fail "$e2e does not exist"
  printf 'RAN wiring-379 e2e.sh=absent\n' >> "$log"
  exit 1
fi
[ -x "$e2e" ] || fail "$e2e is not executable"

# Skip-guard: never a silent pass when claude is absent.
command grep -q "command -v claude" "$e2e" || fail "$e2e has no 'claude is on PATH' guard"
command grep -q "exit 3" "$e2e" || fail "$e2e does not skip with exit 3"

# The real invocation shape (spec section 12 / AC-379's GIVEN).
command grep -q -- '--debug-file' "$e2e" || fail "$e2e does not pass --debug-file"
command grep -q -- '--plugin-dir' "$e2e" || fail "$e2e does not pass --plugin-dir"
command grep -qE -- '(^|[^-])-p ' "$e2e" || fail "$e2e does not pass -p"

# The two failure strings AC-379 requires the log be checked against.
command grep -qF 'Duplicate hooks' "$e2e" || fail "$e2e never checks for 'Duplicate hooks'"
command grep -qF 'Hook load failed' "$e2e" || fail "$e2e never checks for 'Hook load failed'"

# The registration proof (this plugin's own name, read from the manifest,
# never hardcoded, so the check cannot silently drift from the real name).
command grep -q "plugin.json" "$e2e" || fail "$e2e does not read the plugin name from plugin.json"
command grep -qF 'Loading hooks from plugin' "$e2e" || fail "$e2e does not check the 'Loading hooks from plugin' line"
command grep -qF 'Registered' "$e2e" || fail "$e2e does not check the aggregate 'Registered N hooks' line"

# hooks.json itself declares PreToolUse and SubagentStop entries (the two
# events AC-379 names) — the static complement to the live log's inability
# to name an event per plugin (see tests/e2e.sh's own header comment for the
# measured platform fact this works around).
hooks_json="$WV_REPO_ROOT/hooks/hooks.json"
if [ -f "$hooks_json" ]; then
  jq -e '.hooks.PreToolUse | length > 0' "$hooks_json" >/dev/null 2>&1 \
    || fail "$hooks_json declares no PreToolUse entries"
  jq -e '.hooks.SubagentStop | length > 0' "$hooks_json" >/dev/null 2>&1 \
    || fail "$hooks_json declares no SubagentStop entries"
else
  fail "$hooks_json does not exist"
fi

printf 'RAN wiring-379 wired=%s\n' "$([ "$rc" = "0" ] && echo yes || echo no)" >> "$log"
exit $rc
