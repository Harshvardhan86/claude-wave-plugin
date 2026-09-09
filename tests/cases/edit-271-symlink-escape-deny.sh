#!/usr/bin/env bash
# tests/cases/edit-271-symlink-escape-deny.sh — AC-271.
#
# `.wave/link` is a symlink to `src` (project source). A Write targeting
# `.wave/link/app.ts` must still deny W-EDIT: the `.wave/` exemption is
# decided AFTER `realpath`, so a symlink cannot launder an implementation
# edit. `seed.files` (the JSON case schema) can only write plain file
# content, never a symlink, so this case builds its own project by hand —
# same reason budget-178.sh and the other multi-step `.sh` cases do.
set -u

# shellcheck source=tests/lib/assert.sh
source "$(dirname "$0")/../lib/assert.sh"

name="${WV_CASE_NAME:-$(basename "$0" .sh)}"
log="${WV_CASE_LOG:-$WV_RUN_TMP/logs/$name.log}"
rc=0
fail() { printf 'ASSERT FAIL: %s\n' "$*" >&2; rc=1; }

WV_PROJECT=""
WV_PROJECT="$(mkproj)"
seed_state state/valid-full.json
mkdir -p "$WV_PROJECT/src"
printf 'x\n' > "$WV_PROJECT/src/app.ts"
git -C "$WV_PROJECT" add -- src/app.ts >/dev/null 2>&1
ln -s "$WV_PROJECT/src" "$WV_PROJECT/.wave/link"

STDIN_JSON='{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":".wave/link/app.ts"}}'

errf="$(mktemp "$WV_RUN_TMP/$name.stderr.XXXXXX")"
WV_LAST_STDOUT="$(cd "$WV_PROJECT" && printf '%s' "$STDIN_JSON" | bash "$WV_REPO_ROOT/scripts/hooks/pre-edit.sh" 2>"$errf")"
WV_LAST_EXIT=$?
WV_LAST_STDERR="$(cat "$errf")"
rm -f "$errf"
printf 'RAN pre-edit.sh %s decision=%s\n' "$name" "$(_wv_classify_decision)" >> "$log"

assert_deny W-EDIT || fail "$WV_ASSERT_DIFF"
assert_reason_contains "src/app.ts" || fail "$WV_ASSERT_DIFF"
assert_stdout_absent ".wave/link" || fail "$WV_ASSERT_DIFF (the reason must quote the REAL path, not the symlink through which it was reached)"

exit $rc
