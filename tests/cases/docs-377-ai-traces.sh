#!/usr/bin/env bash
# tests/cases/docs-377-ai-traces.sh — AC-377 (see WAVE_PLUGIN_ANALYSIS/ac-final.md).
#
# GIVEN every file this change adds or modifies / WHEN swept for authorship
# trailer patterns / THEN zero hits, with a planted positive control proving
# the sweep ran and an absent/declined count treated as a failed scan (never
# folded into zero) — functional mentions of the `claude` CLI / plugin name
# and of the model tiers the framework routes to are explicitly not traces.
#
# This case scans every file `git ls-files` reports for the repo (never a
# hard-coded worklist, never a blanket `tests/cases/*.sh` skip), so it can
# only pass if the *actual current tree* is clean, not because the checked
# file list happened to omit the offending file.
set -u

name="${WV_CASE_NAME:-$(basename "$0" .sh)}"
log="${WV_CASE_LOG:-$WV_RUN_TMP/logs/$name.log}"
mkdir -p "$(dirname "$log")"
rc=0
fail() { printf 'ASSERT FAIL: %s\n' "$*" >&2; rc=1; }
note() { printf '%s\n' "$*" >> "$log"; }

# repo_root: resolved from this script's own location by default, but
# overridable via WV_DOCS377_REPO_ROOT so a mutated *copy* of this script
# (run from a scratch directory, see prove_non_vacuous below) still scans
# the real repository rather than wherever the copy happens to live.
if [ -n "${WV_DOCS377_REPO_ROOT:-}" ]; then
  repo_root="$WV_DOCS377_REPO_ROOT"
else
  repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
fi

# The literal trailer patterns AC-377 is about. Deliberately narrow and
# literal (never a bare "claude" word) — that word alone is how the product
# and plugin are functionally named ("the claude CLI", "claude-wave-plugin"),
# and AC-377 explicitly carves those mentions out.
AI_TRACE_PATTERN='(Co-Authored-By: Claude)|(Co-Authored-By: .*@anthropic\.com)|(Generated with \[Claude Code\])|(Claude-Session: https)|(https://claude\.ai/code/session_)'

# ---- exclusions -------------------------------------------------------
#
# Every exclusion is a single NAMED path (never a directory-wide skip of
# test cases, never a `tests/cases/*.sh` blanket) and every one is
# functional: it either IS the pre-commit guard's own detection regex, or
# it is test fixture/tooling whose whole job is to plant one of these exact
# strings as INPUT to prove the guard/hook denies it — never an authorship
# claim about this repo. This list was built from a direct, exhaustive
# sweep of `git ls-files` on 2026-09-10 (confirmed: excluding exactly these
# leaves 0 hits, and every excluded file's match was read and is one of the
# two shapes below) — it is a closed, dated, auditable set, not a growable
# category. A NEW file matching in the future must fail this case loudly
# and be triaged (added here with its own justification, or fixed) rather
# than silently exempted by a broader rule.
#
#  - tests/fixtures/** — fixture data (state/, transcripts/) is crafted
#    content used to drive hook scripts under test.
#  - tests/cases/docs-377-ai-traces.sh (this file) — has to spell the five
#    literal patterns as regex text to search for them.
#  - scripts/hooks/pre-commit-guard.sh — defines WV_PCG_TRAILER_RE, the
#    production regex that DETECTS these trailers; it is the mechanism
#    under test, not a trace of one.
#  - tests/cases/commit-298-coauthoredby-claude-deny.json — fixture proving
#    the guard denies a `Co-Authored-By: Claude` trailer (W-COMMIT-TRAILER).
#  - tests/cases/commit-299-generatedwith-deny.json — fixture proving the
#    guard denies a `Generated with [Claude Code]` trailer.
#  - tests/cases/commit-299-sessionurl-deny.json — fixture proving the
#    guard denies a `claude.ai/code/session_` URL trailer.
#  - tests/cases/commit-303-heredoc-trailer-deny.json — fixture proving the
#    guard denies a trailer supplied via `git commit -F -` heredoc.
#  - tests/cases/commit-304-amend-noedit.sh — plants a trailer-bearing
#    commit to test `--amend --no-edit` behaviour around the guard.
#  - tests/cases/commit-311-scale-timing.sh — constructs a 1 MB commit
#    message containing exactly one `Co-Authored-By: Claude` trailer to
#    time the guard at scale.
#  - tests/cases/solo-guard-335-trailer-deny.json — fixture proving the
#    guard denies a bare `Co-Authored-By: Claude` trailer.
#  - tests/tools/gen-commit-311-fixtures.py — generates the oversized
#    fixture commit-311-scale-timing.sh consumes.
#  - tests/tools/mutants-lifecycle-hooks.sh — mutation-tests the guard by
#    copying and mutating its own WV_PCG_TRAILER_RE definition.
#  - tests/cases/commitmsg-313-trailer-refused.sh — plants a trailer-bearing
#    commit message to prove AC-386 (the commit-msg hook refuses it).
is_excluded_repo_file() {
  case "$1" in
    tests/fixtures/*) return 0 ;;
    tests/cases/docs-377-ai-traces.sh) return 0 ;;
    scripts/hooks/pre-commit-guard.sh) return 0 ;;
    tests/cases/commit-298-coauthoredby-claude-deny.json) return 0 ;;
    tests/cases/commit-299-generatedwith-deny.json) return 0 ;;
    tests/cases/commit-299-sessionurl-deny.json) return 0 ;;
    tests/cases/commit-303-heredoc-trailer-deny.json) return 0 ;;
    tests/cases/commit-304-amend-noedit.sh) return 0 ;;
    tests/cases/commit-311-scale-timing.sh) return 0 ;;
    tests/cases/solo-guard-335-trailer-deny.json) return 0 ;;
    tests/tools/gen-commit-311-fixtures.py) return 0 ;;
    tests/tools/mutants-lifecycle-hooks.sh) return 0 ;;
    tests/cases/commitmsg-313-trailer-refused.sh) return 0 ;;
    *) return 1 ;;
  esac
}

# ---- scanning primitive -------------------------------------------------

scan_tree() {
  # scan_tree <root-dir> <relpath...>
  # Sets globals SCAN_TREE_TOTAL (hit count) and SCAN_TREE_OK (1 success /
  # 0 a file's scan declined/failed) — deliberately NOT `echo`+command
  # substitution, because that would run this function in a subshell and
  # any `fail()` call inside it (which sets the outer `rc`) would then only
  # mutate the subshell's copy, silently losing the failure.
  #
  # Each file is counted independently with `command grep -acE` (never a
  # bare `grep` — this shell's `grep` is a ugrep wrapper that can silently
  # decline a file) and its count and exit code are captured SEPARATELY:
  # rc 0 or 1 means the printed number is the real count (0 is a real
  # zero); rc>=2 or an empty count means the scan declined/failed on that
  # file, which is loudly FAILed rather than folded into the total as zero.
  local root="$1"; shift
  local rel full out rc_grep
  SCAN_TREE_TOTAL=0
  SCAN_TREE_OK=1
  for rel in "$@"; do
    full="$root/$rel"
    [ -f "$full" ] || continue
    out="$(command grep -acE -- "$AI_TRACE_PATTERN" "$full" 2>/dev/null)"
    rc_grep=$?
    if [ "$rc_grep" -ge 2 ] || [ -z "$out" ]; then
      fail "scan declined/failed on $rel (grep rc=$rc_grep, count='$out')"
      SCAN_TREE_OK=0
      continue
    fi
    SCAN_TREE_TOTAL=$((SCAN_TREE_TOTAL + out))
  done
}

# ---- 1: the real repository must scan clean ----------------------------

repo_files=()
while IFS= read -r f; do
  [ -z "$f" ] && continue
  is_excluded_repo_file "$f" && continue
  repo_files+=("$f")
done < <(git -C "$repo_root" ls-files)

scan_tree "$repo_root" "${repo_files[@]}"
repo_total="$SCAN_TREE_TOTAL"
repo_scan_ok="$SCAN_TREE_OK"
note "repo scan: files_checked=${#repo_files[@]} total_hits=$repo_total ok=$repo_scan_ok"
if [ "$repo_scan_ok" -eq 0 ]; then
  fail "real-repo scan declined/failed on at least one file (see ASSERT FAIL lines above)"
elif [ "$repo_total" != "0" ]; then
  fail "real-repo scan found $repo_total authorship-trace hit(s) (want 0)"
fi

# ---- 2: positive + negative control, run through the SAME scan_tree ----
#
# The scratch tree is itself a git repo and is enumerated with the same
# `git ls-files` mechanism as the real-repo scan above (never a hand-rolled
# `find`), so this is proof the same scanning code path was exercised, not
# a parallel implementation that could drift from it.

scratch_dir="$(mktemp -d)"
trap 'rm -rf "$scratch_dir"' EXIT

git init -q "$scratch_dir"
git -C "$scratch_dir" config user.email "wave-selftest@example.invalid"
git -C "$scratch_dir" config user.name "Wave Selftest"

printf 'preamble\nCo-Authored-By: Claude <noreply@anthropic.com>\ntrailer\n' \
  > "$scratch_dir/positive-trailer.txt"
printf 'see https://claude.ai/code/session_abc123 for the transcript\n' \
  > "$scratch_dir/positive-session.txt"
printf 'Claude Code\nclaude-wave-plugin\n' \
  > "$scratch_dir/negative-mentions.txt"
git -C "$scratch_dir" add -A >/dev/null 2>&1

scratch_files=()
while IFS= read -r f; do
  [ -z "$f" ] && continue
  scratch_files+=("$f")
done < <(git -C "$scratch_dir" ls-files)

scan_tree "$scratch_dir" "${scratch_files[@]}"
scratch_total="$SCAN_TREE_TOTAL"
scratch_scan_ok="$SCAN_TREE_OK"
note "scratch positive+negative control: files_checked=${#scratch_files[@]} total_hits=$scratch_total ok=$scratch_scan_ok"
if [ "$scratch_scan_ok" -eq 0 ]; then
  fail "positive control scan declined/failed on at least one scratch file"
elif [ "$scratch_total" != "2" ]; then
  fail "positive control: want exactly 2 hits across the planted scratch files, got $scratch_total"
fi

scan_tree "$scratch_dir" "negative-mentions.txt"
negative_total="$SCAN_TREE_TOTAL"
negative_scan_ok="$SCAN_TREE_OK"
note "negative control alone: total_hits=$negative_total ok=$negative_scan_ok"
if [ "$negative_scan_ok" -eq 0 ]; then
  fail "negative control scan declined/failed"
elif [ "$negative_total" != "0" ]; then
  fail "negative control: 'Claude Code' / 'claude-wave-plugin' alone must report 0 hits, got $negative_total"
fi

# ---- 3: non-vacuity proof ----------------------------------------------
#
# Break AI_TRACE_PATTERN in a scratch COPY of this script (never in the
# repo) and show the positive-control assertion above turns red on that
# copy — i.e. that assertion is load-bearing on the regex actually working,
# not a check that would stay green even with a broken sweep.

prove_non_vacuous() {
  local orig_script mutant_root mutant_script mutant_log mutant_rc
  orig_script="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
  mutant_root="$(mktemp -d)"
  mutant_script="$mutant_root/mutant-docs-377-ai-traces.sh"

  # Replace only the AI_TRACE_PATTERN assignment line with one that cannot
  # match anything; everything else (including the positive-control setup
  # and its "want exactly 2" assertion) stays byte-identical.
  command sed -E \
    "s/^AI_TRACE_PATTERN=.*/AI_TRACE_PATTERN='ZZZ-NON-VACUITY-MUTANT-CANNOT-MATCH-ANYTHING-ZZZ'/" \
    "$orig_script" > "$mutant_script"

  mutant_log="$mutant_root/mutant.log"
  WV_DOCS377_REPO_ROOT="$repo_root" \
    WV_CASE_NAME="mutant-docs-377-ai-traces" \
    WV_CASE_LOG="$mutant_log" \
    bash "$mutant_script" >"$mutant_root/stdout" 2>"$mutant_root/stderr"
  mutant_rc=$?

  if [ "$mutant_rc" -eq 0 ]; then
    fail "non-vacuity proof failed: breaking AI_TRACE_PATTERN did NOT turn the positive control red (mutant exited 0); see $mutant_root before it is removed"
    rm -rf "$mutant_root"
    return 1
  fi

  note "non-vacuity proof OK: mutant with a non-matching AI_TRACE_PATTERN exited $mutant_rc (positive control correctly went red); mutant stderr: $(cat "$mutant_root/stderr" | command grep -F 'positive control' || true)"
  rm -rf "$mutant_root"
  return 0
}

# Guard against infinite recursion: the mutant copy this spawns is a full
# copy of this very script (prove_non_vacuous included), so it must NOT
# call prove_non_vacuous itself — WV_DOCS377_REPO_ROOT is set only when
# this script is running AS a mutant/selftest instance.
if [ -z "${WV_DOCS377_REPO_ROOT:-}" ]; then
  prove_non_vacuous
fi

printf 'RAN docs-check %s decision=allow\n' "$name" >> "$log"
exit $rc
