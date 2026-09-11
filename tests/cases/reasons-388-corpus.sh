#!/usr/bin/env bash
# tests/cases/reasons-388-corpus.sh — AC-388, AC-389, AC-390, AC-399, AC-400's
# reason half, and the arity guard.
#
# The corpus sweep itself lives in tests/tools/reason-corpus.sh, because it is
# also a standalone release gate (README's gate list runs it). This case runs that
# one implementation rather than restating it: two copies of a sweep are two
# sources of truth about what a reason must look like, and the one nobody runs is
# the one that rots.
#
# What the tool proves, per rule id in hooks/reasons.tsv, over EVERY positive case
# in the corpus (250 runs at the time of writing, not one per id):
#   * the reason starts with `[<id>] ` and carries exactly ONE `W-` token, and it
#     is the rule's own (AC-389)
#   * it is <= 400 characters, has no newline, has >= 20 non-whitespace
#     characters (AC-390; 400 is tighter than AC-390's own 600)
#   * it carries a `remedy:` clause and no unrendered `%s` / `%d`
#   * it does not name the project root — a path inside the project is named
#     relative to it, the one exception being a warning whose whole claim is that
#     a path resolved OUTSIDE the root
#   * the template's literal segments appear in it, in order, first as prefix and
#     last as suffix (AC-388's "byte-identical to the template rendered with the
#     fixture's values", written so it can actually fail on drift)
#   * every id has a positive case AND a negative control, and every `W-` literal
#     any script names has a template (AC-399)
#   * every emitter call site passes exactly as many arguments as its template has
#     specifiers — printf REUSES its format string on a surplus, which renders the
#     whole reason twice and puts TWO rule tokens in it
#
# `set -u`, never `set -e`.
set -u

# shellcheck source=tests/lib/assert.sh
source "$(dirname "$0")/../lib/assert.sh"

name="${WV_CASE_NAME:-$(basename "$0" .sh)}"
log="${WV_CASE_LOG:-$WV_RUN_TMP/logs/$name.log}"
mkdir -p "$(dirname "$log")"
rc=0
fail() { printf 'ASSERT FAIL: %s\n' "$*" >&2; rc=1; }

out="$WV_RUN_TMP/$name.out"
# The tool is given its OWN scratch root by unsetting WV_RUN_TMP for it: a nested
# run inheriting this one's would write its per-case logs beside ours, and
# tests/run.sh's run-marker check reads those.
( unset WV_RUN_TMP; bash "$WV_REPO_ROOT/tests/tools/reason-corpus.sh" ) > "$out" 2>&1
tool_rc=$?

printf 'RAN tests/tools/reason-corpus.sh %s decision=allow\n' "$name" >> "$log"

# The summary line is the only thing trusted, and its ABSENCE is a failure: a tool
# that died before printing it has measured nothing however plausible its exit
# status looks.
summary="$(command grep -m1 '^rules=' "$out")"
if [ -z "$summary" ]; then
  fail "reason-corpus.sh printed no summary line (exit $tool_rc); output tail: $(tail -c 600 "$out")"
  exit $rc
fi

rules=""; driven=""; cases=""; findings=""
for f in $summary; do
  case "$f" in
    rules=*) rules="${f#rules=}" ;;
    driven=*) driven="${f#driven=}" ;;
    cases=*) cases="${f#cases=}" ;;
    findings=*) findings="${f#findings=}" ;;
  esac
done

case "$rules" in ''|*[!0-9]*) fail "could not read the rule count from '$summary'" ;; esac
case "$findings" in ''|*[!0-9]*) fail "could not read the finding count from '$summary'" ;; esac

# A positive run marker, not just a zero exit: a sweep that drove nothing would
# also report zero findings.
if [ "${rules:-0}" -lt 30 ]; then
  fail "reason-corpus.sh measured only ${rules:-0} rule(s) — that is a failed sweep, not a clean one"
fi
if [ "$driven" != "$rules" ]; then
  fail "reason-corpus.sh drove $driven of $rules rules"
fi
if [ "${cases:-0}" -lt "${rules:-0}" ]; then
  fail "reason-corpus.sh ran ${cases:-0} case(s) for ${rules:-0} rule(s) — fewer cases than rules means it skipped some"
fi
if [ "${findings:-1}" != "0" ]; then
  fail "reason-corpus.sh reported $findings finding(s):
$(command grep '^FAIL ' "$out")"
fi
if [ "$tool_rc" != "0" ]; then
  fail "reason-corpus.sh exited $tool_rc"
fi

printf 'reason corpus: %s\n' "$summary"
exit $rc
