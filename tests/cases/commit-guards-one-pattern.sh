#!/usr/bin/env bash
# tests/cases/commit-guards-one-pattern.sh — the two attribution-trailer
# guards (the PreToolUse commit guard and the commit-msg hook wave-init.sh
# installs) enforce ONE pattern, defined once in scripts/hooks/lib.sh.
#
# Five trailer forms are each refused by BOTH guards; a plain message and a
# functional mention of the tool name are accepted by BOTH; and the installed
# hook carries exactly the shared constant, not a private copy.
set -u
# shellcheck source=../lib/assert.sh
source "$(dirname "$0")/../lib/assert.sh"

name="$(basename "$0" .sh)"
log="${WV_CASE_LOG:-$WV_RUN_TMP/logs/$name.log}"
mkdir -p "$(dirname "$log")"
rc=0
fail() { printf 'ASSERT FAIL: %s\n' "$*" >&2; rc=1; }

proj="$(mkproj)"
mkdir -p "$proj/.wave"
cp "$WV_TESTS_DIR/fixtures/state/full-fresh.json" "$proj/.wave/state.json"
: > "$proj/.wave/lock"
: > "$proj/README.md"
git -C "$proj" add README.md
git -C "$proj" commit -q -m init

# The commit-msg hook is installed by wave-init into a second project so the
# first one keeps the fixture state the commit guard reads.
hproj="$(mkproj)"
: > "$hproj/README.md"
git -C "$hproj" add README.md
git -C "$hproj" commit -q -m init
( cd "$hproj" && WV_PROJECT="$hproj" CLAUDE_PROJECT_DIR="$hproj" bash "$WV_REPO_ROOT/scripts/wave-init.sh" --wave 1 --mode full --feature x >/dev/null 2>&1 )
hook="$hproj/.git/hooks/commit-msg"
[ -x "$hook" ] || fail "setup: commit-msg hook was not installed"

guard_denies() {
  # guard_denies <message> -> 0 when the commit guard denies it as a trailer.
  local msg="$1" stdin out
  stdin="$(jq -nc --arg cwd "$proj" --arg cmd "git commit -m \"$msg\"" \
    '{hook_event_name:"PreToolUse", tool_name:"Bash", cwd:$cwd, tool_input:{command:$cmd}}')"
  out="$(cd "$proj" && printf '%s' "$stdin" | bash "$WV_REPO_ROOT/scripts/hooks/pre-commit-guard.sh")"
  case "$out" in *'"permissionDecision":"deny"'*'W-COMMIT-TRAILER'*) return 0 ;; esac
  return 1
}
hook_denies() {
  # hook_denies <message> -> 0 when the installed commit-msg hook refuses it.
  local f="$WV_RUN_TMP/$name-msg.txt"
  printf '%s\n' "$1" > "$f"
  "$hook" "$f" >/dev/null 2>&1
  [ "$?" = "1" ]
}

forms=(
  'Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>'
  'Co-Authored-By: Someone <someone@anthropic.com>'
  'Generated with [Claude Code](https://claude.com/claude-code)'
  'Claude-Session: https://example.invalid/s/1'
  'https://claude.ai/code/session_abc123'
)
for f in "${forms[@]}"; do
  g=no; h=no
  guard_denies "add a change $f" && g=yes
  hook_denies "add a change
$f" && h=yes
  printf 'RAN %s form=%s guard=%s hook=%s\n' "$name" "$f" "$g" "$h" >> "$log"
  [ "$g" = "yes" ] || fail "the commit guard did not refuse: $f"
  [ "$h" = "yes" ] || fail "the commit-msg hook did not refuse: $f"
done

for ok in 'add a change' 'fix the claude-config parser'; do
  guard_denies "$ok" && fail "the commit guard refused a clean message: $ok"
  hook_denies "$ok" && fail "the commit-msg hook refused a clean message: $ok"
done

# One definition: the installed hook carries the shared constant verbatim and
# wave-init.sh holds no private copy of any of the five forms.
shared="$(bash -c 'source "$1/scripts/hooks/lib.sh" >/dev/null 2>&1; printf "%s" "${WV_TRAILER_ERE:-}"' _ "$WV_REPO_ROOT")"
[ -n "$shared" ] || fail "scripts/hooks/lib.sh does not define WV_TRAILER_ERE"
[ -n "$shared" ] && ! command grep -qF -- "$shared" "$hook" && fail "the installed hook does not carry WV_TRAILER_ERE verbatim"
command grep -qF 'claude\.ai' "$WV_REPO_ROOT/scripts/wave-init.sh" && fail "wave-init.sh still holds its own copy of a trailer form"
command grep -qE "^WV_PCG_TRAILER_RE='" "$WV_REPO_ROOT/scripts/hooks/pre-commit-guard.sh" && \
  fail "pre-commit-guard.sh still defines its own trailer literal"

exit $rc
