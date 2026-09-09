#!/usr/bin/env bash
# tests/lib/assert.sh — helpers shared by every tests/cases/*.sh case and by
# tests/run.sh itself. See tests/cases/README.md for the case-file schema
# these helpers implement.
#
# Deliberately POSIX-ish bash: `set -u`, never `set -e` (a single failed
# assertion must not abort the whole run, and a hook under test exiting
# non-zero is often the very thing being asserted).
set -u

WV_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WV_REPO_ROOT="$(cd "$WV_LIB_DIR/../.." && pwd)"
WV_TESTS_DIR="$WV_REPO_ROOT/tests"

# Root scratch dir for the whole `tests/run.sh` invocation. A `.sh` case
# invoked directly (outside run.sh) gets its own so it still works standalone.
if [ -z "${WV_RUN_TMP:-}" ]; then
  WV_RUN_TMP="$(mktemp -d "${TMPDIR:-/tmp}/wave-plugin-tests.XXXXXX")"
  export WV_RUN_TMP
fi
mkdir -p "$WV_RUN_TMP/logs"

# Set by run_hook; read by the assert_* functions below.
WV_PROJECT="${WV_PROJECT:-}"
WV_LAST_EXIT=""
WV_LAST_STDOUT=""
WV_LAST_STDERR=""
WV_ASSERT_DIFF=""

# ---- small internals -------------------------------------------------

_wv_die_diff() {
  # _wv_die_diff <message...>  — records + prints an assertion failure.
  WV_ASSERT_DIFF="$*"
  printf 'ASSERT FAIL: %s\n' "$WV_ASSERT_DIFF" >&2
  return 1
}

_wv_is_deny() {
  printf '%s' "$WV_LAST_STDOUT" | jq -e \
    '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1
}

_wv_is_block() {
  printf '%s' "$WV_LAST_STDOUT" | jq -e '.decision == "block"' >/dev/null 2>&1
}

_wv_is_warn() {
  printf '%s' "$WV_LAST_STDOUT" | jq -e \
    '.hookSpecificOutput.additionalContext != null and (.hookSpecificOutput.permissionDecision // null) == null' \
    >/dev/null 2>&1
}

_wv_reason_text() {
  # Prints whichever reason/additionalContext field is present, else "".
  printf '%s' "$WV_LAST_STDOUT" | jq -r \
    '.hookSpecificOutput.permissionDecisionReason // .reason // .hookSpecificOutput.additionalContext // empty' \
    2>/dev/null
}

_wv_classify_decision() {
  # Prints one of: silent allow deny block warn
  if _wv_is_deny; then echo deny; return; fi
  if _wv_is_block; then echo block; return; fi
  if _wv_is_warn; then echo warn; return; fi
  if [ "$WV_LAST_EXIT" = "0" ] && [ -z "$WV_LAST_STDOUT" ] && [ -z "${WV_LAST_STDERR:-}" ]; then
    echo silent; return
  fi
  echo allow
}

# ---- project + seeding -------------------------------------------------

mkproj() {
  # mkproj -> prints the path of a fresh temp git repo.
  local d
  d="$(mktemp -d "$WV_RUN_TMP/proj.XXXXXX")"
  git -C "$d" init -q
  git -C "$d" config user.email "wave-test@example.invalid"
  git -C "$d" config user.name "Wave Test Harness"
  printf '%s' "$d"
}

seed_state() {
  # seed_state <fixture> — copies a state fixture into $WV_PROJECT/.wave/state.json.
  # <fixture> may be a path relative to tests/fixtures/, or absolute/repo-relative.
  local fixture="$1" src
  if [ -f "$fixture" ]; then
    src="$fixture"
  elif [ -f "$WV_TESTS_DIR/fixtures/$fixture" ]; then
    src="$WV_TESTS_DIR/fixtures/$fixture"
  elif [ -f "$WV_TESTS_DIR/fixtures/state/$fixture" ]; then
    src="$WV_TESTS_DIR/fixtures/state/$fixture"
  else
    printf 'seed_state: fixture not found: %s\n' "$fixture" >&2
    return 1
  fi
  mkdir -p "$WV_PROJECT/.wave"
  cp "$src" "$WV_PROJECT/.wave/state.json"
  [ -f "$WV_PROJECT/.wave/lock" ] || : > "$WV_PROJECT/.wave/lock"
}

plant_control() {
  # plant_control <relative-path> — writes a recognisable, grep-able marker
  # file at <project>/<relative-path>, for cases that need to prove a
  # gating scan actually ran (a positive/negative control target).
  local rel="$1"
  mkdir -p "$WV_PROJECT/$(dirname "$rel")"
  printf 'WV-PLANTED-CONTROL: %s\n' "$rel" > "$WV_PROJECT/$rel"
}

_wv_apply_seed() {
  # _wv_apply_seed <case-json-path>
  local case_json="$1"
  local state_fixture
  state_fixture="$(jq -r '.seed.state // empty' "$case_json")"
  if [ -n "$state_fixture" ]; then
    seed_state "$state_fixture"
  fi
  local file_keys
  file_keys="$(jq -r '.seed.files // {} | keys[]' "$case_json" 2>/dev/null)"
  local k
  while IFS= read -r k; do
    [ -z "$k" ] && continue
    local content
    content="$(jq -r --arg k "$k" '.seed.files[$k]' "$case_json")"
    mkdir -p "$WV_PROJECT/$(dirname "$k")"
    printf '%s' "$content" > "$WV_PROJECT/$k"
  done <<<"$file_keys"
  # seed.transcripts: { "<project-relative destination>": "<fixture path>" }.
  # An agent transcript is a multi-line JSONL file whose exact bytes are the
  # thing under test, so it lives once under tests/fixtures/transcripts/ and is
  # COPIED here rather than restated inline in every case (two copies of a
  # fixture is two sources of truth). A named fixture that cannot be found is a
  # LOUD failure, never a silent skip: a case that ran against an absent
  # transcript would assert "no transcript" behaviour while claiming to test the
  # opposite.
  local tkeys
  tkeys="$(jq -r '.seed.transcripts // {} | keys[]' "$case_json" 2>/dev/null)"
  local dest src
  while IFS= read -r dest; do
    [ -z "$dest" ] && continue
    src="$(jq -r --arg k "$dest" '.seed.transcripts[$k]' "$case_json")"
    if [ -f "$WV_TESTS_DIR/fixtures/$src" ]; then
      src="$WV_TESTS_DIR/fixtures/$src"
    elif [ -f "$src" ]; then
      :
    else
      printf 'seed.transcripts: fixture not found: %s\n' "$src" >&2
      return 1
    fi
    mkdir -p "$WV_PROJECT/$(dirname "$dest")"
    cp "$src" "$WV_PROJECT/$dest" || return 1
  done <<<"$tkeys"

  local staged p
  staged="$(jq -r '.seed.staged // [] | .[]' "$case_json" 2>/dev/null)"
  while IFS= read -r p; do
    [ -z "$p" ] && continue
    git -C "$WV_PROJECT" add -- "$p" >/dev/null 2>&1
  done <<<"$staged"
  # Explicit, so that only the `return 1`s above (a fixture this function was
  # told to copy and could not find) report a seed failure to run_hook. A
  # `git add` that declines the last staged path keeps the pre-existing
  # behaviour it has always had.
  return 0
}

# ---- running a hook ------------------------------------------------------

run_hook() {
  # run_hook <script> <case-json-path>
  # Sets WV_LAST_EXIT / WV_LAST_STDOUT / WV_LAST_STDERR / WV_PROJECT.
  # Returns 1 (without running the script) if the script does not exist.
  local script="$1" case_json="${2:-}"
  local script_path
  case "$script" in
    */*) script_path="$WV_REPO_ROOT/$script" ;;
    *)   script_path="$WV_REPO_ROOT/scripts/hooks/$script" ;;
  esac

  local case_name
  case_name="$(basename "${case_json:-unknown}" | sed -E 's/\.(json|sh)$//')"
  local log="$WV_RUN_TMP/logs/$case_name.log"

  if [ ! -f "$script_path" ] || [ ! -r "$script_path" ]; then
    WV_LAST_EXIT=127
    WV_LAST_STDOUT=""
    WV_LAST_STDERR="script not found: $script"
    printf 'NOT-FOUND %s %s\n' "$script" "$case_name" >> "$log"
    return 1
  fi

  if [ -z "$WV_PROJECT" ]; then
    WV_PROJECT="$(mkproj)"
  fi

  if [ -n "$case_json" ] && [ -f "$case_json" ]; then
    # A seed that could not be applied must FAIL the case, never run the hook
    # against a half-seeded project: a missing transcript or state fixture would
    # otherwise be indistinguishable from the "absent file" behaviour many of
    # these cases are asserting the hook does NOT take.
    if ! _wv_apply_seed "$case_json"; then
      WV_LAST_EXIT=126
      WV_LAST_STDOUT=""
      WV_LAST_STDERR="seed could not be applied for $case_name (see stderr above)"
      printf 'SEED-FAILED %s %s\n' "$script" "$case_name" >> "$log"
      return 1
    fi
  fi

  local stdin_json="{}"
  if [ -n "$case_json" ] && [ -f "$case_json" ]; then
    stdin_json="$(jq -c '.stdin // {}' "$case_json")"
  fi

  local -a env_args=()
  if [ -n "$case_json" ] && [ -f "$case_json" ]; then
    local ekeys
    ekeys="$(jq -r '.env // {} | keys[]' "$case_json" 2>/dev/null)"
    while IFS= read -r ek; do
      [ -z "$ek" ] && continue
      local ev
      ev="$(jq -r --arg k "$ek" '.env[$k]' "$case_json")"
      env_args+=("$ek=$ev")
    done <<<"$ekeys"
  fi

  local stderr_tmp
  stderr_tmp="$(mktemp "$WV_RUN_TMP/stderr.XXXXXX")"
  WV_LAST_STDOUT="$(cd "$WV_PROJECT" && printf '%s' "$stdin_json" | env "${env_args[@]}" bash "$script_path" 2>"$stderr_tmp")"
  WV_LAST_EXIT=$?
  WV_LAST_STDERR="$(cat "$stderr_tmp")"
  rm -f "$stderr_tmp"

  local decision
  decision="$(_wv_classify_decision)"
  printf 'RAN %s %s decision=%s\n' "$script" "$case_name" "$decision" >> "$log"
  return 0
}

run_cli() {
  # run_cli <repo-relative-script> [args...]
  #
  # For a lifecycle script invoked with real argv (wave-init.sh, wave-set.sh,
  # wave-close.sh) rather than a hook reading stdin JSON — run_hook (above)
  # pipes stdin and never argv, so it does not fit these. Runs <script>
  # inside $WV_PROJECT with the given arguments, sets CLI_STDOUT / CLI_EXIT /
  # CLI_STDERR, and appends this case's `RAN …` run marker to its log — the
  # same marker run_hook writes, so tests/run.sh's per-case run-marker check
  # covers a `.sh` case built entirely on run_cli too.
  #
  # Ambient variables the caller must already have set (every tests/cases/
  # *.sh case sets these near the top, per tests/cases/README.md):
  #   name          this case's name (basename "$0" .sh)
  #   log           this case's log path (${WV_CASE_LOG:-$WV_RUN_TMP/logs/$name.log})
  #   WV_PROJECT    the temp project directory (mkproj)
  local script="$1"; shift
  local errf="$WV_RUN_TMP/$name.stderr"
  CLI_STDOUT="$(cd "$WV_PROJECT" && bash "$WV_REPO_ROOT/$script" "$@" 2>"$errf")"
  CLI_EXIT=$?
  CLI_STDERR="$(cat "$errf")"
  rm -f "$errf"
  printf 'RAN %s %s exit=%s\n' "$script" "$name" "$CLI_EXIT" >> "$log"
}

# ---- assertions -----------------------------------------------------------

assert_exit() {
  local want="$1"
  [ "$WV_LAST_EXIT" = "$want" ] && return 0
  _wv_die_diff "exit: want $want, got $WV_LAST_EXIT"
}

assert_silent() {
  if [ "$WV_LAST_EXIT" = "0" ] && [ -z "$WV_LAST_STDOUT" ] && [ -z "${WV_LAST_STDERR:-}" ]; then
    return 0
  fi
  _wv_die_diff "silent: want exit=0/empty stdout+stderr, got exit=$WV_LAST_EXIT stdout='$WV_LAST_STDOUT' stderr='$WV_LAST_STDERR'"
}

assert_allow() {
  if [ "$WV_LAST_EXIT" = "0" ] && ! _wv_is_deny && ! _wv_is_block; then
    return 0
  fi
  _wv_die_diff "allow: want exit=0 and no deny/block shape, got exit=$WV_LAST_EXIT stdout='$WV_LAST_STDOUT'"
}

assert_deny() {
  local rule="$1"
  if ! _wv_is_deny; then
    _wv_die_diff "deny: stdout is not a PreToolUse deny shape: '$WV_LAST_STDOUT'"
    return 1
  fi
  local reason
  reason="$(_wv_reason_text)"
  case "$reason" in
    "[$rule] "*) return 0 ;;
    *) _wv_die_diff "deny: reason does not start with [$rule] : '$reason'" ;;
  esac
}

assert_block() {
  local rule="$1"
  if ! _wv_is_block; then
    _wv_die_diff "block: stdout is not a SubagentStop block shape: '$WV_LAST_STDOUT'"
    return 1
  fi
  local reason
  reason="$(_wv_reason_text)"
  case "$reason" in
    "[$rule] "*) return 0 ;;
    *) _wv_die_diff "block: reason does not start with [$rule] : '$reason'" ;;
  esac
}

assert_warn() {
  local rule="$1"
  if ! _wv_is_warn; then
    _wv_die_diff "warn: stdout is not an additionalContext warn shape: '$WV_LAST_STDOUT'"
    return 1
  fi
  local reason
  reason="$(_wv_reason_text)"
  case "$reason" in
    "[$rule] "*) return 0 ;;
    *) _wv_die_diff "warn: additionalContext does not start with [$rule] : '$reason'" ;;
  esac
}

assert_single_rule_token() {
  local reason
  reason="$(_wv_reason_text)"
  local n
  n="$(printf '%s' "$reason" | command grep -oE 'W-[A-Z0-9-]+' | wc -l | tr -d ' ')"
  [ "$n" = "1" ] && return 0
  _wv_die_diff "single_rule_token: want exactly 1 W- token, found $n in '$reason'"
}

assert_reason_matches_template() {
  # Structural check only (starts with "[<rule>] ", non-empty remedy tail).
  # Byte-exact comparison against hooks/reasons.tsv is Task 13's job.
  local rule="$1"
  local reason
  reason="$(_wv_reason_text)"
  local prefix="[$rule] "
  case "$reason" in
    "$prefix"*)
      local tail="${reason#"$prefix"}"
      [ -n "$tail" ] && return 0
      _wv_die_diff "reason_matches_template: [$rule] prefix present but no remedy text follows"
      ;;
    *)
      _wv_die_diff "reason_matches_template: '$reason' does not start with '$prefix'"
      ;;
  esac
}

assert_reason_contains() {
  # assert_reason_contains <literal-substring> — the rendered reason (or the
  # warn channel's additionalContext) must contain <substring> byte for byte.
  # Matching is literal, never glob or regex: a rule reason quotes the
  # offending input, and that input routinely carries `*`, `[`, `$` and `\`.
  local needle="$1"
  local reason
  reason="$(_wv_reason_text)"
  case "$reason" in
    *"$needle"*) return 0 ;;
    *) _wv_die_diff "reason_contains: '$needle' is absent from '$reason'" ;;
  esac
}

assert_stderr_contains() {
  # assert_stderr_contains <literal-substring> — stderr must contain <substring>
  # byte for byte. Matching is literal, never glob or regex, for the same reason
  # assert_reason_contains is: the text quotes paths, regexes and agent ids.
  #
  # SubagentStop and PreCompact have no `additionalContext` channel, so a warning
  # on those events reaches the operator on stderr and NOWHERE else. Without this,
  # a case can only assert that such a warning did not break the decision — never
  # that it was actually emitted, which is the whole content of the claim.
  local needle="$1"
  case "${WV_LAST_STDERR:-}" in
    *"$needle"*) return 0 ;;
    *) _wv_die_diff "stderr_contains: '$needle' is absent from '${WV_LAST_STDERR:-}'" ;;
  esac
}

assert_stdout_absent() {
  # assert_stdout_absent <literal-substring> — the whole of stdout must NOT
  # contain <substring>. This is how a case proves a rule did *not* fire (no
  # `W-MODEL-UNKNOWN` token anywhere) and how an injection case proves the
  # hook never evaluated its input (no `uid=` from a substituted `id`).
  local needle="$1"
  case "$WV_LAST_STDOUT" in
    *"$needle"*) _wv_die_diff "stdout_absent: '$needle' is present in '$WV_LAST_STDOUT'" ;;
    *) return 0 ;;
  esac
}

assert_state() {
  local filter="$1"
  local state_file="$WV_PROJECT/.wave/state.json"
  if [ ! -f "$state_file" ]; then
    _wv_die_diff "state: $state_file does not exist"
    return 1
  fi
  if jq -e "$filter" "$state_file" >/dev/null 2>&1; then
    return 0
  fi
  _wv_die_diff "state: filter '$filter' failed against $(cat "$state_file")"
}

assert_ledger_lines() {
  local want="$1"
  local ledger="$WV_PROJECT/.wave/ledger.jsonl"
  local got=0
  [ -f "$ledger" ] && got="$(wc -l < "$ledger" | tr -d ' ')"
  [ "$got" = "$want" ] && return 0
  _wv_die_diff "ledger_lines: want $want, got $got"
}

assert_ledger_line() {
  # assert_ledger_line <jq boolean filter> — evaluated against the LAST line of
  # .wave/ledger.jsonl, which is the line the run under test appended. The line
  # must also parse: `jq -e` on a truncated or interleaved line fails, which is
  # exactly the append-integrity property the concurrency cases assert.
  local filter="$1"
  local ledger="$WV_PROJECT/.wave/ledger.jsonl"
  if [ ! -f "$ledger" ]; then
    _wv_die_diff "ledger_assert: $ledger does not exist"
    return 1
  fi
  local last
  last="$(tail -n 1 "$ledger")"
  if [ -z "$last" ]; then
    _wv_die_diff "ledger_assert: the last ledger line is empty"
    return 1
  fi
  if printf '%s' "$last" | jq -e "$filter" >/dev/null 2>&1; then
    return 0
  fi
  _wv_die_diff "ledger_assert: filter '$filter' failed against $last"
}

assert_ledger_prefix() {
  # assert_ledger_prefix <case-json-path> <n> — the first <n> lines of the
  # ledger must still be byte-identical to the first <n> lines the case seeded
  # into .wave/ledger.jsonl. This is what "append, never rewrite" means: a hook
  # that rewrote the file could still produce the right line COUNT.
  local case_json="$1" n="$2"
  local ledger="$WV_PROJECT/.wave/ledger.jsonl"
  if [ ! -f "$ledger" ]; then
    _wv_die_diff "ledger_prefix_unchanged: $ledger does not exist"
    return 1
  fi
  local seeded
  seeded="$(jq -r '.seed.files[".wave/ledger.jsonl"] // empty' "$case_json" 2>/dev/null)"
  if [ -z "$seeded" ]; then
    _wv_die_diff "ledger_prefix_unchanged: the case seeds no .wave/ledger.jsonl to compare against"
    return 1
  fi
  local want got
  want="$(printf '%s' "$seeded" | head -n "$n")"
  got="$(head -n "$n" "$ledger")"
  [ "$want" = "$got" ] && return 0
  _wv_die_diff "ledger_prefix_unchanged: the first $n lines changed; want '$want' got '$got'"
}
