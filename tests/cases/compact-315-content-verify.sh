#!/usr/bin/env bash
# tests/cases/compact-315-content-verify.sh — AC-315.
#
# The JSON case commit-315-checkpoint-contents.json only asserts the hook's
# stdout decision (PreCompact has no additionalContext channel, so "silent"
# is all a JSON case can check). This one actually reads the written
# checkpoint file and asserts every element AC-315 names: the feature
# string, wave id, mode, last done phase, artifacts present, the ledger's
# output-token total, the trigger, and a literal resume command naming the
# file.
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
printf '{"agent":"a1","phase":"TDE-RED","role":"executor","output":250}\n' > "$WV_PROJECT/.wave/ledger.jsonl"
mkdir -p "$WV_PROJECT/.wave"
: > "$WV_PROJECT/.wave/ac.md"    # first declared artifact present, for the inventory
: > "$WV_PROJECT/.wave/acb.md"  # a SECOND row's artifact — the AC row's own `after`
                                # column is empty in hooks/phases.tsv, which is what
                                # made a plain `IFS=$'\t' read -r a b c ...` shift
                                # every field after it and read the AC row's MARKER
                                # regex as its artifact path instead; a single seeded
                                # artifact could still pass by accident if the walk
                                # started misaligned but happened to land on a real
                                # path for the one file checked, so this asserts two
                                # rows independently.

out="$(cd "$WV_PROJECT" && printf '%s' '{"hook_event_name":"PreCompact","trigger":"auto"}' | \
  bash "$WV_REPO_ROOT/scripts/hooks/pre-compact.sh")"
ec=$?
printf 'RAN pre-compact.sh %s decision=contentverify\n' "$name" >> "$log"

[ "$ec" = "0" ] || fail "exit $ec, expected 0"
[ -z "$out" ] || fail "PreCompact has no additionalContext channel; expected empty stdout, got: $out"

cp_file="$(find "$WV_PROJECT/.wave/checkpoints" -type f -name '*-precompact.md' | head -n1)"
[ -n "$cp_file" ] || { fail "no checkpoint file was written"; exit 1; }

check() {
  local needle="$1"
  command grep -qF -- "$needle" "$cp_file" || fail "checkpoint is missing: $needle"
}

check "hook enforcement layer"     # feature
check "wave: 1"
check "mode: full"
check "enforce: block"
check "last phase done: TDE-RED"
check "trigger: auto"
check ".wave/ac.md"                # first artifact actually present
check ".wave/acb.md"               # second artifact actually present (see comment above)
check "total output tokens: 250"   # the ledger's output-token total
check "TDE-RED: 250"
command grep -q '^Resume: cat ' "$cp_file" || fail "no literal resume command line"
command grep -qF -- "$(basename "$cp_file")" "$cp_file" || fail "the resume command does not name the checkpoint file itself"

exit $rc
