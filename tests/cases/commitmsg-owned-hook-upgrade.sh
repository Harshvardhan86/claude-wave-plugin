#!/usr/bin/env bash
# tests/cases/commitmsg-owned-hook-upgrade.sh — the installed commit-msg hook
# is versioned, and only a hook carrying the owned marker line is upgraded.
#
#   fresh    no hook: wave-init.sh installs the current template, which carries
#            the owned marker line and WV_TRAILER_ERE verbatim; state
#            commit_msg_hook "installed".
#   old      an owned hook from an older template (marker line, template 1, a
#            narrower pattern): wave-init.sh rewrites it to the current
#            template, says so on stderr, records "upgraded", and the rewritten
#            hook refuses a session line the old pattern let through.
#   current  re-running over the current template leaves it byte-identical and
#            records "installed".
#   released the exact hook 0.2.0 and 0.2.1 installed (no marker line; the
#            plugin's data file hooks/released/commit-msg-0.2.1.hook is that
#            template's bytes, pinned to the v0.2.1 wave-init.sh heredoc by
#            tests/cases/commitmsg-released-data-pin.sh and checked equal to a
#            real 0.2.1 install): recognised by its full content, upgraded to
#            the current template byte for byte, and the next run is
#            idempotent.
#   modified the same template with any change (a line appended, the pattern
#            edited, the final newline dropped) is a user's hook: left
#            byte-identical, "skipped-existing", with the refresh-path notice.
#   foreign  a hook without the marker line — including one that merely
#            mentions the plugin, and an unmarked hook an earlier wave-init.sh
#            wrote — is left byte-identical, "skipped-existing", and the notice
#            gives the refresh path for an earlier plugin's hook.
set -u

# shellcheck source=tests/lib/assert.sh
source "$(dirname "$0")/../lib/assert.sh"

name="$(basename "$0" .sh)"
log="${WV_CASE_LOG:-$WV_RUN_TMP/logs/$name.log}"
mkdir -p "$(dirname "$log")"

rc=0
fail() { printf 'ASSERT FAIL: %s\n' "$*" >&2; rc=1; }

# The shared pattern, read as data from lib.sh (never by sourcing the hook).
ERE="$(bash -c 'source "$1"; printf "%s" "$WV_TRAILER_ERE"' _ "$WV_REPO_ROOT/scripts/hooks/lib.sh")"
[ -n "$ERE" ] || fail "could not read WV_TRAILER_ERE from lib.sh"
MARKER_RE='^# wave-orchestrator-owned commit-msg hook; template [0-9]+$'

fresh_project() {
  WV_PROJECT="$(mkproj)"
  : > "$WV_PROJECT/README.md"
  git -C "$WV_PROJECT" add README.md
  git -C "$WV_PROJECT" commit -q -m init
  HOOK="$WV_PROJECT/.git/hooks/commit-msg"
  mkdir -p "$(dirname "$HOOK")"
}

current_template_ok() {
  local label="$1"
  command grep -qE "$MARKER_RE" "$HOOK" || fail "$label: the hook carries no owned marker line"
  command grep -qxF "pattern='$ERE'" "$HOOK" || fail "$label: the hook does not carry WV_TRAILER_ERE verbatim"
  [ -x "$HOOK" ] || fail "$label: the hook is not executable"
}

refuses() {
  # refuses <label> <message line> — the installed hook exits 1 on it.
  local label="$1" msg="$WV_RUN_TMP/$name-msg.txt"
  printf 'subject\n\n%s\n' "$2" > "$msg"
  bash "$HOOK" "$msg" >/dev/null 2>&1
  [ "$?" = "1" ] || fail "$label: the hook did not refuse '$2'"
}

# ---- fresh ------------------------------------------------------------------
fresh_project
run_cli scripts/wave-init.sh --wave 1 --mode full --feature x
[ "$CLI_EXIT" = "0" ] || fail "fresh: exit $CLI_EXIT ($CLI_STDERR)"
current_template_ok fresh
assert_state '.commit_msg_hook == "installed"' || fail "fresh: want installed"
CURRENT_SUM="$(sha256sum "$HOOK" | awk '{print $1}')"

# ---- current: idempotent ----------------------------------------------------
run_cli scripts/wave-init.sh --wave 2 --mode full --feature y --force
[ "$CLI_EXIT" = "0" ] || fail "current: exit $CLI_EXIT ($CLI_STDERR)"
[ "$(sha256sum "$HOOK" | awk '{print $1}')" = "$CURRENT_SUM" ] || fail "current: the current template was rewritten differently"
assert_state '.commit_msg_hook == "installed"' || fail "current: want installed"

# ---- old owned hook ---------------------------------------------------------
fresh_project
cat > "$HOOK" <<'OLD'
#!/usr/bin/env bash
# wave-orchestrator-owned commit-msg hook; template 1
set -u
msg_file="${1:-}"
[ -n "$msg_file" ] && [ -r "$msg_file" ] || exit 0
pattern='Co-Authored-By: Claude'
offending="$(command grep -nE "$pattern" -- "$msg_file" 2>/dev/null)"
[ -z "$offending" ] || exit 1
exit 0
OLD
chmod +x "$HOOK"
run_cli scripts/wave-init.sh --wave 1 --mode full --feature x
[ "$CLI_EXIT" = "0" ] || fail "old: exit $CLI_EXIT ($CLI_STDERR)"
current_template_ok old
command grep -qxF '# wave-orchestrator-owned commit-msg hook; template 1' "$HOOK" \
  && fail "old: the template 1 marker survived the upgrade"
assert_state '.commit_msg_hook == "upgraded"' || fail "old: want upgraded"
case "$CLI_STDERR" in
  *"upgraded $HOOK"*) : ;;
  *) fail "old: stderr must say the hook was upgraded: '$CLI_STDERR'" ;;
esac
[ "$(sha256sum "$HOOK" | awk '{print $1}')" = "$CURRENT_SUM" ] || fail "old: the upgrade is not the current template byte for byte"
refuses old 'Claude-Session: https://example.invalid/session'

# ---- the hook 0.2.0 / 0.2.1 actually installed --------------------------------
REL="$WV_REPO_ROOT/hooks/released/commit-msg-0.2.1.hook"
[ -s "$REL" ] || fail "released: data file $REL is missing"
fresh_project
cp "$REL" "$HOOK"
chmod +x "$HOOK"
# The released pattern lets a session line through; the upgrade must close that.
printf 'subject\n\n%s\n' 'Claude-Session: https://example.invalid/session' > "$WV_RUN_TMP/$name-rel-msg.txt"
bash "$HOOK" "$WV_RUN_TMP/$name-rel-msg.txt" >/dev/null 2>&1 \
  || fail "released: precondition: the released hook was expected to let the session line through"
run_cli scripts/wave-init.sh --wave 1 --mode full --feature x
[ "$CLI_EXIT" = "0" ] || fail "released: exit $CLI_EXIT ($CLI_STDERR)"
current_template_ok released
assert_state '.commit_msg_hook == "upgraded"' || fail "released: want upgraded, the unmodified released template is ours"
case "$CLI_STDERR" in
  *"upgraded $HOOK"*) : ;;
  *) fail "released: stderr must say the hook was upgraded: '$CLI_STDERR'" ;;
esac
[ "$(sha256sum "$HOOK" | awk '{print $1}')" = "$CURRENT_SUM" ] || fail "released: the upgrade is not the current template byte for byte"
refuses released 'Claude-Session: https://example.invalid/session'
run_cli scripts/wave-init.sh --wave 2 --mode full --feature y --force
[ "$CLI_EXIT" = "0" ] || fail "released-again: exit $CLI_EXIT ($CLI_STDERR)"
[ "$(sha256sum "$HOOK" | awk '{print $1}')" = "$CURRENT_SUM" ] || fail "released-again: the upgraded hook was rewritten differently"
assert_state '.commit_msg_hook == "installed"' || fail "released-again: want installed"

# ---- foreign hooks ------------------------------------------------------------
preserved_leg() {
  # preserved_leg <label> <file with the hook's exact bytes>
  local label="$1" src="$2" before
  fresh_project
  cp "$src" "$HOOK"
  chmod +x "$HOOK"
  before="$(sha256sum "$HOOK" | awk '{print $1}')"
  run_cli scripts/wave-init.sh --wave 1 --mode full --feature x
  [ "$CLI_EXIT" = "0" ] || fail "$label: exit $CLI_EXIT ($CLI_STDERR)"
  [ "$(sha256sum "$HOOK" | awk '{print $1}')" = "$before" ] || fail "$label: a hook without the owned marker was modified"
  assert_state '.commit_msg_hook == "skipped-existing"' || fail "$label: want skipped-existing"
  case "$CLI_STDERR" in
    *"left untouched"*) : ;;
    *) fail "$label: stderr must say the hook was left untouched: '$CLI_STDERR'" ;;
  esac
  case "$CLI_STDERR" in
    *"# Installed by wave-init.sh"*"remove it and the next scripts/wave-init.sh installs"*) : ;;
    *) fail "$label: the notice must give the refresh path for an earlier plugin hook: '$CLI_STDERR'" ;;
  esac
}
foreign_leg() {
  # foreign_leg <label> <body>
  local body_file="$WV_RUN_TMP/$name-$1-body"
  printf '%s' "$2" > "$body_file"
  preserved_leg "$1" "$body_file"
}
foreign_leg mention $'#!/bin/sh\n# wraps the wave-orchestrator-owned commit-msg hook of another repo\nexit 0\n'
foreign_leg unmarked-earlier $'#!/usr/bin/env bash\n# Installed by wave-init.sh. Refuses a commit message\nexit 0\n'

# The released template with any user modification is the user's hook.
MOD="$WV_RUN_TMP/$name-modified"
{ cat "$REL"; printf '# local addition\n'; } > "$MOD-appended"
preserved_leg modified-appended "$MOD-appended"
sed 's/(Claude|Anthropic)/(Claude|Anthropic|Example)/' "$REL" > "$MOD-pattern"
cmp -s "$REL" "$MOD-pattern" && fail "modified-pattern: precondition: the edit did not change the template"
preserved_leg modified-pattern "$MOD-pattern"
head -c -1 "$REL" > "$MOD-no-final-newline"
preserved_leg modified-no-final-newline "$MOD-no-final-newline"

exit $rc
