#!/usr/bin/env bash
# scripts/hooks/pre-bash.sh — the PreToolUse hook on `Bash`.
#
# Spec section 8.3: a main-session `Bash` whose `tool_input.command` matches
# a test/build runner is denied (W-BASH). Commands without a runner or
# an unbounded wait (W-POLL) — including
# one that only MENTIONS a runner name inside a quoted string or as a
# substring of a longer word — is a silent no-op, so ordinary inspection
# (git status/log/diff, ls, wc, reading .wave/) produces no noise at all.
#
# The regex (transcribed from spec section 8.3, `\s` -> `[[:space:]]` for
# POSIX ERE and GNU grep's `\b` word-boundary extension, which `grep -E`
# also honours) requires a runner name to start right at the beginning of
# the command or right after one of the shell's own compound-command
# separators (`;`, `&`, `|`) — with any amount of leading whitespace, any
# number of env-var assignments (`CI=1 npm test`), and any of the wrapper
# commands `sudo`/`time`/`nice`/`env` (each optionally carrying its own
# dash-flags, e.g. `sudo -E`) allowed in between — optionally through
# `npx`, and ending at a word boundary. Measured on 2026-09-10: the original anchor admitted none of that, so `sudo make`,
# `CI=1 npm test` and ` make` (leading whitespace) were all silently
# allowed; widened per the ruling to close that gap while keeping the
# lexical bound intact — a wrapper/env token must itself look like one
# (`sudo`/`time`/`nice`/`env`, or `NAME=value`), so it does not bridge
# across an unrelated command. A wrapper's flag is only skipped when it
# starts with `-` (`sudo -E`, `nice -n` — but not the `5` that follows
# `-n`, a declared bound, not a fix-round-1 requirement).
#
# Because the widened anchor still admits no arbitrary non-flag,
# non-assignment character before the runner name, a name that only
# appears inside a quoted string (`echo "npm test"`, `command grep -n
# "npm test" README.md`) or as a substring of a longer identifier
# (`tscheck`, `maker --help`) never matches, and `echo sudo make` (the
# runner-shaped text following an unrelated command, not a wrapper) stays
# silent too. This is a DECLARED BOUND, not shell-quote parsing: the
# controller ruling reaffirms it explicitly — "do not try to be
# shell-quote-aware for W-BASH; W-POLL separately inspects shell code.
# The W-BASH lexical bound stands for `bash -c
# "…"`, variables and aliases." §13 of the design doc separately records
# that a `Bash` WRITE (`sed -i src/x.ts`) is out of scope for this hook —
# only the four edit tools of pre-edit.sh cover that.
#
# Solo mode is silent. Calls inside subagents skip only the runner gate;
# W-POLL checks wait bounds in both main and subagent sessions.

set -u

WV_HOOK_DIR="$(cd "${BASH_SOURCE[0]%/*}" 2>/dev/null && pwd)"
# shellcheck source=scripts/hooks/lib.sh
source "$WV_HOOK_DIR/lib.sh"

WV_BASH_RUNNER_RE='(^|[;&|])[[:space:]]*((sudo|time|nice|env)([[:space:]]+-[^[:space:]]+)*[[:space:]]+|[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*(npx[[:space:]]+)?(jest|vitest|mocha|playwright|pytest|py\.test|go test|cargo (test|build)|dotnet (test|build)|make|tsc|ng (build|test)|vite build|npm (test|run (build|test|e2e))|pnpm (test|build)|yarn (test|build))\b'

# D-14: while true / while : with a token delimiter, not a trailing word-end
# after `:` (that would miss `while :;`).
WV_POLL_LOOP_RE='(^|[^[:alnum:]_])while[[:space:]]+(true|:)([[:space:];&|]|$)'

# D-11: the wrapper starts at position zero, allowing leading whitespace.
# A trailing timeout never exempts an earlier loop; units s/m/h/d are bounded.
WV_POLL_TIMEOUT_RE='^[[:space:]]*timeout([[:space:]]+-[^[:space:]]+)*[[:space:]]+[1-9][0-9]*[smhd]?([^[:alnum:]_]|$)'

# D-12: literal duration after a sleep token. $VAR is not a literal.
WV_POLL_SLEEP_RE='(^|[^[:alnum:]_])sleep[[:space:]]+(infinity|inf|[0-9]+(\.[0-9]+)?[[:alpha:]]*)([^[:alnum:]_]|$)'

# until … do … sleep  — until denies only when the body also sleeps (D-14).
# `do` is preceded by a separator so the `do` inside `done` cannot match;
# sleep may sit immediately after `do ` (the separator is already consumed).
WV_POLL_UNTIL_RE='(^|[^[:alnum:]_])until[[:space:]].*[[:space:];]do[[:space:];].*sleep'

# True when $1 ends with a shell interpreter plus a -c flag (and space).
wv_poll__shell_c_prefix() {
  local s="${1-}"
  [[ $s =~ (^|[^[:alnum:]_])(bash|sh|dash|ksh|zsh)[[:space:]]+(-[a-zA-Z]*c[a-zA-Z]*[[:space:]]+)+$ ]]
}

# wv_poll_strip_quotes <cmd>
# Remove double- and single-quoted spans (D-13). Escaped quotes inside
# double quotes are not terminators. A quoted span that is the argument
# to bash/sh/dash/ksh/zsh -c is inspected recursively through depth 3.
# Other quoted spans, and shell arguments deeper than that bound, are stripped.
wv_poll_strip_quotes() {
  local cmd="${1-}" depth="${2:-0}"
  local i=0 n=${#cmd} out="" c q keep inner
  while [ "$i" -lt "$n" ]; do
    c="${cmd:i:1}"
    if [ "$c" = "'" ] || [ "$c" = '"' ]; then
      keep=0
      if [ "$depth" -lt 3 ] && wv_poll__shell_c_prefix "$out"; then
        keep=1
      fi
      q="$c"
      i=$((i + 1))
      inner=""
      while [ "$i" -lt "$n" ]; do
        c="${cmd:i:1}"
        if [ "$q" = '"' ] && [ "$c" = '\' ]; then
          i=$((i + 1))
          if [ "$i" -lt "$n" ]; then
            inner+="${cmd:i:1}"
            i=$((i + 1))
          fi
          continue
        fi
        if [ "$c" = "$q" ]; then
          i=$((i + 1))
          break
        fi
        inner+="$c"
        i=$((i + 1))
      done
      if [ "$keep" -eq 1 ]; then
        out+="$(wv_poll_strip_quotes "$inner" "$((depth + 1))")"
      fi
      continue
    fi
    if [ "$c" = '\' ]; then
      out+="$c"
      i=$((i + 1))
      if [ "$i" -lt "$n" ]; then
        out+="${cmd:i:1}"
        i=$((i + 1))
      fi
      continue
    fi
    out+="$c"
    i=$((i + 1))
  done
  printf '%s' "$out"
}

# wv_poll_timeout_wraps <cmd>
# Exit 0 iff an anchored prefix timeout wrapper with a positive integer
# duration is present (D-11). timeout 0 and timeout $N are not wrappers.
wv_poll_timeout_wraps() {
  local cmd="${1-}"
  [[ $cmd =~ $WV_POLL_TIMEOUT_RE ]]
}

# Convert one sleep duration token to integer seconds.
# inf/infinity and any suffix other than s/m/h → 999999 (D-12).
wv_poll__sleep_token_seconds() {
  local dur="${1-}" n suf
  case "$dur" in
    inf|infinity|INF|INFINITY|Inf|Infinity)
      printf '%s' '999999'
      return 0
      ;;
  esac
  if [[ $dur =~ ^([0-9]+)(\.[0-9]+)?([A-Za-z]*)$ ]]; then
    n="${BASH_REMATCH[1]}"
    suf="${BASH_REMATCH[3]}"
    case "$suf" in
      ''|s|S)
        printf '%s' "$n"
        return 0
        ;;
      m|M)
        printf '%s' "$((n * 60))"
        return 0
        ;;
      h|H)
        printf '%s' "$((n * 3600))"
        return 0
        ;;
      *)
        printf '%s' '999999'
        return 0
        ;;
    esac
  fi
  printf ''
}

# wv_poll_sleep_seconds <cmd>
# Print the largest sleep duration in seconds after D-12 conversion, or
# empty. sleep $VAR is ignored. inf/infinity (and unknown suffixes) → 999999.
wv_poll_sleep_seconds() {
  local cmd="${1-}" stripped rest matched dur sec max=""
  stripped="$(wv_poll_strip_quotes "$cmd")"
  rest="$stripped"
  while [[ $rest =~ $WV_POLL_SLEEP_RE ]]; do
    matched="${BASH_REMATCH[0]}"
    dur="${BASH_REMATCH[2]}"
    sec="$(wv_poll__sleep_token_seconds "$dur")"
    if [ -n "$sec" ]; then
      if [ -z "$max" ] || [ "$sec" -gt "$max" ]; then
        max="$sec"
      fi
    fi
    if [ -z "$matched" ]; then
      break
    fi
    rest="${rest#*"$matched"}"
  done
  printf '%s' "$max"
}

wv_poll__has_loop() {
  local s="${1-}"
  [[ $s =~ $WV_POLL_LOOP_RE ]] && return 0
  [[ $s =~ $WV_POLL_UNTIL_RE ]] && return 0
  return 1
}

# wv_poll_check <cmd>
# Print one of: "" (allow), "loop", "sleep:<n>", "sleep:inf".
# Non-zero when clean (allow). Timeout exemption returns from this
# checker only (D-15) — the caller still runs W-BASH.
wv_poll_check() {
  local cmd="${1-}" stripped secs
  if wv_poll_timeout_wraps "$cmd"; then
    printf ''
    return 1
  fi
  stripped="$(wv_poll_strip_quotes "$cmd")"
  if wv_poll__has_loop "$stripped"; then
    printf '%s' 'loop'
    return 0
  fi
  secs="$(wv_poll_sleep_seconds "$cmd")"
  if [ -z "$secs" ]; then
    printf ''
    return 1
  fi
  if [ "$secs" -eq 999999 ]; then
    printf '%s' 'sleep:inf'
    return 0
  fi
  if [ "$secs" -gt 300 ]; then
    printf '%s' "sleep:${secs}"
    return 0
  fi
  printf ''
  return 1
}

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

  # Wait bounds apply to every agent before the main-session runner gate.
  if wv_poll_check "$cmd" >/dev/null; then
    wv_rule_deny W-POLL "$(wv_list_cap 1 120 ' ' "$cmd")"
    return 0
  fi
  # Subagents run the suite; only the main session is gated below.
  [ -z "$WV_AGENT_ID" ] || return 0

  # A bounded wait is exempt only from W-POLL. Inspect its wrapped runner.
  if wv_poll_timeout_wraps "$cmd"; then
    cmd="${cmd:${#BASH_REMATCH[0]}}"
  fi
  command grep -qE -- "$WV_BASH_RUNNER_RE" <<<"$cmd" 2>/dev/null || return 0

  wv_rule_deny W-BASH "$(wv_bash_matched_runner "$cmd")"
  return 0
}

wv_main
wv_emit_flush
exit 0
