#!/usr/bin/env bash
# tests/cases/compact-317-no-subprocess.sh - AC-317.
#
# pre-compact.sh must never spawn a `claude` subprocess: it cannot fail for
# lack of context because it never asks for any. A PATH shim whose `claude`
# fails the whole case the moment it is invoked proves it.
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

fakebin="$WV_RUN_TMP/$name-fakebin"
mkdir -p "$fakebin"
marker="$WV_RUN_TMP/$name-claude-was-invoked"
rm -f "$marker"
cat > "$fakebin/claude" <<EOF
#!/bin/sh
touch "$marker"
exit 1
EOF
chmod +x "$fakebin/claude"

stdin='{"hook_event_name":"PreCompact","trigger":"auto"}'
out="$(cd "$WV_PROJECT" && PATH="$fakebin:$PATH" printf '%s' "$stdin" | \
  PATH="$fakebin:$PATH" bash "$WV_REPO_ROOT/scripts/hooks/pre-compact.sh" 2>"$WV_RUN_TMP/$name.stderr")"
ec=$?
printf 'RAN pre-compact.sh %s decision=nosubprocess\n' "$name" >> "$log"

[ "$ec" = "0" ] || fail "exit $ec, expected 0"
[ -f "$marker" ] && fail "the fake claude binary WAS invoked - pre-compact.sh must never spawn an agent"
compgen -G "$WV_PROJECT/.wave/checkpoints/*-precompact.md" >/dev/null 2>&1 || \
  fail "no checkpoint file was written even though nothing failed"

exit $rc
