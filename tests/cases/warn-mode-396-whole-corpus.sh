#!/usr/bin/env bash
# tests/cases/warn-mode-396-whole-corpus.sh — AC-394, AC-396 and AC-397: the WHOLE
# deny/block corpus, replayed under `enforce:"warn"` and under `enforce:"block"`.
#
# tests/cases/warn-mode-393-per-script.sh proves the conversion one rule per script,
# in detail — same rendered text, one JSON object, the right channel per event, the
# ledger line's shape at SubagentStop. This case proves the OTHER half, which detail
# cannot: that the escape hatch is TOTAL. A rule that quietly kept denying under
# enforce=warn, or one that stopped denying under enforce=block, would pass every
# per-rule case that did not happen to name it.
#
# The engine is tests/tools/reason-corpus.sh --replay-enforce, not a loop of its own:
# that tool already enumerates the corpus for its reason checks, and a second copy of
# "which cases are the deny corpus" is a second thing to keep in step — the copy
# nobody runs is the one that drifts.
#
# It costs about two minutes (219 fixtures, two runs each). That is the price of the
# claim: the AC says the whole corpus, and a sample of it is a different, weaker
# statement that would be reported as if it were this one.
set -u

# shellcheck source=tests/lib/assert.sh
source "$(dirname "$0")/../lib/assert.sh"

name="${WV_CASE_NAME:-$(basename "$0" .sh)}"
log="${WV_CASE_LOG:-$WV_RUN_TMP/logs/$name.log}"
rc=0
fail() { printf 'ASSERT FAIL: %s\n' "$*" >&2; rc=1; }

out="$WV_RUN_TMP/$name.out"
( unset WV_RUN_TMP; bash "$WV_REPO_ROOT/tests/tools/reason-corpus.sh" --replay-enforce ) > "$out" 2>&1
tool_rc=$?

printf 'RAN tests/tools/reason-corpus.sh %s decision=allow\n' "$name" >> "$log"

summary="$(command grep -m1 '^replayed=' "$out")"
if [ -z "$summary" ]; then
  fail "the replay printed no summary line (exit $tool_rc); output tail: $(tail -c 800 "$out")"
  exit $rc
fi

replayed=""; excluded=""; block_ok=""; warn_ok=""; findings=""
for f in $summary; do
  case "$f" in
    replayed=*) replayed="${f#replayed=}" ;;
    excluded=*) excluded="${f#excluded=}" ;;
    block_ok=*) block_ok="${f#block_ok=}" ;;
    warn_ok=*)  warn_ok="${f#warn_ok=}" ;;
    findings=*) findings="${f#findings=}" ;;
  esac
done

case "$replayed" in ''|*[!0-9]*) fail "could not read the replay count from '$summary'"; exit $rc ;; esac

# A positive run marker, not just a zero exit: a replay that enumerated nothing
# would also report zero findings.
if [ "$replayed" -lt 100 ]; then
  fail "only $replayed fixture(s) were replayed — that is a failed enumeration, not a small corpus"
fi
[ "$block_ok" = "$replayed" ] || \
  fail "enforce=block: $block_ok of $replayed produced their original deny/block — the inverse control is what stops the warn half being vacuous"
[ "$warn_ok" = "$replayed" ] || \
  fail "enforce=warn: $warn_ok of $replayed reached a warn channel with their own rule id"
if [ "${findings:-1}" != "0" ]; then
  fail "the replay reported $findings finding(s):
$(command grep '^FAIL ' "$out")"
fi
[ "$tool_rc" = "0" ] || fail "the replay exited $tool_rc"

printf 'enforce replay: %s\n' "$summary"
exit $rc
