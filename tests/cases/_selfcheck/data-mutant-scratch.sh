#!/usr/bin/env bash
# tests/cases/_selfcheck/data-mutant-scratch.sh — a mutation driver leaves no
# harness scratch behind.
#
# Every killed mutant is, by design, a RED run of tests/run.sh, and the
# harness keeps the scratch directory of a red run (tests/lib/assert.sh) so a
# person can read its case logs. Run from a driver that would leave one
# ${TMPDIR:-/tmp}/wave-plugin-tests.* directory per killed mutant (~190 per
# full sweep). The drivers therefore run the harness under a TMPDIR inside
# their OWN temp root and remove it with that root.
#
# Proves, under a PRIVATE TMPDIR:
#   (a) mutants-lifecycle-hooks.sh --mutant <label> kills its mutant and leaves
#       the private TMPDIR empty;
#   (b) the same for mutants-subagent-stop.sh;
#   (c) every tests/run.sh invocation in every tests/tools/mutants-*.sh driver
#       is scoped to a driver-owned TMPDIR (the drivers without --mutant are
#       too slow to run here, so they are held to the same line by reading);
# while a genuine red run outside a driver still keeps its directory and prints
# the path (data-scratch-cleanup (b) proves that half and stays green).
set -u

# shellcheck source=tests/lib/assert.sh
source "$(dirname "$0")/../../lib/assert.sh"

name="${WV_CASE_NAME:-$(basename "$0" .sh)}"
if [ -n "${WV_CASE_LOG:-}" ]; then
  printf 'RAN %s %s decision=silent\n' "${BASH_SOURCE[0]}" "$name" >> "$WV_CASE_LOG"
fi

rc=0
fail() { printf 'ASSERT FAIL: %s\n' "$*" >&2; rc=1; }

REPO_ROOT="$WV_REPO_ROOT"
private="$(mktemp -d "$WV_RUN_TMP/mutant-scratch-private.XXXXXX")"
wv_on_exit 'chmod -R u+rwX "$private" 2>/dev/null; rm -rf "$private"'

leftovers() { find "$private" -mindepth 1 -maxdepth 1 2>/dev/null | sort; }

one_mutant() {
  # one_mutant <driver basename> <label>
  local drv="$1" label="$2" out r left
  rm -rf "$private"/* 2>/dev/null
  out="$(cd "$REPO_ROOT" && env -u WV_RUN_TMP -u WV_KEEP_TMP -u WV_CASE_LOG -u WV_CASE_NAME TMPDIR="$private" \
    timeout 300 bash "tests/tools/$drv" --mutant "$label" 2>&1)"; r=$?
  [ "$r" = "0" ] || fail "$drv --mutant $label exited $r (the mutant must be applied, killed and restored): $(printf '%s' "$out" | tail -n 5)"
  case "$out" in
    *"$label"*killed*) : ;;
    *) fail "$drv --mutant $label: no 'killed' row in: $(printf '%s' "$out" | tail -n 5)" ;;
  esac
  left="$(leftovers)"
  [ -z "$left" ] || fail "$drv --mutant $label left scratch behind in its TMPDIR: $left"
}

# ---- (a) / (b) ---------------------------------------------------------------
one_mutant mutants-lifecycle-hooks.sh leftovermarkerfirst
one_mutant mutants-subagent-stop.sh drainremoved

# ---- (c) every driver's harness call is TMPDIR-scoped -------------------------
n=0
for drv in "$REPO_ROOT"/tests/tools/mutants-*.sh; do
  while IFS= read -r line; do
    n=$((n + 1))
    case "$line" in
      *'TMPDIR="$WV_SCRATCH"'*'bash tests/run.sh'*) : ;;
      *) fail "$(basename "$drv"): a tests/run.sh call is not scoped to the driver's TMPDIR: $line" ;;
    esac
  done < <(command grep -E 'bash tests/run\.sh' "$drv" | command grep -vE '^[[:space:]]*#')
done
[ "$n" -ge 6 ] || fail "(c) expected at least six driver calls to tests/run.sh, found $n (the scan read nothing)"

exit $rc
