#!/usr/bin/env bash
# tests/cases/compact-319-earlier-checkpoints-unchanged.sh - AC-319.
#
# Two checkpoint files already exist under .wave/checkpoints/; running
# pre-compact.sh writes a THIRD one and leaves the earlier two byte-identical.
set -u
# shellcheck source=../lib/assert.sh
source "$(dirname "$0")/../lib/assert.sh"

name="$(basename "$0" .sh)"
log="${WV_CASE_LOG:-$WV_RUN_TMP/logs/$name.log}"
mkdir -p "$(dirname "$log")"
rc=0
fail() { printf 'ASSERT FAIL: %s\n' "$*" >&2; rc=1; }

WV_PROJECT="$(mkproj)"
seed_state state/full-red-done.json

mkdir -p "$WV_PROJECT/.wave/checkpoints"
printf 'first checkpoint, untouched\n' > "$WV_PROJECT/.wave/checkpoints/2020-01-01T00:00:00Z-precompact.md"
printf 'second checkpoint, untouched\n' > "$WV_PROJECT/.wave/checkpoints/2020-01-02T00:00:00Z-precompact.md"
sum_before="$(cd "$WV_PROJECT/.wave/checkpoints" && sha256sum -- *.md | sort)"
count_before=$(find "$WV_PROJECT/.wave/checkpoints" -type f | wc -l)

stdin='{"hook_event_name":"PreCompact","trigger":"auto"}'
out="$(cd "$WV_PROJECT" && printf '%s' "$stdin" | bash "$WV_REPO_ROOT/scripts/hooks/pre-compact.sh")"
ec=$?
printf 'RAN pre-compact.sh %s decision=twoexisting\n' "$name" >> "$log"

[ "$ec" = "0" ] || fail "exit $ec, expected 0"
count_after=$(find "$WV_PROJECT/.wave/checkpoints" -type f | wc -l)
[ "$count_after" = "$((count_before + 1))" ] || \
  fail "expected exactly one new file (had $count_before, now $count_after)"

sum_after="$(cd "$WV_PROJECT/.wave/checkpoints" && sha256sum 2020-01-01T00:00:00Z-precompact.md 2020-01-02T00:00:00Z-precompact.md | sort)"
[ "$sum_before" = "$sum_after" ] || \
  fail "the two pre-existing checkpoints changed: before=[$sum_before] after=[$sum_after]"

exit $rc
