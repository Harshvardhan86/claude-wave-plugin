#!/usr/bin/env bash
# tests/cases/commit-312-brokengrep-warns.sh - AC-312 (second half).
#
# A `grep` on PATH that declines every file (prints no count, exits
# non-zero) - simulating the wrapped-searcher failure Global Constraint 7
# exists for - must make the staged-path scan warn W-STATE naming a failed
# scan, and must NOT print a bare/silent allow: the scan genuinely did not
# run, so the script has measured nothing and has to say so.
set -u
# shellcheck source=../lib/assert.sh
source "$(dirname "$0")/../lib/assert.sh"

name="$(basename "$0" .sh)"
log="${WV_CASE_LOG:-$WV_RUN_TMP/logs/$name.log}"
mkdir -p "$(dirname "$log")"
rc=0
fail() { printf 'ASSERT FAIL: %s\n' "$*" >&2; rc=1; }

WV_PROJECT="$(mkproj)"
seed_state state/full-fresh.json
mkdir -p "$WV_PROJECT/tasks"
: > "$WV_PROJECT/tasks/todo.md"
git -C "$WV_PROJECT" add tasks/todo.md

fakebin="$WV_RUN_TMP/$name-fakebin"
mkdir -p "$fakebin"
cat > "$fakebin/grep" <<'FAKEGREP'
#!/bin/sh
# A "declining" grep: no output, non-zero exit, on every invocation - the
# exact shape Global Constraint 7 warns a wrapped searcher can take.
exit 1
FAKEGREP
chmod +x "$fakebin/grep"

stdin='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git commit -m wip"}}'
out="$(cd "$WV_PROJECT" && PATH="$fakebin:$PATH" printf '%s' "$stdin" | \
  PATH="$fakebin:$PATH" bash "$WV_REPO_ROOT/scripts/hooks/pre-commit-guard.sh")"
ec=$?
printf 'RAN pre-commit-guard.sh %s decision=brokengrep\n' "$name" >> "$log"

[ "$ec" = "0" ] || fail "exit $ec, expected 0 (a hook never fails closed on its own bug)"
case "$out" in
  *'"permissionDecision":"deny"'*) fail "a broken grep must never manufacture a deny (nothing was measured): $out" ;;
esac
case "$out" in
  *'W-STATE'*'scan'*'no count'*) : ;;
  *) fail "expected a W-STATE warning naming a failed scan, got: $out" ;;
esac
[ -n "$out" ] || fail "expected a warning, not a bare silent allow"

exit $rc
