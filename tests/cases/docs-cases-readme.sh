#!/usr/bin/env bash
# tests/cases/docs-cases-readme.sh
#
# tests/cases/README.md describes the harness contributors write cases for. Its
# behavioural statements are pinned here next to the code fact each one
# describes, so the prose and the runner cannot drift apart silently:
#   1. `script` is required (run.sh fails a case without it) and `stdin` is
#      optional, defaulting to `{}` (assert.sh run_hook);
#   2. the obsolete "wave-init.sh does not exist yet" sentence is gone;
#   3. a `.sh` case exits 0 for PASS and non-zero for FAIL (run.sh);
#   4. the coverage universe counts every id listed in `expect.rules` and
#      `expect.stderr_rules` as a positive (run.sh pre-pass);
#   5. coverage under `--filter` has two paths: a selected positive with no
#      selected negative control fails THAT CASE whatever the flags, and a
#      rule with no selected positive at all is a suite-level line that fails
#      only under `--coverage`.
set -u

# shellcheck source=tests/lib/assert.sh
source "$(dirname "$0")/../lib/assert.sh"

name="${WV_CASE_NAME:-$(basename "$0" .sh)}"
log="${WV_CASE_LOG:-$WV_RUN_TMP/logs/$name.log}"
mkdir -p "$(dirname "$log")"
rc=0
fail() { printf 'ASSERT FAIL: %s\n' "$*" >&2; rc=1; }

readme="$WV_REPO_ROOT/tests/cases/README.md"
runner="$WV_REPO_ROOT/tests/run.sh"
assertlib="$WV_REPO_ROOT/tests/lib/assert.sh"
printf 'RAN tests/cases/README.md %s exit=0\n' "$name" >> "$log"

has() { command grep -qF -- "$2" "$1"; }
# Prose checks read the README with its line breaks folded to single spaces, so
# a sentence wrapped across lines is still one sentence.
flat="$(tr '\n' ' ' < "$readme" | tr -s ' ')"
says() { case "$flat" in *"$1"*) return 0 ;; esac; return 1; }

# The code facts first: if one of these moves, the prose below is unproven.
has "$runner" "case is missing required 'script' field" || fail "run.sh no longer fails a case without 'script'"
has "$assertlib" "jq -c '.stdin // {}'" || fail "assert.sh run_hook no longer defaults stdin to {}"
has "$runner" 'if [ "$rc" = "0" ]; then' || fail "run.sh no longer reads a .sh case's exit 0 as its pass"
has "$runner" "jq -r '.expect.rules[]'" || fail "run.sh no longer counts expect.rules ids as positives"
has "$runner" "jq -r '.expect.stderr_rules[]'" || fail "run.sh no longer counts expect.stderr_rules ids as positives"
has "$runner" 'wv_case_violation["$cn"]' || fail "run.sh no longer fails a positive case whose rule has no negative control"
has "$runner" 'wv_enforce_coverage' || fail "run.sh no longer has the --coverage switch"

# 1. required script, optional stdin.
says 'All fields are optional except `stdin`' && fail "README still says every field but stdin is optional"
says '`script` is required' || fail "README must say script is required"
says 'defaults to `{}`' || fail "README must say stdin defaults to {}"
# 2. the obsolete wave-init sentence.
says 'which does not exist yet' && fail "README still says wave-init.sh does not exist yet"
# 3. .sh exit status.
says 'non-zero for PASS' && fail "README still says a non-zero .sh exit is a PASS"
says 'exit 0 for PASS and non-zero for FAIL' || fail "README must say a .sh case exits 0 for PASS and non-zero for FAIL"

# 4 and 5 live in the coverage section.
section="$(awk '/^## The rule-id coverage self-check/ {on = 1; next} on && /^## / {exit} on' "$readme" | tr '\n' ' ' | tr -s ' ')"
[ -n "$section" ] || fail "README has no rule-id coverage section"
case "$section" in *'`expect.rules`'*'`expect.stderr_rules`'*) : ;; *) fail "the coverage section must count expect.rules and expect.stderr_rules ids as positives" ;; esac
case "$section" in *'--filter'*) : ;; *) fail "the coverage section must describe a --filter run" ;; esac
case "$section" in *'fails that case'*) : ;; *) fail "the coverage section must say a positive without a selected negative control fails that case" ;; esac
case "$section" in *'only under `--coverage`'*) : ;; *) fail "the coverage section must say a rule with no positive fails only under --coverage" ;; esac

exit $rc
