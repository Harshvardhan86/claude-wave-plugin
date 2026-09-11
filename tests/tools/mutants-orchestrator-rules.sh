#!/usr/bin/env bash
# tests/tools/mutants-orchestrator-rules.sh [--keep]
#
# The mutation control for scripts/hooks/pre-edit.sh, pre-read.sh and
# pre-bash.sh (spec section 8.1-8.3, Task 9). Same construction as
# tests/tools/mutants-pre-agent.sh (read its header first) — a mutant is
# applied to a COPY of the tree in a temp directory, never the working
# tree, with logs outside the copied tree so the measurement cannot write
# into its own subject, and a `real` verdict strips pure rule-coverage FAIL
# lines (`no positive case` / `no negative control`) before deciding
# SURVIVED vs killed, because those fire on every narrow --filter
# regardless of the mutant and would otherwise manufacture a false
# `killed`.
#
# Eleven mutants, covering all three scripts and the shared library function
# pre-edit.sh and pre-read.sh both call:
#   1. the `.wave/` exemption becomes a string prefix instead of a directory one,
#      in pre-edit.sh AND (added by Task 13) in pre-read.sh's own copy of it
#      directory prefix (pre-edit.sh)                    -> edit-265
#   2. the main-session-only guard is removed             (pre-edit.sh)  -> edit-269
#   3. the main-session-only guard is removed             (pre-read.sh)  -> read-276
#   4. the main-session-only guard is removed             (pre-bash.sh)  -> bash-285
#   5. the solo short-circuit is removed                  (pre-edit.sh)  -> edit-331
#   6. the solo short-circuit is removed                  (pre-read.sh)  -> read-332
#   7. the solo short-circuit is removed                  (pre-bash.sh)  -> bash-287
#   8. the runner regex's anchor/word-boundary group is dropped, so a
#      runner name matches anywhere in the command        (pre-bash.sh)  -> bash-283 / bash-286
#   9. hooks/orchestrator-writable.tsv is never consulted  (pre-edit.sh)  -> edit-267a
#  10. the shared path resolver stops resolving symlinks (`-s` instead of
#      `-m`), so a symlink under .wave/ launders an edit   (lib.sh)       -> edit-271
#  11. Fix round 1 (2026-09-10): the widened wrapper/env-assignment prefix
#      group is reverted to the original bare anchor, so `sudo make` /
#      `CI=1 npm test` / leading-whitespace `make` go back to silently
#      allowed                                             (pre-bash.sh)  -> bash-fix1-*
#
# Exit status: 0 only when every mutant was applied, every mutant was
# killed, and the final restore matches the pristine hash for every
# mutated file.
#
#   bash tests/tools/mutants-orchestrator-rules.sh
#   bash tests/tools/mutants-orchestrator-rules.sh --keep   # leave the temp root behind
#
# Deliberately `set -u`, never `set -e`: a mutant whose run fails must
# reach the table rather than abort the sweep.

set -u

WV_TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WV_REPO_ROOT="$(cd "$WV_TOOLS_DIR/../.." && pwd)"
WV_KEEP=0
[ "${1:-}" = "--keep" ] && WV_KEEP=1

for tool in jq git python3; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'mutants-orchestrator-rules.sh: required tool not found on PATH: %s\n' "$tool" >&2
    exit 1
  fi
done

WV_TMP="$(mktemp -d "${TMPDIR:-/tmp}/wave-mutants-orch.XXXXXX")" || exit 1
WV_TREE="$WV_TMP/tree"
WV_LOGS="$WV_TMP/logs"
mkdir -p "$WV_TREE" "$WV_LOGS" || exit 1

cleanup() {
  if [ "$WV_KEEP" = "1" ]; then
    printf 'temp root kept at %s\n' "$WV_TMP"
  else
    rm -rf "$WV_TMP"
  fi
}
trap cleanup EXIT

for d in scripts hooks tests; do
  cp -a "$WV_REPO_ROOT/$d" "$WV_TREE/" || exit 1
done
git -C "$WV_TREE" init -q 2>/dev/null

# Every file a mutant might touch, pristine copies kept by basename.
declare -A WV_PRISTINE=()
declare -A WV_BASE_SHA=()
for f in scripts/hooks/pre-edit.sh scripts/hooks/pre-read.sh scripts/hooks/pre-bash.sh scripts/hooks/lib.sh; do
  base="$(basename "$f")"
  cp "$WV_TREE/$f" "$WV_TMP/$base.pristine"
  WV_PRISTINE["$f"]="$WV_TMP/$base.pristine"
  WV_BASE_SHA["$f"]="$(sha256sum < "$WV_TMP/$base.pristine" | cut -d' ' -f1)"
done

wv_restore_all() {
  local f now
  for f in "${!WV_PRISTINE[@]}"; do
    cp "${WV_PRISTINE[$f]}" "$WV_TREE/$f"
    now="$(sha256sum < "$WV_TREE/$f" | cut -d' ' -f1)"
    if [ "$now" != "${WV_BASE_SHA[$f]}" ]; then
      printf 'FATAL: restore failed for %s (%s != %s)\n' "$f" "$now" "${WV_BASE_SHA[$f]}" >&2
      exit 1
    fi
  done
}

wv_build_patch() {
  local label="$1" body="$2"
  local f="$WV_LOGS/$label.py"
  {
    printf '%s\n' 'import sys' 'p = sys.argv[1]' 's = open(p).read()'
    "$body"
    printf '%s\n' 'open(p, "w").write(s)'
  } > "$f"
  printf '%s' "$f"
}

wv_total=0
wv_survived=0
declare -a wv_rows=()

declare -A WV_EXPECT=()   # mutant label -> the case name that must go red

wv_reds_include() {
  # wv_reds_include <case name or glob> <space-separated red case names>
  local want="$1" cn
  for cn in $2; do
    # shellcheck disable=SC2053  # a glob is intended when one is given
    [[ "$cn" == $want ]] && return 0
  done
  return 1
}

wv_run_mutant() {
  # wv_run_mutant <label> <target-file (repo-relative)> <body-function> <filter>...
  local label="$1" target="$2" body="$3"
  shift 3
  wv_total=$((wv_total + 1))

  local patch
  patch="$(wv_build_patch "$label" "$body")"
  if ! python3 "$patch" "$WV_TREE/$target" 2>"$WV_LOGS/$label.patch.err"; then
    wv_rows+=("$label|NOT-APPLIED|$(tr '\n' ' ' < "$WV_LOGS/$label.patch.err" | tail -c 60)|-")
    wv_survived=$((wv_survived + 1))
    wv_restore_all
    return
  fi
  local mut_sha
  mut_sha="$(sha256sum < "$WV_TREE/$target" | cut -d' ' -f1)"
  if [ "$mut_sha" = "${WV_BASE_SHA[$target]}" ]; then
    wv_rows+=("$label|NOT-APPLIED|patch changed nothing (hash unchanged)|-")
    wv_survived=$((wv_survived + 1))
    wv_restore_all
    return
  fi

  local -a args=()
  local f
  for f in "$@"; do args+=(--filter "$f"); done
  local log="$WV_LOGS/$label.log"
  ( cd "$WV_TREE" && bash tests/run.sh "${args[@]}" ) > "$log" 2>&1

  local summary total
  summary="$(command grep -m1 '^total=' "$log")"
  total="${summary#total=}"; total="${total%% *}"

  local real=0 artefact=0 first="" reds="" fl stripped cn
  while IFS= read -r fl; do
    [ -n "$fl" ] || continue
    stripped="$(printf '%s' "$fl" | sed -E \
      's/rule W-[A-Z0-9-]+: (no positive case|no negative control)(,(no positive case|no negative control))*;?[[:space:]]*//g')"
    case "$stripped" in
      'FAIL '*': '|'FAIL '*':')
        artefact=$((artefact + 1))
        ;;
      *)
        real=$((real + 1))
        cn="$(printf '%s' "$fl" | cut -d' ' -f2 | tr -d ':')"
        reds="$reds $cn"
        [ -n "$first" ] || first="$cn"
        ;;
    esac
  done < <(command grep '^FAIL ' "$log")

  local note=""
  [ "$artefact" -gt 0 ] && note=" (+$artefact coverage artefact(s) ignored)"

  # THE KILL CRITERION IS A NAMED CASE, not "something in this filtered run went
  # red" (progress ledger 103). A filter-level criterion credits the mutant to
  # whatever happened to fail: a neighbouring case that shares the filter, or a
  # coverage complaint the stripper did not recognise. The mutant is then recorded
  # as covered without anything having been shown to cover THAT property, which is
  # the exact failure a mutation sweep exists to rule out. WV_EXPECT names the case
  # that must be among the reds; MEMBERSHIP, not first place, so adding a case that
  # sorts earlier does not turn a real kill into a failure.
  local want="${WV_EXPECT[$label]:-}"
  if [ "$real" -eq 0 ]; then
    wv_rows+=("$label|SURVIVED|${total:-?} cases ran, none red$note|-")
    wv_survived=$((wv_survived + 1))
  elif [ -n "$want" ] && ! wv_reds_include "$want" "$reds"; then
    wv_rows+=("$label|WRONG-CASE|$real red, but not $want$note|${first:-?}")
    wv_survived=$((wv_survived + 1))
  elif [ -z "$want" ]; then
    wv_rows+=("$label|UNPINNED|$real of ${total:-?} red, no expected case declared$note|${first:-?}")
    wv_survived=$((wv_survived + 1))
  else
    wv_rows+=("$label|killed|$real of ${total:-?} red$note|${first:-?}")
  fi
  wv_restore_all
}

# --- 1. the .wave/ exemption becomes a string prefix ------------------------
wv_body_dotwave_stringprefix() { cat <<'PY'
old = '  case "$rel" in\n    .wave|.wave/*) return 0 ;;\n  esac'
new = '  case "$rel" in\n    .wave*) return 0 ;;\n  esac'
assert old in s, "anchor missing: the .wave/ exemption case block"
s = s.replace(old, new)
PY
}

# --- 2/3/4. the main-session-only guard is removed --------------------------
wv_body_agentid_removed() { cat <<'PY'
old = '  [ -z "$WV_AGENT_ID" ] || return 0\n'
assert old in s, "anchor missing: the main-session-only guard"
s = s.replace(old, "", 1)
PY
}

# --- 5/6/7. the solo short-circuit is removed --------------------------------
wv_body_solo_removed() { cat <<'PY'
import re
old_re = re.compile(r'  case "\$WV_MODE" in\n(?:.*\n)*?    \*\) return 0 ;;\n  esac\n')
m = old_re.search(s)
assert m, "anchor missing: the mode case block"
s = s[:m.start()] + '  :\n' + s[m.end():]
PY
}

# --- 8. the runner regex's anchor/word-boundary group is dropped ------------
wv_body_regex_unanchored() { cat <<'PY'
old = "WV_BASH_RUNNER_RE='(^|[;&|])[[:space:]]*((sudo|time|nice|env)([[:space:]]+-[^[:space:]]+)*[[:space:]]+|[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*(npx[[:space:]]+)?(jest|vitest|mocha|playwright|pytest|py\\.test|go test|cargo (test|build)|dotnet (test|build)|make|tsc|ng (build|test)|vite build|npm (test|run (build|test|e2e))|pnpm (test|build)|yarn (test|build))\\b'"
new = "WV_BASH_RUNNER_RE='(jest|vitest|mocha|playwright|pytest|py\\.test|go test|cargo (test|build)|dotnet (test|build)|make|tsc|ng (build|test)|vite build|npm (test|run (build|test|e2e))|pnpm (test|build)|yarn (test|build))'"
assert old in s, "anchor missing: the runner regex definition"
s = s.replace(old, new)
PY
}

# --- 11. the wrapper/env prefix group is removed (Fix round 1, 2026-09-10) --
# Reverts just the widened prefix (leading whitespace, env assignments,
# sudo/time/nice/env wrappers) back to the original bare anchor, so a
# controller-ruling case like `sudo make` or `CI=1 npm test` goes back to
# silently allowed.
wv_body_prefix_group_removed() { cat <<'PY'
old = "WV_BASH_RUNNER_RE='(^|[;&|])[[:space:]]*((sudo|time|nice|env)([[:space:]]+-[^[:space:]]+)*[[:space:]]+|[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*(npx[[:space:]]+)?(jest|vitest|mocha|playwright|pytest|py\\.test|go test|cargo (test|build)|dotnet (test|build)|make|tsc|ng (build|test)|vite build|npm (test|run (build|test|e2e))|pnpm (test|build)|yarn (test|build))\\b'"
new = "WV_BASH_RUNNER_RE='(^|[;&|][[:space:]]*)(npx[[:space:]]+)?(jest|vitest|mocha|playwright|pytest|py\\.test|go test|cargo (test|build)|dotnet (test|build)|make|tsc|ng (build|test)|vite build|npm (test|run (build|test|e2e))|pnpm (test|build)|yarn (test|build))\\b'"
assert old in s, "anchor missing: the widened runner regex definition (Fix round 1)"
s = s.replace(old, new)
PY
}

# --- 9. hooks/orchestrator-writable.tsv is never consulted -------------------
wv_body_writable_ignored() { cat <<'PY'
old = '  wv_writable_allowed "$rel" && return 0\n'
assert old in s, "anchor missing: the writable-tsv allow-list call"
s = s.replace(old, "", 1)
PY
}

# --- 10. the shared path resolver stops resolving symlinks -------------------
wv_body_symlink_removed() { cat <<'PY'
old = 'resolved="$(realpath -m "$abs" 2>/dev/null)"'
new = 'resolved="$(realpath -s -m "$abs" 2>/dev/null)"'
assert old in s, "anchor missing: the realpath -m call in wv_resolve_input_path"
s = s.replace(old, new)
PY
}

# THE EXPECTED KILLER, one per mutant. Each names the case that must be among the
# reds — measured from a real run, not chosen — so a mutant credited to some other
# case in the same filter is reported WRONG-CASE rather than killed. Membership,
# not first place: a case added later that also reds does not disturb these.
WV_EXPECT[dotwave-stringprefix]=edit-265-wavefile-prefix-deny
WV_EXPECT[dotwave-stringprefix-read]=read-278b-wavefile-prefix-deny
WV_EXPECT[agentid-removed-edit]=edit-269-subagent-allow
WV_EXPECT[agentid-removed-read]=read-276-subagent-allow
WV_EXPECT[agentid-removed-bash]=bash-285-subagent-allow
WV_EXPECT[solo-removed-edit]=edit-331-solo-allow
WV_EXPECT[solo-removed-read]=read-332-solo-allow
WV_EXPECT[solo-removed-bash]=bash-287-solo-silent
WV_EXPECT[regex-unanchored]=bash-283-negatives-silent
WV_EXPECT[writable-ignored]=edit-267a-changelog-allow
WV_EXPECT[symlink-realpath-removed]=edit-271-symlink-escape-deny
WV_EXPECT[prefix-group-removed]=bash-fix1-env-npmtest-deny

wv_run_mutant dotwave-stringprefix scripts/hooks/pre-edit.sh wv_body_dotwave_stringprefix 'edit-265*' 'edit-262*' 'edit-267*'
# pre-read.sh carries its OWN copy of the same case-glob, and it had no mutant:
# the identical `.wave*` slip would have exempted every path starting with those
# five bytes from the read gate and nothing would have gone red (ledger 140).
wv_run_mutant dotwave-stringprefix-read scripts/hooks/pre-read.sh wv_body_dotwave_stringprefix 'read-278b*' 'read-278c*' 'read-274*'
wv_run_mutant agentid-removed-edit scripts/hooks/pre-edit.sh wv_body_agentid_removed       'edit-269*' 'edit-261*'
wv_run_mutant agentid-removed-read scripts/hooks/pre-read.sh wv_body_agentid_removed       'read-276*' 'read-273*'
wv_run_mutant agentid-removed-bash scripts/hooks/pre-bash.sh wv_body_agentid_removed       'bash-285*' 'bash-280*'
wv_run_mutant solo-removed-edit    scripts/hooks/pre-edit.sh wv_body_solo_removed          'edit-331*' 'edit-261*'
wv_run_mutant solo-removed-read    scripts/hooks/pre-read.sh wv_body_solo_removed          'read-332*' 'read-273*'
wv_run_mutant solo-removed-bash    scripts/hooks/pre-bash.sh wv_body_solo_removed          'bash-287*' 'bash-333*' 'bash-280*'
wv_run_mutant regex-unanchored     scripts/hooks/pre-bash.sh wv_body_regex_unanchored      'bash-283*' 'bash-286*' 'bash-280*'
wv_run_mutant writable-ignored     scripts/hooks/pre-edit.sh wv_body_writable_ignored      'edit-267*'
wv_run_mutant symlink-realpath-removed scripts/hooks/lib.sh  wv_body_symlink_removed       'edit-271*'
wv_run_mutant prefix-group-removed scripts/hooks/pre-bash.sh wv_body_prefix_group_removed  'bash-fix1-*'

# --- the table --------------------------------------------------------------

printf '\n%-24s %-11s %-40s %s\n' MUTANT VERDICT EFFECT 'FIRST CASE THAT CAUGHT IT'
printf '%s\n' '-----------------------------------------------------------------------------------------------------'
wv_row=""
for wv_row in "${wv_rows[@]:-}"; do
  [ -z "$wv_row" ] && continue
  IFS='|' read -r wv_label wv_verdict wv_effect wv_first <<<"$wv_row"
  printf '%-24s %-11s %-40s %s\n' "$wv_label" "$wv_verdict" "$wv_effect" "$wv_first"
done
printf '%s\n' '-----------------------------------------------------------------------------------------------------'

wv_restored=yes
for f in "${!WV_PRISTINE[@]}"; do
  now="$(sha256sum < "$WV_TREE/$f" | cut -d' ' -f1)"
  [ "$now" = "${WV_BASE_SHA[$f]}" ] || wv_restored=NO
done
printf 'mutants=%s survived=%s restored=%s\n' "$wv_total" "$wv_survived" "$wv_restored"

[ "$wv_survived" -eq 0 ] && [ "$wv_restored" = "yes" ]
