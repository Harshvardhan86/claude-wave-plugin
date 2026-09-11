#!/usr/bin/env bash
# tests/tools/mutants-lifecycle-hooks.sh [--keep]
#
# The mutation control for Task 10's five scripts (pre-commit-guard.sh,
# pre-compact.sh, stop.sh, session-start.sh, user-prompt.sh) plus the wave-id
# bound in scripts/wave-init.sh, which is the other half of session-start.sh's
# character budget: proves the
# case corpus is not vacuous by breaking one property at a time and
# requiring at least one case to go red for each. Same construction as
# tests/tools/mutants-post-agent.sh (read its header first) — a mutant is
# applied to a COPY of the tree in a temp directory, never the working
# tree, with logs OUTSIDE the copied tree so the measurement cannot write
# into its own subject; a `real` verdict strips pure rule-coverage FAIL
# lines (`no positive case` / `no negative control`) before deciding
# SURVIVED vs killed, because those fire on every narrow --filter regardless
# of the mutant and would otherwise manufacture a false `killed`.
#
# Eight mutants — the task-10-brief's own six, plus the two properties the fix
# rounds added, which cases pinned and no mutant could break:
#   1. the planning-path glob is unanchored (drops `^`/`$`)
#   2. the trailer regex is loosened to the bare word "claude"
#   3. the commit guard's main-session-only (agent_id) guard is removed
#   4. the PreCompact checkpoint is written without the ledger section
#   5. the stop.sh scorecard pointer's once-per-wave marker check is removed
#   6. the reminder is emitted with no active wave at all
#   7. wave-init.sh's 1-24 `[A-Za-z0-9._-]` wave-id bound is loosened — the bound
#      the session banner's own 400-character budget is derived from
#   8. session-start.sh's two advisory clauses are collected in the other order,
#      so the clause dropped when the cap binds is the SHORT actionable one
#
# Exit status: 0 only when every mutant was applied, every mutant was
# killed, and the final restore matches the pristine hash for every target
# file (this sweep touches five files, not one, so each keeps its own
# pristine copy and hash).
#
#   bash tests/tools/mutants-lifecycle-hooks.sh
#   bash tests/tools/mutants-lifecycle-hooks.sh --keep   # leave the temp root behind
#
# Deliberately `set -u`, never `set -e`: a mutant whose run fails must reach
# the table rather than abort the sweep.

set -u

WV_TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WV_REPO_ROOT="$(cd "$WV_TOOLS_DIR/../.." && pwd)"
WV_KEEP=0
[ "${1:-}" = "--keep" ] && WV_KEEP=1

for tool in jq git python3; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'mutants-lifecycle-hooks.sh: required tool not found on PATH: %s\n' "$tool" >&2
    exit 1
  fi
done

WV_TMP="$(mktemp -d "${TMPDIR:-/tmp}/wave-mutants-lifecycle.XXXXXX")" || exit 1
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

declare -A WV_PRISTINE=()
declare -A WV_BASE_SHA=()

wv_register_target() {
  # wv_register_target <relative-script-path> — one pristine copy + hash per
  # file this sweep mutates, so restoring one target never touches another.
  #
  # `rel` and `target` are declared in SEPARATE `local` statements: bash
  # expands every word on a command line before the command runs, so
  # `local rel="$1" target="$WV_TREE/$rel"` in ONE statement expands
  # `$rel` against whatever it was BEFORE this call (unset, under `set
  # -u`) — the assignments in a single `local` do not chain.
  local rel="$1"
  local target="$WV_TREE/$rel"
  local pristine="$WV_TMP/$(basename "$rel").pristine"
  cp "$target" "$pristine" || exit 1
  WV_PRISTINE["$rel"]="$pristine"
  WV_BASE_SHA["$rel"]="$(sha256sum < "$pristine" | cut -d' ' -f1)"
}

wv_register_target scripts/hooks/pre-commit-guard.sh
wv_register_target scripts/hooks/pre-compact.sh
wv_register_target scripts/hooks/stop.sh
wv_register_target scripts/hooks/user-prompt.sh
wv_register_target scripts/hooks/session-start.sh
# Not a hook, but the wave id's bound lives here and the banner's character budget
# is derived from it: the two are one property with two halves, and this sweep is
# where the banner's half is already measured.
wv_register_target scripts/wave-init.sh

wv_restore_target() {
  local rel="$1"
  local target="$WV_TREE/$rel"
  cp "${WV_PRISTINE[$rel]}" "$target"
  local now
  now="$(sha256sum < "$target" | cut -d' ' -f1)"
  if [ "$now" != "${WV_BASE_SHA[$rel]}" ]; then
    printf 'FATAL: restore failed for %s (%s != %s)\n' "$rel" "$now" "${WV_BASE_SHA[$rel]}" >&2
    exit 1
  fi
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
  # wv_run_mutant <label> <relative-script-path> <body-function> <filter>...
  local label="$1" rel="$2" body="$3"
  shift 3
  local target="$WV_TREE/$rel"
  wv_total=$((wv_total + 1))

  local patch
  patch="$(wv_build_patch "$label" "$body")"
  if ! python3 "$patch" "$target" 2>"$WV_LOGS/$label.patch.err"; then
    wv_rows+=("$label|NOT-APPLIED|$(tr '\n' ' ' < "$WV_LOGS/$label.patch.err" | tail -c 40)|-")
    wv_survived=$((wv_survived + 1))
    wv_restore_target "$rel"
    return
  fi
  local mut_sha
  mut_sha="$(sha256sum < "$target" | cut -d' ' -f1)"
  if [ "$mut_sha" = "${WV_BASE_SHA[$rel]}" ]; then
    wv_rows+=("$label|NOT-APPLIED|patch changed nothing (hash unchanged)|-")
    wv_survived=$((wv_survived + 1))
    wv_restore_target "$rel"
    return
  fi

  # A MUTANT THAT DOES NOT PARSE KILLS EVERYTHING AND PROVES NOTHING. A mutation is
  # supposed to invert ONE property and leave the script running; one that breaks the
  # syntax makes every case under the filter red on `syntax error`, and this driver
  # would then report the mutant killed and the property covered. Measured while
  # adding `waveidbound`: an unquoted space inside a `case` pattern ended the word,
  # all 7 cases in the filter reded on the parse error, and the row said `killed`.
  # A broken mutant is not a weaker mutant, it is not a mutant, so it counts as
  # SURVIVED — the property still has no mutation proof.
  if ! bash -n "$target" 2>"$WV_LOGS/$label.parse.err"; then
    wv_rows+=("$label|INVALID|does not parse: $(tr '\n' ' ' < "$WV_LOGS/$label.parse.err" | tail -c 60)|-")
    wv_survived=$((wv_survived + 1))
    wv_restore_target "$rel"
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
  wv_restore_target "$rel"
}

# --- 1. planning-path glob unanchored ---------------------------------------
wv_body_globunanchored() { cat <<'PY'
old = "  printf '^%s$' \"$out\"\n}"
assert old in s, "anchor missing: wv_pcg_glob_to_ere's anchored printf"
new = "  printf '%s' \"$out\"\n}"
s = s.replace(old, new, 1)
PY
}

# --- 2. trailer regex loosened to the bare word "claude" -------------------
wv_body_trailerloosened() { cat <<'PY'
old = "WV_PCG_TRAILER_RE='Co-Authored-By: Claude|Co-Authored-By: [^[:space:]]*@anthropic\\.com|Generated with \\[Claude Code\\]|Claude-Session: https|https://claude\\.ai/code/session_'"
assert old in s, "anchor missing: WV_PCG_TRAILER_RE"
new = "WV_PCG_TRAILER_RE='[Cc]laude'"
s = s.replace(old, new)
PY
}

# --- 3. the commit guard's main-session-only (agent_id) guard is removed ---
wv_body_agentidguardremoved() { cat <<'PY'
old = "  # Only the main session is gated; a subagent's own commits are not judged\n  # by this rule (spec section 8, applied consistently here too).\n  [ -z \"$WV_AGENT_ID\" ] || return 0\n\n"
assert old in s, "anchor missing: the main-session-only agent_id guard"
s = s.replace(old, "", 1)
PY
}

# --- 4. the PreCompact checkpoint is written without the ledger section ----
wv_body_noledgersection() { cat <<'PY'
old = "    printf '\\n## Ledger\\n\\n'\n    wv_pc_ledger_summary\n"
assert old in s, "anchor missing: the checkpoint's Ledger section"
s = s.replace(old, "", 1)
PY
}

# --- 5. stop.sh's once-per-wave marker check is removed --------------------
wv_body_scorecardtwice() { cat <<'PY'
old = "  [ -f \"$WV_WAVE_DIR/.scorecard-printed\" ] && return 0\n\n"
assert old in s, "anchor missing: the scorecard-printed early return"
s = s.replace(old, "", 1)
PY
}

# --- 6. the reminder is emitted with no active wave at all -----------------
wv_body_reminderwithnowave() { cat <<'PY'
old = "  wv_project_root || return 0\n  wv_state_read || return 0\n"
assert old in s, "anchor missing: user-prompt.sh's project-root/state-read guards"
new = '  WV_STATE_OK=1; WV_WAVE="mutant"; WV_MODE="full"\n'
s = s.replace(old, new, 1)
PY
}

# --- 7. the wave id's 1-24 [A-Za-z0-9._-] bound is loosened ----------------
#
# BOTH halves at once, because they are one property: the character class admits `/`,
# and the length limit goes to 9999. init-360 rejects both halves independently (a
# 25-character id, and `a/b`), so its log names each — a mutant killed on only one
# half would be visible there rather than credited whole.
#
# The class admits `/` and NOT a space, and that is not a style choice: an unquoted
# space inside a `case` pattern ends the word, so `*[!A-Za-z0-9._/ -]*)` is a SYNTAX
# ERROR. Measured — that version of this mutant reded all 7 cases under the filter,
# every one of them on `wave-init.sh: line 106: syntax error`, i.e. it was killed for
# not parsing rather than for loosening anything. The parse gate in wv_run_mutant now
# refuses such a mutant outright; this comment is why it exists.
wv_body_waveidbound() { cat <<'PY'
old_class = '  *[!A-Za-z0-9._-]*)'
assert old_class in s, "anchor missing: wave-init.sh's wave-id character class"
s = s.replace(old_class, '  *[!A-Za-z0-9._/-]*)', 1)
old_len = 'if [ "${#wave_id}" -gt 24 ]; then'
assert old_len in s, "anchor missing: wave-init.sh's 24-character wave-id limit"
s = s.replace(old_len, 'if [ "${#wave_id}" -gt 9999 ]; then', 1)
PY
}

# --- 8. the two advisory clauses are collected in the other order ----------
#
# The staleness clause is MOVED to after the compaction clause rather than reworded,
# so the mutant is the order and nothing else. wv_list_cap fills from the front, so
# under the maximum accepted input — where the budget genuinely cannot hold both —
# this drops the short clause that names the command to run and keeps the long one.
wv_body_clauseorder() { cat <<'PY'
block = '  if wv_wave_stale_24h; then\n    clauses+=("wave open >24h; scripts/wave-close.sh closes it.")\n  fi\n\n'
assert block in s, "anchor missing: session-start.sh's staleness clause block"
s = s.replace(block, "", 1)
anchor = '  local extra=""\n'
assert anchor in s, "anchor missing: session-start.sh's extra assembly"
s = s.replace(anchor, block + anchor, 1)
PY
}

# THE EXPECTED KILLER, one per mutant. Each names the case that must be among the
# reds — measured from a real run, not chosen — so a mutant credited to some other
# case in the same filter is reported WRONG-CASE rather than killed. Membership,
# not first place: a case added later that also reds does not disturb these.
WV_EXPECT[globunanchored]=commit-296-falsedeny-corpus-allow
WV_EXPECT[trailerloosened]=commit-298-coauthoredby-claude-deny
WV_EXPECT[agentidguardremoved]=commit-subagent-silent
WV_EXPECT[noledgersection]=compact-315-content-verify
WV_EXPECT[scorecardtwice]=stopcard-322-alreadyprinted-silent
WV_EXPECT[reminderwithnowave]=prompt-inject-11-no-wave-silent
WV_EXPECT[waveidbound]=init-360-invalid-args
# session-327d is the maximum accepted input, the one collision where the budget
# really cannot hold both clauses, so it is where the order DECIDES which advisory
# the operator sees. session-327b and session-327e also red (each pins the order with
# a needle spanning the join), and membership means naming one does not exclude them.
WV_EXPECT[clauseorder]=session-327d-max-banner-stale

wv_run_mutant globunanchored        scripts/hooks/pre-commit-guard.sh wv_body_globunanchored        'commit-*' 'solo-guard-*'
wv_run_mutant trailerloosened       scripts/hooks/pre-commit-guard.sh wv_body_trailerloosened       'commit-*' 'solo-guard-*'
wv_run_mutant agentidguardremoved   scripts/hooks/pre-commit-guard.sh wv_body_agentidguardremoved   'commit-*' 'solo-guard-*'
wv_run_mutant noledgersection       scripts/hooks/pre-compact.sh      wv_body_noledgersection       'compact-*' 'solo-guard-336*'
wv_run_mutant scorecardtwice        scripts/hooks/stop.sh             wv_body_scorecardtwice        'stopcard-*'
wv_run_mutant reminderwithnowave    scripts/hooks/user-prompt.sh      wv_body_reminderwithnowave    'prompt-inject-*'
wv_run_mutant waveidbound           scripts/wave-init.sh              wv_body_waveidbound           'init-36*'
wv_run_mutant clauseorder           scripts/hooks/session-start.sh    wv_body_clauseorder           'session-*'

# --- the table --------------------------------------------------------------

printf '\n%-21s %-11s %-33s %s\n' MUTANT VERDICT EFFECT 'FIRST CASE THAT CAUGHT IT'
printf '%s\n' '-----------------------------------------------------------------------------------------'
wv_row=""
for wv_row in "${wv_rows[@]:-}"; do
  [ -z "$wv_row" ] && continue
  IFS='|' read -r wv_label wv_verdict wv_effect wv_first <<<"$wv_row"
  printf '%-21s %-11s %-33s %s\n' "$wv_label" "$wv_verdict" "$wv_effect" "$wv_first"
done
printf '%s\n' '-----------------------------------------------------------------------------------------'

wv_all_restored=yes
for rel in "${!WV_PRISTINE[@]}"; do
  now="$(sha256sum < "$WV_TREE/$rel" | cut -d' ' -f1)"
  if [ "$now" != "${WV_BASE_SHA[$rel]}" ]; then
    wv_all_restored=NO
    printf 'restore mismatch: %s\n' "$rel" >&2
  fi
done
printf 'mutants=%s survived=%s restored=%s\n' "$wv_total" "$wv_survived" "$wv_all_restored"

[ "$wv_survived" -eq 0 ] && [ "$wv_all_restored" = "yes" ]
