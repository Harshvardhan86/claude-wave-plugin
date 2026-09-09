#!/usr/bin/env bash
# tests/cases/_selfcheck/data-coverage-flag.sh — finding 3, fix round 3
#
# Regression test for the `--coverage` split in tests/run.sh (added in Task
# 3 fix round 1, 612c8a2). Nothing ever exercised it: proves (a) without
# the flag, a corpus with an uncovered rule id exits 0 and prints the
# summary line, and (b) with --coverage the same corpus exits non-zero and
# names the rule.
#
# This builds a FULLY SYNTHETIC, isolated copy of the harness (tests/run.sh
# + tests/lib/assert.sh + an empty tests/cases/ + a one-row hooks/reasons.tsv)
# rather than copying the real tests/cases/ tree. Copying the real corpus
# would make this very file — data-coverage-flag.sh — discoverable by the
# nested tests/run.sh invocation, which would then run itself recursively.
# An empty synthetic cases/ dir also makes the result deterministic and
# independent of which rule ids the real corpus does or doesn't cover yet
# (that set changes across Tasks 5-13).

set -u

# shellcheck source=tests/lib/assert.sh
source "$(dirname "$0")/../../lib/assert.sh"

cd "$(git rev-parse --show-toplevel)"

name="${WV_CASE_NAME:-$(basename "$0" .sh)}"
if [ -n "${WV_CASE_LOG:-}" ]; then
  printf 'RAN %s %s decision=silent\n' "${BASH_SOURCE[0]}" "$name" >> "$WV_CASE_LOG"
fi

rc=0
fail() { printf '%s\n' "$*" >&2; rc=1; }

REPO_ROOT="$(git rev-parse --show-toplevel)"
sandbox="$(mktemp -d "$WV_RUN_TMP/coverage-flag-sandbox.XXXXXX")"
trap 'rm -rf "$sandbox"' EXIT

mkdir -p "$sandbox/tests/lib" "$sandbox/tests/cases" "$sandbox/hooks"
cp "$REPO_ROOT/tests/run.sh" "$sandbox/tests/run.sh"
cp "$REPO_ROOT/tests/lib/assert.sh" "$sandbox/tests/lib/assert.sh"

# A synthetic rule id that no case anywhere declares — the universe comes
# only from hooks/reasons.tsv here, since tests/cases/ is empty.
probe_rule="W-SELFTEST-COVERAGE-PROBE"
cat > "$sandbox/hooks/reasons.tsv" <<EOF
# synthetic reasons.tsv for data-coverage-flag.sh — not the real file
rule_id	precedence	printf_template
$probe_rule	1	[$probe_rule] %s; remedy: synthetic probe with no test coverage, used only by this regression test.
EOF

# ---- (a) default: exit 0, prints the gap but does not fail -------------

default_out="$(cd "$sandbox" && bash tests/run.sh 2>&1)"
default_rc=$?

if [ "$default_rc" != "0" ]; then
  fail "default invocation (no --coverage) should exit 0 on an uncovered-rule corpus, got exit $default_rc"
fi
case "$default_out" in
  *"coverage: rule $probe_rule: no positive case,no negative control"*) : ;;
  *) fail "default invocation should print the per-rule coverage gap line for $probe_rule; got:
$default_out" ;;
esac
case "$default_out" in
  *"coverage: 1 rule(s) without cases (run with --coverage to enforce)"*) : ;;
  *) fail "default invocation should print the coverage summary line naming 1 rule; got:
$default_out" ;;
esac
case "$default_out" in
  *"FAIL coverage:"*) fail "default invocation must not count the coverage gap as a FAIL" ;;
  *) : ;;
esac
case "$default_out" in
  *"total=0 failed=0"* | *"failed=0"*) : ;;
  *) fail "default invocation should report failed=0; got:
$default_out" ;;
esac

# ---- (b) --coverage: exit non-zero, names the rule as a FAIL -----------

coverage_out="$(cd "$sandbox" && bash tests/run.sh --coverage 2>&1)"
coverage_rc=$?

if [ "$coverage_rc" = "0" ]; then
  fail "--coverage invocation should exit non-zero on an uncovered-rule corpus, got exit 0"
fi
case "$coverage_out" in
  *"FAIL coverage: rule $probe_rule: no positive case,no negative control"*) : ;;
  *) fail "--coverage invocation should FAIL naming $probe_rule; got:
$coverage_out" ;;
esac
case "$coverage_out" in
  *"failed=0"*) fail "--coverage invocation should report a non-zero failed= count; got:
$coverage_out" ;;
  *) : ;;
esac

exit $rc
