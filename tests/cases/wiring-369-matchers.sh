#!/usr/bin/env bash
# tests/cases/wiring-369-matchers.sh — AC-369.
#
# Matchers are literally ^Agent$ (the dispatch hooks: pre-agent.sh,
# post-agent.sh), ^(Edit|Write|NotebookEdit|MultiEdit)$ (pre-edit.sh),
# ^Read$ (pre-read.sh), ^Bash$ twice (pre-bash.sh and pre-commit-guard.sh),
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
    pre-bash.sh|pre-commit-guard.sh)
      [ "$matcher" = "^Bash\$" ] || fail "$script ($event): want matcher ^Bash\$, got $matcher"
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

# The two ^Bash$ matchers must be pre-bash.sh AND pre-commit-guard.sh, not
# the same script twice.
bash_scripts="$(printf '%s\n' "$pairs" | awk -F'\t' '$2=="^Bash$"{print $3}')"
n_bash="$(printf '%s\n' "$bash_scripts" | grep -c . || true)"
[ "$n_bash" -eq 2 ] || fail "want exactly 2 ^Bash\$ entries, found $n_bash"
printf '%s\n' "$bash_scripts" | command grep -q 'pre-bash.sh' \
  || fail "no ^Bash\$ entry resolves to pre-bash.sh"
printf '%s\n' "$bash_scripts" | command grep -q 'pre-commit-guard.sh' \
  || fail "no ^Bash\$ entry resolves to pre-commit-guard.sh"

[ "$n" -eq 11 ] || fail "want 11 hook entries, found $n"

printf 'RAN wiring-369 entries=%s\n' "$n" >> "$log"
exit $rc
