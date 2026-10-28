#!/usr/bin/env bash
# tests/cases/commitmsg-released-data-pin.sh — the commit-msg hook 0.2.0 and
# 0.2.1 installed lives in ONE inert data file shipped with the plugin,
# hooks/released/commit-msg-0.2.1.hook, and nowhere in scripts/wave-init.sh.
#
#   pin      the data file is byte-equal to the template the 0.2.1
#            wave-init.sh wrote: the heredoc body of `git show
#            cdc229f:scripts/wave-init.sh`, extracted as text (the old script
#            is never executed). It is not executable. Its sha256 is pinned
#            too (taken from that extraction), so a copied tree without the
#            release history (the mutation drivers' copies) still certifies
#            the bytes; with the history present both checks run.
#   reader   wave-init.sh reads that file for its byte comparison and holds no
#            heredoc copy of the released template.
#   missing  a plugin tree without the data file never treats a hook as owned:
#            the released hook is left byte-identical, the state records
#            "skipped-existing", and stderr says the data file is missing.
set -u

# shellcheck source=tests/lib/assert.sh
source "$(dirname "$0")/../lib/assert.sh"

name="$(basename "$0" .sh)"
log="${WV_CASE_LOG:-$WV_RUN_TMP/logs/$name.log}"
mkdir -p "$(dirname "$log")"
rc=0
fail() { printf 'ASSERT FAIL: %s\n' "$*" >&2; rc=1; }

DATA_REL="hooks/released/commit-msg-0.2.1.hook"
DATA="$WV_REPO_ROOT/$DATA_REL"
INIT="$WV_REPO_ROOT/scripts/wave-init.sh"
RELEASE_COMMIT=cdc229f
RELEASE_SHA256=ebbfb086ac83eed5197d3fa70b947129efc6dc2bd02e347bd87107f059bd9e7f
printf 'RAN %s %s exit=0\n' "$DATA_REL" "$name" >> "$log"

# ---- pin ----------------------------------------------------------------------
[ -s "$DATA" ] || fail "pin: the data file $DATA_REL is missing or empty"
[ -x "$DATA" ] && fail "pin: the data file $DATA_REL must not be executable"
[ "$(sha256sum < "$DATA" 2>/dev/null | cut -d' ' -f1)" = "$RELEASE_SHA256" ] \
  || fail "pin: $DATA_REL does not hash to the released template's sha256"
if ! git -C "$WV_REPO_ROOT" cat-file -e "$RELEASE_COMMIT^{commit}" 2>/dev/null; then
  printf 'NOTE %s: release commit %s not in this tree; sha256 pin only\n' "$name" "$RELEASE_COMMIT" >> "$log"
else
  released="$WV_RUN_TMP/$name-released.hook"
  git -C "$WV_REPO_ROOT" show "$RELEASE_COMMIT:scripts/wave-init.sh" \
    | awk "/<<'WV_COMMIT_MSG_HOOK'\$/{f=1;next} /^WV_COMMIT_MSG_HOOK\$/{f=0} f" > "$released"
  [ -s "$released" ] || fail "pin: no commit-msg heredoc found in $RELEASE_COMMIT:scripts/wave-init.sh"
  [ -s "$released" ] && [ -s "$DATA" ] && ! cmp -s "$released" "$DATA" \
    && fail "pin: $DATA_REL differs from the template $RELEASE_COMMIT installed"
fi

# ---- reader -------------------------------------------------------------------
command grep -qF "$DATA_REL" "$INIT" || fail "reader: wave-init.sh does not read $DATA_REL"
command grep -qF 'WV_COMMIT_MSG_HOOK_RELEASED' "$INIT" \
  && fail "reader: wave-init.sh still holds a heredoc copy of the released template"
command grep -qF "pattern='Co-Authored-By:" "$INIT" \
  && fail "reader: wave-init.sh still holds the released template's pattern line"

# ---- missing: fail safe -------------------------------------------------------
plugin="$WV_RUN_TMP/$name-plugin"
mkdir -p "$plugin"
cp -R "$WV_REPO_ROOT/scripts" "$WV_REPO_ROOT/hooks" "$plugin/"
[ -d "$WV_REPO_ROOT/.claude-plugin" ] && cp -R "$WV_REPO_ROOT/.claude-plugin" "$plugin/"
rm -f "$plugin/$DATA_REL"
[ -e "$plugin/$DATA_REL" ] && fail "missing: precondition: the copy still has the data file"
WV_PROJECT="$(mkproj)"
: > "$WV_PROJECT/README.md"
git -C "$WV_PROJECT" add README.md
git -C "$WV_PROJECT" commit -q -m init
HOOK="$WV_PROJECT/.git/hooks/commit-msg"
mkdir -p "$(dirname "$HOOK")"
cp "$DATA" "$HOOK" 2>/dev/null
chmod +x "$HOOK"
before="$(sha256sum "$HOOK" | awk '{print $1}')"
errf="$WV_RUN_TMP/$name.stderr"
( cd "$WV_PROJECT" && CLAUDE_PROJECT_DIR="$WV_PROJECT" bash "$plugin/scripts/wave-init.sh" --wave 1 --mode full --feature x >/dev/null 2>"$errf" )
mexit=$?
merr="$(cat "$errf")"
printf 'RAN scripts/wave-init.sh %s exit=%s\n' "$name" "$mexit" >> "$log"
[ "$mexit" = "0" ] || fail "missing: exit $mexit ($merr)"
[ "$(sha256sum "$HOOK" | awk '{print $1}')" = "$before" ] || fail "missing: the hook was modified without the data file"
jq -e '.commit_msg_hook == "skipped-existing"' "$WV_PROJECT/.wave/state.json" >/dev/null 2>&1 \
  || fail "missing: want skipped-existing, got $(jq -c '.commit_msg_hook' "$WV_PROJECT/.wave/state.json" 2>/dev/null)"
case "$merr" in
  *"$DATA_REL"*"missing"*|*"missing"*"$DATA_REL"*) : ;;
  *) fail "missing: stderr must say the data file is missing: '$merr'" ;;
esac

exit $rc
