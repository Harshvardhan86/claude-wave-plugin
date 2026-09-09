#!/usr/bin/env bash
# tests/cases/lib-wave-symlink.sh — AC-27.
#
# `.wave` is a symlink. Two halves, and they must differ:
#   A. target inside the project -> behaves exactly as a real directory
#      (this is the negative control: a symlink is not by itself suspicious).
#   B. target outside the project -> no enforcement, a rendered `W-STATE`,
#      and nothing written through the link.
# A JSON case cannot express either half: the case schema has no way to create
# a symlink.
set -u

# shellcheck source=tests/lib/assert.sh
source "$(dirname "$0")/../lib/assert.sh"

name="$(basename "$0" .sh)"

mkcase() {
  # mkcase <seed-json> -> path of a JSON case file named after this case.
  local seed="$1" case_file="$WV_RUN_TMP/$name.json"
  jq -n --argjson seed "$seed" '{
    script: "tests/fixtures/drive-lib.sh",
    env: { WV_DRIVE: "deny:W-TAG" },
    seed: $seed,
    stdin: {
      hook_event_name: "PreToolUse",
      tool_name: "Agent",
      cwd: ".",
      tool_input: {
        description: "probe dispatch",
        prompt: "Do the thing.",
        subagent_type: "general-purpose",
        model: "sonnet"
      },
      tool_use_id: "toolu_016jDXUebmA9qCw58g1rxGuH"
    }
  }' > "$case_file"
  printf '%s' "$case_file"
}

rc=0
fail() { printf 'ASSERT FAIL: %s\n' "$*" >&2; rc=1; }
fixture="$WV_TESTS_DIR/fixtures/state/valid-full.json"

# --- A. .wave -> a directory inside the project ---------------------------
WV_PROJECT="$(mkproj)"
mkdir -p "$WV_PROJECT/runtime-wave"
ln -s runtime-wave "$WV_PROJECT/.wave"

if ! run_hook tests/fixtures/drive-lib.sh "$(mkcase '{"state":"state/valid-full.json"}')"; then
  printf 'run_hook could not run the library: %s\n' "$WV_LAST_STDERR" >&2
  exit 1
fi
assert_exit 0 || rc=1
assert_deny W-TAG || rc=1
[ -f "$WV_PROJECT/runtime-wave/state.json" ] || \
  fail "the seeded state did not land in the symlink target inside the project"
case "$WV_LAST_STDOUT" in
  *W-STATE*) fail "a .wave symlink inside the project must not report W-STATE: '$WV_LAST_STDOUT'" ;;
esac

# --- B. .wave -> a directory outside the project --------------------------
outside="$WV_RUN_TMP/elsewhere-wave"
rm -rf "$outside"
mkdir -p "$outside"
cp "$fixture" "$outside/state.json"
: > "$outside/lock"
before="$(cat "$outside/state.json")"

WV_PROJECT="$(mkproj)"
ln -s "$outside" "$WV_PROJECT/.wave"

# no seed: seeding would write *through* the link, which is the very thing
# this half proves must not happen.
if ! run_hook tests/fixtures/drive-lib.sh "$(mkcase '{}')"; then
  printf 'run_hook could not run the library: %s\n' "$WV_LAST_STDERR" >&2
  exit 1
fi
assert_exit 0 || rc=1
assert_allow || rc=1

ctx="$(printf '%s' "$WV_LAST_STDOUT" | jq -r '.hookSpecificOutput.additionalContext // ""')"
case "$ctx" in
  "[W-STATE] "*) : ;;
  *) fail "outside .wave: additionalContext does not carry a rendered W-STATE: '$ctx'" ;;
esac
case "$ctx" in
  *"$outside"*) : ;;
  *) fail "outside .wave: the W-STATE warning does not name the resolved path: '$ctx'" ;;
esac
[ "$(cat "$outside/state.json")" = "$before" ] || \
  fail "the state file outside the project was modified through the link"
[ -e "$outside/ledger.jsonl" ] && fail "a ledger was written through the outside link"
[ -e "$outside/ledger.pending" ] && fail "a pending ledger spool was written through the outside link"

# --- C. .wave -> outside, and holding no state.json at all ----------------
# The refusal belongs to the DIRECTORY, not to the state file: with a
# state.json present the later outside-the-root check on the file would report
# the same thing, so only an empty outside .wave can show that the directory
# check does any work of its own. Spec section 4 refuses the directory and
# writes nothing through it either way.
empty_outside="$WV_RUN_TMP/elsewhere-empty-wave"
rm -rf "$empty_outside"
mkdir -p "$empty_outside"

WV_PROJECT="$(mkproj)"
ln -s "$empty_outside" "$WV_PROJECT/.wave"

if ! run_hook tests/fixtures/drive-lib.sh "$(mkcase '{}')"; then
  printf 'run_hook could not run the driver: %s\n' "$WV_LAST_STDERR" >&2
  exit 1
fi
assert_exit 0 || rc=1
assert_allow || rc=1

ctx="$(printf '%s' "$WV_LAST_STDOUT" | jq -r '.hookSpecificOutput.additionalContext // ""')"
case "$ctx" in
  "[W-STATE] "*) : ;;
  *) fail "outside .wave holding no state.json: additionalContext does not carry a rendered W-STATE: '$ctx'" ;;
esac
case "$ctx" in
  *"$empty_outside"*) : ;;
  *) fail "outside .wave holding no state.json: the W-STATE warning does not name the resolved path: '$ctx'" ;;
esac
[ -z "$(ls -A "$empty_outside")" ] || \
  fail "something was written through the outside link: $(ls -A "$empty_outside")"

exit $rc
