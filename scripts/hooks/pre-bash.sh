#!/usr/bin/env bash
# scripts/hooks/pre-bash.sh — the PreToolUse hook on `Bash`.
#
# Spec section 8.3: a main-session `Bash` whose `tool_input.command` matches
# a test/build runner is denied (W-BASH). Every other command — including
# one that only MENTIONS a runner name inside a quoted string or as a
# substring of a longer word — is a silent no-op, so ordinary inspection
# (git status/log/diff, ls, wc, reading .wave/) produces no noise at all.
#
# The regex (transcribed from spec section 8.3, `\s` -> `[[:space:]]` for
# POSIX ERE and GNU grep's `\b` word-boundary extension, which `grep -E`
# also honours) requires a runner name to start right at the beginning of
# the command or right after one of the shell's own compound-command
# separators (`;`, `&`, `|`), optionally through `npx`, and end at a word
# boundary. Because the anchor alternation admits no arbitrary character
# before the runner name, a name that only appears inside a quoted string
# (`echo "npm test"`, `command grep -n "npm test" README.md`) or as a
# substring of a longer identifier (`tscheck`, `maker --help`) never
# matches. This is a DECLARED BOUND, not shell-quote parsing: the
# Interfaces line for this task is explicit that "a false deny here is the
# risk — prefer allow for quoted occurrences", so the regex is deliberately
# lexical rather than shell-aware. §13 of the design doc separately records
# that a `Bash` WRITE (`sed -i src/x.ts`) is out of scope for this hook —
# only the four edit tools of pre-edit.sh cover that.
#
# Solo mode and any call made INSIDE a subagent (stdin carries `agent_id`)
# are both silent no-ops, same as pre-edit.sh / pre-read.sh.

set -u

WV_HOOK_DIR="$(cd "${BASH_SOURCE[0]%/*}" 2>/dev/null && pwd)"
# shellcheck source=scripts/hooks/lib.sh
source "$WV_HOOK_DIR/lib.sh"

WV_BASH_RUNNER_RE='(^|[;&|][[:space:]]*)(npx[[:space:]]+)?(jest|vitest|mocha|playwright|pytest|py\.test|go test|cargo (test|build)|dotnet (test|build)|make|tsc|ng (build|test)|vite build|npm (test|run (build|test|e2e))|pnpm (test|build)|yarn (test|build))\b'

wv_bash_matched_runner() {
  # wv_bash_matched_runner <command> -> the first matched runner phrase, on
  # stdout, with its leading compound-separator character and whitespace
  # trimmed for a readable reason ("; pytest" -> "pytest",
  # "| npx vitest" -> "npx vitest"). The caller has already proven a match
  # exists with `command grep -qE`; this only re-extracts it for the reason.
  local cmd="$1" m
  m="$(command grep -oE -- "$WV_BASH_RUNNER_RE" <<<"$cmd" 2>/dev/null | head -n1)"
  case "$m" in
    [\;\&\|]*) m="${m:1}" ;;
  esac
  m="${m#"${m%%[![:space:]]*}"}"
  printf '%s' "$m"
}

wv_main() {
  wv_parse_stdin || return 0
  [ "$WV_EVENT" = "PreToolUse" ] || return 0
  [ "$WV_TOOL" = "Bash" ] || return 0

  # Subagents run the suite; only the main session is gated.
  [ -z "$WV_AGENT_ID" ] || return 0

  wv_project_root || return 0
  wv_state_read || return 0
  # Solo mode does not consult phases.tsv at all, and §8.3 is one of the
  # rules it keeps switched off entirely (spec section 6).
  case "$WV_MODE" in
    full|demo) : ;;
    *) return 0 ;;
  esac

  local cmd
  cmd="$(wv_json '.tool_input.command // empty')"
  [ -n "$cmd" ] || return 0

  command grep -qE -- "$WV_BASH_RUNNER_RE" <<<"$cmd" 2>/dev/null || return 0

  wv_rule_deny W-BASH "$(wv_bash_matched_runner "$cmd")"
  return 0
}

wv_main
wv_emit_flush
exit 0
