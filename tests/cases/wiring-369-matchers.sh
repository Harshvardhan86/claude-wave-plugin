#!/usr/bin/env bash
# tests/cases/wiring-369-matchers.sh — AC-369.
#
# Matchers are literally ^Agent$ (the dispatch hooks: pre-agent.sh,
# post-agent.sh), ^(Edit|Write|NotebookEdit|MultiEdit)$ (pre-edit.sh),
# ^Read$ (pre-read.sh), ^Bash$ three times (pre-bash.sh, pre-commit-guard.sh,
# post-bash.sh), ^Monitor$ (pre-monitor.sh),
# startup|resume|clear|compact on SessionStart, and absent on Stop,
# PreCompact, SubagentStop and UserPromptSubmit.
set -u

# shellcheck source=tests/lib/assert.sh
source "$(dirname "$0")/../lib/assert.sh"

name="$(basename "$0" .sh)"
log="${WV_CASE_LOG:-$WV_RUN_TMP/logs/$name.log}"
mkdir -p "$(dirname "$log")"

rc=0
fail() { printf 'ASSERT FAIL: %s\n' "$*" >&2; rc=1; }

hooks_json="$WV_REPO_ROOT/hooks/hooks.json"
if [ ! -f "$hooks_json" ]; then
  fail "$hooks_json does not exist"
  printf 'RAN wiring-369 hooks.json=absent\n' >> "$log"
  exit 1
fi

CLAUDE_PLUGIN_ROOT="$WV_REPO_ROOT"

# script-basename -> matcher, one line per hooks.json entry.
pairs="$(jq -r '
  .hooks | to_entries[] as $e
  | $e.value[] as $group
  | $group.hooks[] as $h
  | [$e.key, ($group.matcher // "<absent>"), $h.command] | @tsv
' "$hooks_json" 2>/dev/null)"

n=0
while IFS=$'\t' read -r event matcher cmd; do
  [ -z "$event" ] && continue
  n=$((n + 1))
  resolved="$(eval "printf '%s' $cmd" 2>/dev/null)"
  script="$(basename "$resolved" 2>/dev/null)"
  case "$script" in
    pre-agent.sh|post-agent.sh)
      [ "$matcher" = "^Agent\$" ] || fail "$script ($event): want matcher ^Agent\$, got $matcher"
      ;;
    pre-edit.sh)
      [ "$matcher" = "^(Edit|Write|NotebookEdit|MultiEdit)\$" ] \
        || fail "$script ($event): want matcher ^(Edit|Write|NotebookEdit|MultiEdit)\$, got $matcher"
      ;;
    pre-read.sh)
      [ "$matcher" = "^Read\$" ] || fail "$script ($event): want matcher ^Read\$, got $matcher"
      ;;
    pre-bash.sh|pre-commit-guard.sh|post-bash.sh)
      [ "$matcher" = "^Bash\$" ] || fail "$script ($event): want matcher ^Bash\$, got $matcher"
      if [ "$script" = "post-bash.sh" ]; then
        [ "$event" = "PostToolUse" ] || fail "$script: want PostToolUse, got $event"
      else
        [ "$event" = "PreToolUse" ] || fail "$script: want PreToolUse, got $event"
      fi
      ;;
    pre-monitor.sh)
      [ "$matcher" = "^Monitor\$" ] || fail "$script: want matcher ^Monitor\$, got $matcher"
      [ "$event" = "PreToolUse" ] || fail "$script: want PreToolUse, got $event"
      ;;
    session-start.sh)
      [ "$matcher" = "startup|resume|clear|compact" ] \
        || fail "$script ($event): want matcher startup|resume|clear|compact, got $matcher"
      ;;
    subagent-stop.sh|pre-compact.sh|stop.sh|user-prompt.sh)
      [ "$matcher" = "<absent>" ] || fail "$script ($event): want no matcher, got $matcher"
      ;;
    *)
      fail "unrecognised hook script in the matcher sweep: $script (from $cmd)"
      ;;
  esac
done <<<"$pairs"

# The three ^Bash$ matchers must name distinct scripts, including post-bash.sh.
bash_scripts="$(printf '%s\n' "$pairs" | awk -F'\t' '$2=="^Bash$"{print $3}')"
# `command grep`, never a bare grep: a wrapped searcher can decline its input and
# print nothing where real grep prints 0, and `|| true` would then turn that
# failed scan into a clean count of "". An absent count fails the case.
n_bash="$(printf '%s\n' "$bash_scripts" | command grep -c .)"
case "$n_bash" in ''|*[!0-9]*) fail "the ^Bash\$ matcher scan returned no count, so it did not run"; n_bash=-1 ;; esac
[ "$n_bash" -eq 3 ] || fail "want exactly 3 ^Bash\$ entries, found $n_bash"
printf '%s\n' "$bash_scripts" | command grep -q 'pre-bash.sh' \
  || fail "no ^Bash\$ entry resolves to pre-bash.sh"
printf '%s\n' "$bash_scripts" | command grep -q 'pre-commit-guard.sh' \
  || fail "no ^Bash\$ entry resolves to pre-commit-guard.sh"

printf '%s\n' "$bash_scripts" | command grep -q 'post-bash.sh' \
  || fail "no ^Bash\$ entry resolves to post-bash.sh"
jq -e '[.hooks.PreToolUse[] | select(.matcher == "^Monitor$")] | length == 1' "$hooks_json" >/dev/null \
  || fail "want exactly one PreToolUse Monitor entry"

[ "$n" -eq 13 ] || fail "want 13 hook entries, found $n"

printf 'RAN wiring-369 entries=%s\n' "$n" >> "$log"
exit $rc
