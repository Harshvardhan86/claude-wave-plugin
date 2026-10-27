#!/usr/bin/env bash
# tests/tools/mutants-lifecycle-hooks.sh [--keep] [--mutant <label>]
#
# The mutation control for the five lifecycle scripts (pre-commit-guard.sh,
# pre-compact.sh, stop.sh, session-start.sh, user-prompt.sh) plus the wave-id
# bound in scripts/wave-init.sh, which is the other half of session-start.sh's
# character budget, plus the advisory evaluator in scripts/hooks/lib.sh
# (wv_up_condition_met / wv_next_allowed_phase) that those hooks print:
# proves the case corpus is not vacuous by breaking one property at a time
# and requiring at least one case to go red for each. Same construction as
# tests/tools/mutants-post-agent.sh (read its header first) — a mutant is
# applied to a COPY of the tree in a temp directory, never the working
# tree, with logs OUTSIDE the copied tree so the measurement cannot write
# into its own subject; a `real` verdict strips pure rule-coverage FAIL
# lines (`no positive case` / `no negative control`) before deciding
# SURVIVED vs killed, because those fire on every narrow --filter regardless
# of the mutant and would otherwise manufacture a false `killed`.
#
# `--mutant <label>` runs only that row (used to re-check a single new
# mutant without replaying the rest of the sweep).
#
# Eight mutants — the task-10-brief's own six, plus the two properties the fix
# rounds added, which cases pinned and no mutant could break:
#   1. the planning-path glob is unanchored (drops `^`/`$`)
#   2. the trailer regex is loosened to the bare word "claude"
#   3. the commit guard's main-session-only (agent_id) guard is removed
#   4. the PreCompact checkpoint is written without the ledger section
#   5. the scorecard pointer's once-per-wave marker check is removed (since
#      the second revision it lives in lib.sh wv_close_announce, which stop.sh calls)
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
#   bash tests/tools/mutants-lifecycle-hooks.sh --mutant unansweredskipped
#
# Deliberately `set -u`, never `set -e`: a mutant whose run fails must reach
# the table rather than abort the sweep.

set -u

WV_TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WV_REPO_ROOT="$(cd "$WV_TOOLS_DIR/../.." && pwd)"
WV_KEEP=0
WV_ONLY_MUTANT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --keep) WV_KEEP=1; shift ;;
    --mutant)
      [ $# -ge 2 ] || {
        printf 'mutants-lifecycle-hooks.sh: --mutant needs a label\n' >&2
        exit 1
      }
      WV_ONLY_MUTANT="$2"; shift 2 ;;
    *)
      printf 'mutants-lifecycle-hooks.sh: unknown argument: %s\n' "$1" >&2
      printf 'usage: bash tests/tools/mutants-lifecycle-hooks.sh [--keep] [--mutant <label>]\n' >&2
      exit 1
      ;;
  esac
done

for tool in jq git python3; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'mutants-lifecycle-hooks.sh: required tool not found on PATH: %s\n' "$tool" >&2
    exit 1
  fi
done

WV_TMP="$(mktemp -d "${TMPDIR:-/tmp}/wave-mutants-lifecycle.XXXXXX")" || exit 1
# The harness keeps the scratch directory of every RED run, and every killed
# mutant is a red run: each run gets TMPDIR inside this temp root, removed
# after the run (kept with --keep) and with the root on exit
# (tests/cases/_selfcheck/data-mutant-scratch.sh).
WV_SCRATCH="$WV_TMP/scratch"
WV_TREE="$WV_TMP/tree"
WV_LOGS="$WV_TMP/logs"
mkdir -p "$WV_TREE" "$WV_LOGS" || exit 1

cleanup() {
  if [ "$WV_KEEP" = "1" ]; then
    printf 'temp root kept at %s\n' "$WV_TMP"
  else
    chmod -R u+rwX "$WV_TMP" 2>/dev/null
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
wv_register_target scripts/hooks/lib.sh
wv_register_target scripts/hooks/pre-compact.sh
wv_register_target scripts/hooks/stop.sh
wv_register_target scripts/hooks/subagent-stop.sh
wv_register_target scripts/hooks/user-prompt.sh
wv_register_target scripts/hooks/session-start.sh
# Not a hook, but the wave id's bound lives here and the banner's character budget
# is derived from it: the two are one property with two halves, and this sweep is
# where the banner's half is already measured.
wv_register_target scripts/wave-init.sh
# Not a hook either: the close-time Delivery section is rendered here.
wv_register_target scripts/wave-scorecard.sh
wv_register_target scripts/wave-close.sh

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
  if [ -n "$WV_ONLY_MUTANT" ] && [ "$label" != "$WV_ONLY_MUTANT" ]; then
    return
  fi
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
  mkdir -p "$WV_SCRATCH"
  ( cd "$WV_TREE" && TMPDIR="$WV_SCRATCH" bash tests/run.sh "${args[@]}" ) > "$log" 2>&1
  if [ "$WV_KEEP" != "1" ]; then chmod -R u+rwX "$WV_SCRATCH" 2>/dev/null; rm -rf "$WV_SCRATCH"; fi

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
old = "WV_TRAILER_ERE='Co-Authored-By: Claude|Co-Authored-By: .*@anthropic\\.com|Generated with \\[Claude Code\\]|Claude-Session: https|https://claude\\.ai/code/session_'"
assert old in s, "anchor missing: WV_TRAILER_ERE"
new = "WV_TRAILER_ERE='[Cc]laude'"
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

# --- 5. the pointer's once-per-wave marker check is removed ---------------
# RE-ANCHORED: the check moved from stop.sh into lib.sh's
# wv_close_announce, the one composition both hooks use. Killed by
# stopcard-322 (solo, marker present: silent).
wv_body_scorecardtwice() { cat <<'PY'
old = '{ [ ! -f "$d/.scorecard-printed" ] && [ -s "$d/ledger.jsonl" ]; }'
assert old in s, "anchor missing: the scorecard-printed once-per-wave check"
s = s.replace(old, '{ [ -s "$d/ledger.jsonl" ]; }', 1)
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
wv_run_mutant trailerloosened       scripts/hooks/lib.sh wv_body_trailerloosened       'commit-*' 'solo-guard-*'
wv_run_mutant agentidguardremoved   scripts/hooks/pre-commit-guard.sh wv_body_agentidguardremoved   'commit-*' 'solo-guard-*'
wv_run_mutant noledgersection       scripts/hooks/pre-compact.sh      wv_body_noledgersection       'compact-*' 'solo-guard-336*'
wv_run_mutant scorecardtwice        scripts/hooks/lib.sh              wv_body_scorecardtwice        'stopcard-*'
wv_run_mutant reminderwithnowave    scripts/hooks/user-prompt.sh      wv_body_reminderwithnowave    'prompt-inject-*'
wv_run_mutant waveidbound           scripts/wave-init.sh              wv_body_waveidbound           'init-36*'
wv_run_mutant clauseorder           scripts/hooks/session-start.sh    wv_body_clauseorder           'session-*'

# Leftover mutations act only inside the copied test tree.
wv_body_leftoverprefixcwd() { cat <<'PYM'
old = 'if [ "$cwd" = "$root" ]; then'
assert old in s
s = s.replace(old, 'if [[ "$cwd" == "$root"* ]]; then', 1)
PYM
}
wv_body_leftovercronsdropped() { cat <<'PYM'
old = 'crons:($crons|map(select(named)))'
assert old in s
s = s.replace(old, 'crons:[]', 1)
PYM
}
wv_body_leftoverwarnremoved() { cat <<'PYM'
old = '    if wv_rule_warn W-LEFTOVER "$WV_LO_SUMMARY"'
assert old in s
s = s.replace(old, '    if true', 1)
PYM
}
wv_body_leftoverstopwarn() { cat <<'PYM'
old = '          if wv_rule_warn W-LEFTOVER "$WV_LO_SUMMARY"'
assert old in s
s = s.replace(old, '          if true', 1)
PYM
}
wv_body_leftoverkills() { cat <<'PYM'
old = 'if [ "$cwd" = "$root" ]; then'
assert old in s
s = s.replace(old, old + '\n        kill "$pid" 2>/dev/null', 1)
PYM
}
wv_body_leftoverscanclean() { cat <<'PYM'
old = 'if [ "$markers" -eq 0 ]; then WV_LO_STATUS=unavailable'
assert old in s
s = s.replace(old, 'if [ "$markers" -eq 0 ]; then WV_LO_STATUS=ok', 1)
PYM
}
wv_body_leftoverprecompactsection() { cat <<'PYM'
old = '    wv_lo_render_section\n'
assert old in s
s = s.replace(old, '', 1)
PYM
}
wv_body_leftoverselfexcluded() { cat <<'PYM'
old = '''  pid="$BASHPID"
  while [[ "$pid" =~ ^[1-9][0-9]*$ ]] && [ -z "${excluded[$pid]:-}" ]; do
    excluded[$pid]=1
    [ -r "/proc/$pid/stat" ] || break
    statline="$(<"/proc/$pid/stat")"
    tail="${statline##*) }"
    read -r state parent tail <<< "$tail"
    pid="$parent"
  done
  excluded[$$]=1
'''
assert old in s
s = s.replace(old, '', 1)
PYM
}
wv_body_leftovermarkerfirst() { cat <<'PYM'
old = '  wv_lo_collect\n  wv_lo_write_checkpoint\n'
assert old in s
s = s.replace(old, '  [ -f "$WV_WAVE_DIR/.scorecard-printed" ] && return 0\n  wv_lo_collect\n  wv_lo_write_checkpoint\n', 1)
PYM
}
WV_EXPECT[leftoverprefixcwd]=leftover-426-proc-exact-root
WV_EXPECT[leftovercronsdropped]=leftover-428-absent-vs-empty
WV_EXPECT[leftoverwarnremoved]=leftover-423-terminal-warn
WV_EXPECT[leftoverstopwarn]=leftover-431-closing-subagent
WV_EXPECT[leftoverkills]=leftover-426-proc-exact-root
WV_EXPECT[leftoverscanclean]=leftover-427-scan-unavailable
WV_EXPECT[leftoverprecompactsection]=leftover-429-precompact-and-solo
WV_EXPECT[leftoverselfexcluded]=leftover-426-proc-exact-root
WV_EXPECT[leftovermarkerfirst]=leftover-430-closed-and-double-stop
wv_run_mutant leftoverprefixcwd scripts/hooks/lib.sh wv_body_leftoverprefixcwd 'leftover-426*'
wv_run_mutant leftovercronsdropped scripts/hooks/lib.sh wv_body_leftovercronsdropped 'leftover-428*'
# RE-TARGETED: the 4-space anchor line moved, byte-identical,
# from stop.sh into lib.sh wv_close_announce.
wv_run_mutant leftoverwarnremoved scripts/hooks/lib.sh wv_body_leftoverwarnremoved 'leftover-423*'
wv_run_mutant leftoverstopwarn scripts/hooks/subagent-stop.sh wv_body_leftoverstopwarn 'leftover-431*'
wv_run_mutant leftoverkills scripts/hooks/lib.sh wv_body_leftoverkills 'leftover-426*'
wv_run_mutant leftoverscanclean scripts/hooks/lib.sh wv_body_leftoverscanclean 'leftover-427*'
wv_run_mutant leftoverprecompactsection scripts/hooks/pre-compact.sh wv_body_leftoverprecompactsection 'leftover-429*'
wv_run_mutant leftoverselfexcluded scripts/hooks/lib.sh wv_body_leftoverselfexcluded 'leftover-426*'
wv_run_mutant leftovermarkerfirst scripts/hooks/stop.sh wv_body_leftovermarkerfirst 'leftover-430*'

# --- unanswered reads as skipped (advisory evaluator, design 3.2) ----------
#
# Collapses wv_up_condition_met's third outcome (return 2, unanswered) back
# into return 1 (not met). wv_up_phase_settled then treats the row as
# skipped and wv_next_allowed_phase walks through it to a successor the
# gate would refuse. Killed by advisory-gate-agreement.
wv_body_unansweredskipped() { cat <<'PY'
start = s.find('wv_up_condition_met()')
end = s.find('wv_up_phase_settled()')
assert start != -1 and end != -1, "anchor missing: wv_up_condition_met / wv_up_phase_settled"
block = s[start:end]
assert 'return 2' in block, "anchor missing: unanswered return 2 in wv_up_condition_met"
new_block = block.replace('return 2', 'return 1')
assert new_block != block, "unansweredskipped: return 2 was not replaced"
s = s[:start] + new_block + s[end:]
PY
}
WV_EXPECT[unansweredskipped]=advisory-gate-agreement
wv_run_mutant unansweredskipped scripts/hooks/lib.sh wv_body_unansweredskipped 'advisory-gate-agreement'

# --- wave complete: anytime rows count towards complete --------------------
# Drops the when=phase filter so AD (anytime) must be done before the wave
# is complete. Killed by stop-227-dash-artifact: the last of VB/COMMIT/CL/CCP
# closes while AD has never run.
wv_body_anytimecounts() { cat <<'PY'
old = '''    [ "$when" = "phase" ] || continue
    case ",$modes," in
      *",$WV_MODE,"*) : ;;
      *) continue ;;
    esac
    wv_up_phase_settled "$code" || return 1
'''
new = '''    : # anytime rows count towards complete
    case ",$modes," in
      *",$WV_MODE,"*) : ;;
      *) continue ;;
    esac
    wv_up_phase_settled "$code" || return 1
'''
assert old in s, "anchor missing: anytime rows skipped in wv_wave_complete"
s = s.replace(old, new, 1)
PY
}
WV_EXPECT[anytimecounts]=stop-227-dash-artifact
wv_run_mutant anytimecounts scripts/hooks/lib.sh wv_body_anytimecounts 'stop-227*' 'complete-wave-complete'

# --- wave complete: unanswered counts as settled ---------------------------
# An unsettled row (including unanswered) is skipped instead of blocking.
# Killed by complete-wave-complete (vocabulary unknown).
wv_body_unansweredsettled() { cat <<'PY'
old = '    wv_up_phase_settled "$code" || return 1\n'
assert old in s, "anchor missing: unsettled row blocks wv_wave_complete"
s = s.replace(old, '    wv_up_phase_settled "$code" || continue\n', 1)
PY
}
WV_EXPECT[unansweredsettled]=complete-wave-complete
wv_run_mutant unansweredsettled scripts/hooks/lib.sh wv_body_unansweredsettled 'complete-wave-complete'

# --- 5.4: absent ben-close.md reads as delivered ---------------------------
wv_body_absentdelivered() { cat <<'PY'
old = '''  if [ ! -f "$file" ]; then
    printf 'unverified'
    return 0
  fi'''
new = '''  if [ ! -f "$file" ]; then
    printf 'delivered'
    return 0
  fi'''
assert old in s, "anchor missing: absent ben-close.md is unverified"
s = s.replace(old, new, 1)
PY
}
WV_EXPECT[absentdelivered]=init-delivery-54
wv_run_mutant absentdelivered scripts/hooks/lib.sh wv_body_absentdelivered 'init-delivery-54' 'init-363*'

# --- 5.4: BEN not done with behaviour_change true reads as not-applicable --
wv_body_bctrueapplicable() { cat <<'PY'
old = '''      true|unknown) printf 'unverified' ;;
      *) printf 'not-applicable' ;;'''
new = '''      true|unknown) printf 'not-applicable' ;;
      *) printf 'unverified' ;;'''
assert old in s, "anchor missing: BEN not done + bc true/unknown is unverified"
s = s.replace(old, new, 1)
PY
}
WV_EXPECT[bctrueapplicable]=init-delivery-54
wv_run_mutant bctrueapplicable scripts/hooks/lib.sh wv_body_bctrueapplicable 'init-delivery-54'

# --- 5.4: the BEN row's modes are not consulted -----------------------------
# A demo wave with behaviour_change true then closes unverified and is told to
# run a phase demo does not have. Killed by init-delivery-54's mode rows.
wv_body_benmodesignored() { cat <<'PY'
old = '  if ben_modes="$(wv_row_get BEN "$WV_COL_MODES")"; then\n'
assert old in s, "anchor missing: verdict reads the BEN row's modes"
s = s.replace(old, '  if false; then\n', 1)
PY
}
WV_EXPECT[benmodesignored]=init-delivery-54
wv_run_mutant benmodesignored scripts/hooks/lib.sh wv_body_benmodesignored 'init-delivery-54' 'undelivered-*'

# --- scorecard: Delivery section printed when state.json has no delivery ---
# The guard's exact negation. Killed by scorecard-004-delivery's first leg,
# which seeds a ledger line so the scorecard is actually rendered (without it
# the "no ledger" early return hid the Delivery code and this mutant survived).
wv_body_deliveryalways() { cat <<'PY'
old = 'if [ -n "$wv_sc_delivery" ]; then\n'
assert old in s, "anchor missing: Delivery section gated on a set delivery"
s = s.replace(old, 'if true; then\n', 1)
PY
}
WV_EXPECT[deliveryalways]=scorecard-004-delivery
wv_run_mutant deliveryalways scripts/wave-scorecard.sh wv_body_deliveryalways 'scorecard-*'

# --- close-report, completeness and verdict-reader mutants ------------------

# The close is reported without reading state.json back. Killed by
# undelivered-failed-close (a failing closer must yield W-STATE, no pointer).
wv_body_closeunchecked() { cat <<'PY'
old = '  if [ "$closed" != "closed" ]; then\n'
assert old in s, "anchor missing: close report reads the closed status back"
s = s.replace(old, '  if false; then\n', 1)
PY
}
WV_EXPECT[closeunchecked]=undelivered-failed-close
wv_run_mutant closeunchecked scripts/hooks/subagent-stop.sh wv_body_closeunchecked 'undelivered-*'

# A verdict no longer forces its same-call pointer (it goes out
# alone once the pointer marker exists). RE-ANCHORED: the
# composition moved from stop.sh into lib.sh wv_close_announce. Killed by
# undelivered-close-matrix (its pointer-already-printed leg).
wv_body_undeliveredinstead() { cat <<'PY'
old = '    if [ "$verdict_now" = "1" ] || { [ ! -f "$d/.scorecard-printed" ]'
assert old in s, "anchor missing: the verdict-forces-pointer condition"
s = s.replace(old, '    if { [ ! -f "$d/.scorecard-printed" ]', 1)
PY
}
WV_EXPECT[undeliveredinstead]=undelivered-close-matrix
wv_run_mutant undeliveredinstead scripts/hooks/lib.sh wv_body_undeliveredinstead 'undelivered-*'

# The final-row leftover trigger is gone (only a completing stop
# inventories). Killed by leftover-431 (failed / artifact-missing final row).
wv_body_finalrownoinventory() { cat <<'PY'
old = '      if wv_final_row "$WV_STOP_PHASE" && wv_wave_complete "$WV_STOP_PHASE"; then\n'
assert old in s, "anchor missing: final-row leftover trigger"
s = s.replace(old, '      if false; then\n', 1)
PY
}
WV_EXPECT[finalrownoinventory]=leftover-431-closing-subagent
wv_run_mutant finalrownoinventory scripts/hooks/subagent-stop.sh wv_body_finalrownoinventory 'leftover-431*'

# Completeness made stale-aware, so it disagrees with the gate. Killed
# by complete-wave-complete (done-and-stale).
wv_body_stalenotsettled() { cat <<'PY'
old = '  [ "$(wv_state_phase_status "$code")" = "done" ] && return 0\n  modes="$(wv_row_get "$code" "$WV_COL_MODES")" || return 1\n'
assert old in s, "anchor missing: wv_up_phase_settled done check"
new = '  [ "$(printf "%s" "$WV_STATE" | jq -r --arg c "$code" ".phases[\\$c].stale // false")" = "true" ] && return 1\n' + old
s = s.replace(old, new, 1)
PY
}
WV_EXPECT[stalenotsettled]=complete-wave-complete
wv_run_mutant stalenotsettled scripts/hooks/lib.sh wv_body_stalenotsettled 'complete-*'

# An unmeasurable findings condition (no FINDINGS: line, unreadable file)
# reads as settled for completeness too, so the closer closes a wave whose
# BF- row the gate still holds (W-MARKER, or fail-open required). Killed by
# complete-unmeasurable-findings.
wv_body_unmeasurablesettled() { cat <<'PY'
old = '    3) [ "${WV_UP_STRICT:-0}" = "1" ] && return 1; return 0 ;;\n'
assert old in s, "anchor missing: strict completeness reads unmeasurable as unsettled"
s = s.replace(old, '    3) return 0 ;;\n', 1)
PY
}
WV_EXPECT[unmeasurablesettled]=complete-unmeasurable-findings
wv_run_mutant unmeasurablesettled scripts/hooks/lib.sh wv_body_unmeasurablesettled 'complete-*'

# Any row's done stop may trigger the close again, so an AD (anytime) stop
# closes a complete-but-active wave. Killed by complete-ad-no-close.
wv_body_anytimetriggers() { cat <<'PY'
old = '[ "$status_new" = "done" ] && [ "$trig_when" = "phase" ] && wv_wave_complete; then\n'
assert old in s, "anchor missing: only a when=phase row triggers the close"
s = s.replace(old, '[ "$status_new" = "done" ] && wv_wave_complete; then\n', 1)
PY
}
WV_EXPECT[anytimetriggers]=complete-ad-no-close
wv_run_mutant anytimetriggers scripts/hooks/subagent-stop.sh wv_body_anytimetriggers 'complete-*'

# The closer decides on the state it read BEFORE taking the lock (the
# under-lock re-read is skipped), so a redo, a new wave or another close
# recorded while it waited is overwritten. Killed by
# complete-close-lock-race.
wv_body_closeunlocked() { cat <<'PY'
old = 'if ! wv_state_read; then\n  wv_lock_release\n'
assert old in s, "anchor missing: the under-lock re-read in wave-close.sh"
s = s.replace(old, 'if false; then\n  wv_lock_release\n', 1)
PY
}
WV_EXPECT[closeunlocked]=complete-close-lock-race
wv_run_mutant closeunlocked scripts/wave-close.sh wv_body_closeunlocked 'complete-*'

# A done scan with a missing findings file reads as skipped again.
# Killed by complete-wave-complete (done-scan-missing-findings).
wv_body_missingfindingsskips() { cat <<'PY'
old = '        [ "$(wv_state_phase_status "$src")" = "done" ] && return 2\n'
assert old in s, "anchor missing: done scan + missing findings is unanswered"
s = s.replace(old, '', 1)
PY
}
WV_EXPECT[missingfindingsskips]=complete-wave-complete
wv_run_mutant missingfindingsskips scripts/hooks/lib.sh wv_body_missingfindingsskips 'complete-*'

# The verdict reader strips trailing whitespace/CR, so it disagrees with
# the BEN-CLOSE stop marker. Killed by undelivered-benclose-edges.
wv_body_benclosestrip() { cat <<'PY'
old = """  line="$(command grep -m1 -E '^BENEFIT: (DELIVERED|UNDELIVERED)$' "$file" 2>/dev/null || true)\""""
assert old in s, "anchor missing: the verdict line reader"
new = """  line="$(sed -E 's/[[:space:]]+$//' "$file" 2>/dev/null | command grep -m1 -E '^BENEFIT: (DELIVERED|UNDELIVERED)$' || true)\""""
s = s.replace(old, new, 1)
PY
}
WV_EXPECT[benclosestrip]=undelivered-benclose-edges
wv_run_mutant benclosestrip scripts/hooks/lib.sh wv_body_benclosestrip 'undelivered-*'

# --- Stop never closes; close-time warning composition ----------------------

# The Stop on a complete, unclosed full/demo wave announces the verdict
# and the pointer after its W-STATE (it falls through to wv_close_announce).
# Killed by stopcard-321 (W-STATE alone, no pointer, no marker).
wv_body_stopannounces() { cat <<'PY'
old = '      return 0\n      ;;\n  esac\n\n  wv_close_announce'
assert old in s, "anchor missing: stop.sh full/demo W-STATE return"
s = s.replace(old, '      ;;\n  esac\n\n  wv_close_announce', 1)
PY
}
WV_EXPECT[stopannounces]=stopcard-321-terminal-done-prints
wv_run_mutant stopannounces scripts/hooks/stop.sh wv_body_stopannounces 'stopcard-*'

# A SubagentStop that attempts the close warns of leftovers (and writes
# .leftover-warned) BEFORE the close is confirmed. Killed by
# undelivered-failed-close (failed closer with leftovers: no marker).
wv_body_leftovernotdeferred() { cat <<'PY'
old = '        if [ "$will_close" = "0" ] && [ "$WV_LO_WARN" = "1" ]'
assert old in s, "anchor missing: the deferred closing-call leftover warning"
s = s.replace(old, '        if [ "$WV_LO_WARN" = "1" ]', 1)
PY
}
WV_EXPECT[leftovernotdeferred]=undelivered-failed-close
wv_run_mutant leftovernotdeferred scripts/hooks/subagent-stop.sh wv_body_leftovernotdeferred 'undelivered-*'

# A leftover warning from a PRIOR call suppresses this call's pointer
# (the round-1 SubagentStop behaviour). Killed by undelivered-close-matrix.
wv_body_priorwarnsuppresses() { cat <<'PY'
old = '  if [ "$lo_now" = "0" ]; then\n'
assert old in s, "anchor missing: the pointer when no leftover warning was queued this call"
s = s.replace(old, '  if [ "$lo_now" = "0" ] && [ ! -f "$d/.leftover-warned" ]; then\n', 1)
PY
}
WV_EXPECT[priorwarnsuppresses]=undelivered-close-matrix
wv_run_mutant priorwarnsuppresses scripts/hooks/lib.sh wv_body_priorwarnsuppresses 'undelivered-*'

# A leftover close (W-LEFTOVER carried the pointer) does not write
# .scorecard-printed. Killed by undelivered-close-matrix.
wv_body_leftoverpointerunmarked() { cat <<'PY'
old = '      lo_now=1\n      pointer=1\n'
assert old in s, "anchor missing: W-LEFTOVER counts as the pointer"
s = s.replace(old, '      lo_now=1\n', 1)
PY
}
WV_EXPECT[leftoverpointerunmarked]=undelivered-close-matrix
wv_run_mutant leftoverpointerunmarked scripts/hooks/lib.sh wv_body_leftoverpointerunmarked 'undelivered-*'

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

if [ -n "$WV_ONLY_MUTANT" ] && [ "$wv_total" -eq 0 ]; then
  printf 'mutants-lifecycle-hooks.sh: no mutant named %s\n' "$WV_ONLY_MUTANT" >&2
  exit 1
fi

[ "$wv_survived" -eq 0 ] && [ "$wv_all_restored" = "yes" ]
