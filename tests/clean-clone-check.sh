#!/usr/bin/env bash
# tests/clean-clone-check.sh
#
# Proves the test suite is green from a fresh `git clone` of HEAD, not just
# in a dirty working tree that happens to hold uncommitted/untracked fixture
# files. Clones the current repo's HEAD into a temp dir, runs the full test
# suite there, prints the suite's last output line, and exits with the
# suite's own exit code.
#
# Deliberately `set -u`, never `set -e` — see tests/run.sh for the same
# rationale (this script must still clean up the temp dir on failure).

set -u

WV_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"

cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT

if ! git clone -q "$(git -C "$WV_REPO_ROOT" rev-parse --show-toplevel)" "$tmp"; then
  printf 'clean-clone-check: git clone failed\n' >&2
  exit 1
fi

out="$(cd "$tmp" && bash tests/run.sh 2>&1)"
rc=$?

printf '%s\n' "$out" | tail -1

exit "$rc"
