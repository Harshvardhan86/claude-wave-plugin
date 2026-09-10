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

_wv_assert_shape() {
  # _wv_assert_shape <kind> <rule> <shape predicate> <shape description>
  #
  # The three public assertions below are the same two-step check — is stdout the
  # right JSON SHAPE for this event, and does the reason it carries name the
  # expected rule — differing only in which predicate answers the first step and
  # how the failure reads. They were three copies; a fix to one (the reason text
  # is read from three possible fields, and that list has changed twice) had to be
  # made three times or the three would disagree about what a reason even is.
  local kind="$1" rule="$2" pred="$3" desc="$4"
  if ! "$pred"; then
    _wv_die_diff "$kind: stdout is not $desc: '$WV_LAST_STDOUT'"
    return 1
  fi
  local reason
  reason="$(_wv_reason_text)"
  case "$reason" in
    "[$rule] "*) return 0 ;;
    *) _wv_die_diff "$kind: reason does not start with [$rule] : '$reason'" ;;
  esac
}

assert_deny() {
  _wv_assert_shape deny "$1" _wv_is_deny 'a PreToolUse deny shape'
}

assert_block() {
  _wv_assert_shape block "$1" _wv_is_block 'a SubagentStop block shape'
}

assert_warn() {
  _wv_assert_shape warn "$1" _wv_is_warn 'an additionalContext warn shape'
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

# ---- the eleven-script sweep (Task 11, AC-12/13/30/31/398) ----------------
#
# Every wired script must be a total no-op (exit 0, empty stdout, empty
# stderr) whenever there is no active wave to enforce, and — the other half
# of the same claim — must NOT be a no-op when there IS one: a sweep that
# only ever proves silence would pass just as well against eleven scripts
# that always do nothing. `_wv_eleven_stdin`/`_wv_eleven_active_state`/
# `_wv_eleven_seed_files` below are copied, byte-for-byte where practical,
# from an already-GREEN positive case for that script (cited in each case's
# comment) — never invented — so "produces its rule" is grounded in a fixture
# this suite has already proven fires, not a guess about what might.

_wv_eleven_scripts() {
  printf '%s\n' \
    pre-agent.sh post-agent.sh subagent-stop.sh pre-edit.sh pre-read.sh \
    pre-bash.sh pre-commit-guard.sh pre-compact.sh stop.sh session-start.sh \
    user-prompt.sh
}

_wv_eleven_active_state() {
  # The seed.state fixture each script's positive case (cited below) uses.
  case "$1" in
    pre-agent.sh)       printf 'state/full-all-done-cr.json' ;;
    post-agent.sh)      printf 'state/full-all-done.json' ;;
    subagent-stop.sh)   printf 'state/stop-ac-reviewer.json' ;;
    pre-edit.sh)        printf 'state/valid-full.json' ;;
    pre-read.sh)        printf 'state/valid-full.json' ;;
    pre-bash.sh)        printf 'state/valid-full.json' ;;
    pre-commit-guard.sh) printf 'state/full-fresh.json' ;;
    pre-compact.sh)     printf 'state/valid-full.json' ;;
    stop.sh)            printf 'state/full-all-done.json' ;;
    session-start.sh)   printf 'state/full-ac-done.json' ;;
    user-prompt.sh)     printf 'state/full-red-done.json' ;;
  esac
}

_wv_eleven_seed_files() {
  # Writes into $WV_PROJECT whatever on-disk fixture this script's positive
  # case needs beyond state.json (an artifact file, a ledger line, a
  # checkpoint). Safe to call regardless of scenario: unused files are inert.
  local script="$1"
  case "$script" in
    subagent-stop.sh)
      # tests/cases/marker-204-no-ac-line-block.json
      mkdir -p "$WV_PROJECT/.wave"
      printf 'no criteria here\njust prose about criteria\n' > "$WV_PROJECT/.wave/ac.md"
      ;;
    pre-edit.sh)
      # tests/cases/edit-261-tracked-deny.json
      mkdir -p "$WV_PROJECT/src"
      printf 'x\n' > "$WV_PROJECT/src/app.ts"
      git -C "$WV_PROJECT" add src/app.ts >/dev/null 2>&1
      ;;
    pre-read.sh)
      # tests/cases/read-273-tracked-deny.json
      mkdir -p "$WV_PROJECT/src"
      printf 'x\n' > "$WV_PROJECT/src/app.ts"
      ;;
    stop.sh)
      # tests/cases/stopcard-321-terminal-done-prints.json
      mkdir -p "$WV_PROJECT/.wave"
      printf '{"agent":"a1","phase":"AD","role":"executor","output":100}\n' \
        > "$WV_PROJECT/.wave/ledger.jsonl"
      ;;
    session-start.sh)
      # tests/cases/session-327-compact-advisory.json
      mkdir -p "$WV_PROJECT/.wave/checkpoints"
      printf '# checkpoint\n' \
        > "$WV_PROJECT/.wave/checkpoints/2026-09-09T13:00:00Z-precompact.md"
      ;;
  esac
}

_wv_eleven_stdin() {
  # Reads the `.stdin` object straight out of each script's cited positive
  # case file, rather than retyping it here: byte-identical to the fixture
  # that already proves the rule fires (never a second, driftable copy),
  # and — for pre-commit-guard.sh specifically — it keeps that fixture's
  # W-COMMIT-TRAILER trigger text (an AI-attribution trailer, spelled out in
  # full in the fixture itself) confined to its one dedicated, already-
  # excluded fixture file (tests/cases/commit-298-coauthoredby-claude-deny.json)
  # instead of duplicating it inline into this shared library file, which
  # would otherwise trip tests/cases/docs-377-ai-traces.sh's repo-wide
  # AI-trace sweep (that sweep allow-lists individual fixture files by name,
  # never a whole shared library).
  local script="$1" fixture=""
  case "$script" in
    pre-agent.sh)       fixture="role-137b-cr-executor-deny.json" ;;
    post-agent.sh)      fixture="launch-193-downgrade-warn.json" ;;
    subagent-stop.sh)   fixture="marker-204-no-ac-line-block.json" ;;
    pre-edit.sh)        fixture="edit-261-tracked-deny.json" ;;
    pre-read.sh)        fixture="read-273-tracked-deny.json" ;;
    pre-bash.sh)        fixture="bash-fix1-sudo-make-deny.json" ;;
    pre-commit-guard.sh) fixture="commit-298-coauthoredby-claude-deny.json" ;;
    pre-compact.sh)     fixture="solo-guard-336-precompact-checkpoint.json" ;;
    stop.sh)            fixture="stopcard-321-terminal-done-prints.json" ;;
    session-start.sh)   fixture="session-327-compact-advisory.json" ;;
    user-prompt.sh)      fixture="prompt-inject-288-reminder.json" ;;
  esac
  [ -n "$fixture" ] || return 1
  jq -c '.stdin' "$WV_TESTS_DIR/cases/$fixture"
}

WV_ELEVEN_FAILURES=""

run_all_eleven() {
  # run_all_eleven <scenario> -> 0 if all eleven scripts behaved as the
  # scenario requires, 1 otherwise (WV_ELEVEN_FAILURES then names which and
  # why). Every script gets its own fresh mkproj() so one script's state
  # write can never leak into the next script's run. <scenario>:
  #
  #   active             each script's own positive-case state+seed -> the
  #                      script must NOT be a total no-op (AC-13's second
  #                      half: the control that proves the fixtures mean
  #                      something).
  #   closed             the same state+seed, status forced to "closed" ->
  #                      silent (AC-13's first half).
  #   leftover-wave-dir  .wave/ exists, holds no state.json -> silent (AC-12).
  #   no-wave-dir        no .wave/ at all -> silent (AC-398: there is no
  #                      channel to signal an "enforce: warn" intent without
  #                      a state file, so this is also the case that AC
  #                      exercises).
  #   empty-stdin        active state+seed, 0-byte stdin -> silent (AC-30).
  #   nonjson-stdin      active state+seed, "not json at all" stdin -> silent
  #                      (AC-31).
  local scenario="$1"
  WV_ELEVEN_FAILURES=""
  local script n=0

  for script in $(_wv_eleven_scripts); do
    n=$((n + 1))
    local proj
    proj="$(mkproj)"
    WV_PROJECT="$proj"

    local stdin
    stdin="$(_wv_eleven_stdin "$script")"

    case "$scenario" in
      active)
        seed_state "$(_wv_eleven_active_state "$script")"
        _wv_eleven_seed_files "$script"
        ;;
      closed)
        seed_state "$(_wv_eleven_active_state "$script")"
        _wv_eleven_seed_files "$script"
        jq '.status = "closed"' "$proj/.wave/state.json" > "$proj/.wave/state.json.tmp" \
          && mv "$proj/.wave/state.json.tmp" "$proj/.wave/state.json"
        ;;
      leftover-wave-dir)
        mkdir -p "$proj/.wave"
        ;;
      no-wave-dir)
        : # nothing: no .wave/ at all.
        ;;
      empty-stdin)
        seed_state "$(_wv_eleven_active_state "$script")"
        _wv_eleven_seed_files "$script"
        stdin=""
        ;;
      nonjson-stdin)
        seed_state "$(_wv_eleven_active_state "$script")"
        _wv_eleven_seed_files "$script"
        stdin="not json at all"
        ;;
      *)
        WV_ELEVEN_FAILURES="unknown scenario: $scenario"
        return 1
        ;;
    esac

    local stderr_tmp out rc err
    stderr_tmp="$(mktemp "$WV_RUN_TMP/eleven-stderr.XXXXXX")"
    out="$(cd "$proj" && printf '%s' "$stdin" | bash "$WV_REPO_ROOT/scripts/hooks/$script" 2>"$stderr_tmp")"
    rc=$?
    err="$(cat "$stderr_tmp")"
    rm -f "$stderr_tmp"

    if [ "$scenario" = "active" ]; then
      # "Produces its rule": stdout carries a decision, or stderr carries a
      # warning (SubagentStop/PreCompact have no additionalContext channel),
      # or — pre-compact.sh only, whose whole observable effect is a file,
      # never stdout/stderr (spec section 10) — a non-empty checkpoint landed.
      local fired=0
      [ -n "$out" ] && fired=1
      [ -n "$err" ] && fired=1
      if [ "$script" = "pre-compact.sh" ]; then
        local cp
        cp="$(find "$proj/.wave/checkpoints" -name '*-precompact.md' 2>/dev/null | head -n1)"
        [ -n "$cp" ] && [ -s "$cp" ] && fired=1
      fi
      if [ "$rc" != "0" ] || [ "$fired" != "1" ]; then
        WV_ELEVEN_FAILURES="$WV_ELEVEN_FAILURES $script(active-did-not-fire: exit=$rc stdout='$out' stderr='$err')"
      fi
    elif [ "$scenario" = "empty-stdin" ] || [ "$scenario" = "nonjson-stdin" ]; then
      # Global Constraint 4 ("jq absent -> fail open ... The same applies to
      # unparseable stdin ... print exactly one line to stderr and exit 0")
      # mandates the single diagnostic lib.sh's wv_parse_stdin already prints
      # here — "stderr is empty" in AC-30/31's own wording therefore cannot
      # mean byte-for-byte zero output without contradicting a binding
      # Global Constraint every one of these eleven scripts already
      # satisfies; read together with the qualifier immediately following it
      # in the AC ("no unbound-variable trace, no partial state write"), the
      # operative claim is "no CRASH trace", not "no diagnostic line at
      # all". So: stdout must be empty and exit must be 0 unconditionally,
      # and stderr must be either empty or exactly lib.sh's one sanctioned
      # fail-open line for this stdin shape — anything else (an unbound
      # variable trace, a stray second line, a partial write) still fails.
      local allowed
      allowed='wave-plugin: hook stdin was empty; nothing was measured, allowing.'
      if [ "$scenario" = "nonjson-stdin" ]; then
        allowed='wave-plugin: hook stdin was not a JSON object; nothing was measured, allowing.'
      fi
      if [ "$rc" != "0" ] || [ -n "$out" ]; then
        WV_ELEVEN_FAILURES="$WV_ELEVEN_FAILURES $script($scenario-not-silent: exit=$rc stdout='$out')"
      elif [ -n "$err" ] && [ "$err" != "$allowed" ]; then
        WV_ELEVEN_FAILURES="$WV_ELEVEN_FAILURES $script($scenario-unexpected-stderr: want empty or '$allowed', got '$err')"
      fi
      # Also: no partial state write. A $proj/.wave/state.json newer than
      # the one seed_state wrote, or any stray tmp file under .wave/, is a
      # partial write this scenario must never produce.
      if find "$proj/.wave" -maxdepth 1 -name '.state-*' -o -name '*.tmp' 2>/dev/null | command grep -q .; then
        WV_ELEVEN_FAILURES="$WV_ELEVEN_FAILURES $script($scenario-partial-write: a temp state file was left under .wave/)"
      fi
    else
      if [ "$rc" != "0" ] || [ -n "$out" ] || [ -n "$err" ]; then
        WV_ELEVEN_FAILURES="$WV_ELEVEN_FAILURES $script($scenario-not-silent: exit=$rc stdout='$out' stderr='$err')"
      fi
    fi
  done

  [ "$n" -eq 11 ] || WV_ELEVEN_FAILURES="$WV_ELEVEN_FAILURES incomplete-sweep:ran=$n"
  [ -z "$WV_ELEVEN_FAILURES" ]
}
