#!/usr/bin/env bash
# tests/cases/commit-311-scale-timing.sh - AC-311.
#
# A 1 MB single-line command carrying exactly one `Co-Authored-By: Claude`
# trailer denies within 2 seconds (no windowed/quadratic scan blowing up on
# a huge command); and separately, a command whose JSON-encoded string
# carries a NUL byte decides correctly (bash cannot hold an embedded NUL in
# a variable at all, so this proves "no hang, no crash, a well-formed
# decision" rather than "sees past the NUL").
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

run_timed() {
  # run_timed <stdin-file> -> sets TIMED_OUT / TIMED_EXIT / TIMED_SECS.
  local f="$1" start end
  start="$(date +%s.%N)"
  TIMED_OUT="$(cd "$WV_PROJECT" && bash "$WV_REPO_ROOT/scripts/hooks/pre-commit-guard.sh" < "$f")"
  TIMED_EXIT=$?
  end="$(date +%s.%N)"
  TIMED_SECS="$(awk -v a="$start" -v b="$end" 'BEGIN{printf "%.3f", b-a}')"
}

# ---- 1 MB single-line command with one trailer -----------------------------
big_stdin="$WV_RUN_TMP/$name-big.json"
python3 "$WV_TESTS_DIR/tools/gen-commit-311-fixtures.py" big "$big_stdin"

run_timed "$big_stdin"
printf 'RAN pre-commit-guard.sh %s decision=1mb exit=%s secs=%s\n' "$name" "$TIMED_EXIT" "$TIMED_SECS" >> "$log"
[ "$TIMED_EXIT" = "0" ] || fail "1MB case: exit $TIMED_EXIT"
case "$TIMED_OUT" in
  *'"permissionDecision":"deny"'*'W-COMMIT-TRAILER'*) : ;;
  *) fail "1MB case: expected a W-COMMIT-TRAILER deny, got: $TIMED_OUT" ;;
esac
awk -v s="$TIMED_SECS" 'BEGIN{exit !(s+0 < 2.0)}' || fail "1MB case took ${TIMED_SECS}s, over the 2s bound"

# ---- a command whose JSON string carries an embedded NUL byte -------------
nul_stdin="$WV_RUN_TMP/$name-nul.json"
python3 "$WV_TESTS_DIR/tools/gen-commit-311-fixtures.py" nul "$nul_stdin"

run_timed "$nul_stdin"
printf 'RAN pre-commit-guard.sh %s decision=nul exit=%s secs=%s\n' "$name" "$TIMED_EXIT" "$TIMED_SECS" >> "$log"
[ "$TIMED_EXIT" = "0" ] || fail "NUL-byte case: exit $TIMED_EXIT"
awk -v s="$TIMED_SECS" 'BEGIN{exit !(s+0 < 2.0)}' || fail "NUL-byte case took ${TIMED_SECS}s, over the 2s bound"
# No hang, no crash, and a decision that is unambiguously empty (allow) or a
# complete deny object - never a truncated half-object on stdout.
case "$TIMED_OUT" in
  '') : ;;
  *'"hookSpecificOutput"'*'"permissionDecision"'*'}}') : ;;
  *) fail "NUL-byte case: stdout is neither empty nor a complete JSON object: $TIMED_OUT" ;;
esac

exit $rc
