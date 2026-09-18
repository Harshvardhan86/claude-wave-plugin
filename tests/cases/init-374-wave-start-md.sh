#!/usr/bin/env bash
# tests/cases/init-374-wave-start-md.sh — AC-374.
#
# commands/wave-start.md is a slash-command prompt, not executable code, so
# this is a static content check: it parses --demo and --solo, its
# allowed-tools front-matter covers the wave-init.sh and wave-set.sh
# invocations, step 0 asks four scope questions (vocabulary and
# behaviour-change before wave-init.sh, as flags; ui and cr through
# wave-set.sh), and it states a one-line refusal when .wave/state.json is
# absent.
set -u

# shellcheck source=tests/lib/assert.sh
source "$(dirname "$0")/../lib/assert.sh"

name="$(basename "$0" .sh)"
log="${WV_CASE_LOG:-$WV_RUN_TMP/logs/$name.log}"
mkdir -p "$(dirname "$log")"

rc=0
fail() { printf 'ASSERT FAIL: %s\n' "$*" >&2; rc=1; }

md="$WV_REPO_ROOT/commands/wave-start.md"
[ -f "$md" ] || { fail "$md does not exist"; printf 'RAN commands/wave-start.md %s exit=1\n' "$name" >> "$log"; exit 1; }

content="$(cat "$md")"

printf 'RAN commands/wave-start.md %s exit=0\n' "$name" >> "$log"

case "$content" in
  *'--demo'*) : ;;
  *) fail "wave-start.md does not mention --demo" ;;
esac
case "$content" in
  *'--solo'*) : ;;
  *) fail "wave-start.md does not mention --solo" ;;
esac

allowed_line="$(command grep -m1 '^allowed-tools:' "$md")"
case "$allowed_line" in
  *'wave-init.sh'*) : ;;
  *) fail "allowed-tools does not cover wave-init.sh: '$allowed_line'" ;;
esac
case "$allowed_line" in
  *'wave-set.sh'*) : ;;
  *) fail "allowed-tools does not cover wave-set.sh: '$allowed_line'" ;;
esac

case "$content" in
  *'Step 0'*) : ;;
  *) fail "wave-start.md has no Step 0 section" ;;
esac
for key in ui behaviour-change cr vocabulary; do
  case "$content" in
    *"wave-set.sh $key"*) : ;;
    *) fail "wave-start.md does not route the '$key' answer through wave-set.sh" ;;
  esac
done

# The two early flags are wave-init pairs (the leading -- is what distinguishes
# them from the wave-set.sh behaviour-change / vocabulary strings above).
for flag in --vocabulary --no-vocabulary --behaviour-change --no-behaviour-change; do
  case "$content" in
    *"$flag"*) : ;;
    *) fail "wave-start.md does not mention the wave-init flag '$flag'" ;;
  esac
done

vocab_q='Does this wave introduce a new kind of record, or a new value of an existing classification (a status, a category, a role), that a user will see?'
case "$content" in
  *"$vocab_q"*) : ;;
  *) fail "wave-start.md is missing the vocabulary question wording" ;;
esac

vocab_line="$(command grep -nF "$vocab_q" "$md" | head -1 | cut -d: -f1)"
init_line="$(command grep -nF 'wave-init.sh --wave' "$md" | head -1 | cut -d: -f1)"
if [ -z "$vocab_line" ]; then
  fail "could not find the vocabulary question line"
elif [ -z "$init_line" ]; then
  fail "could not find the wave-init.sh --wave invocation"
elif [ "$vocab_line" -ge "$init_line" ]; then
  fail "vocabulary question is on line $vocab_line, which is not before wave-init.sh on line $init_line"
fi

case "$content" in
  *'state.json'*'not present'*|*'not present'*'state.json'*|*'.wave/state.json'*absent*|*absent*'.wave/state.json'*) : ;;
  *) fail "wave-start.md does not state a refusal keyed on .wave/state.json being absent" ;;
esac
case "$content" in
  *'stop'*|*'Stop'*) : ;;
  *) fail "wave-start.md does not tell the orchestrator to stop on that refusal" ;;
esac

exit $rc
