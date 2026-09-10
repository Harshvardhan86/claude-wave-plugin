#!/usr/bin/env bash
# tests/tools/mutants-post-agent.sh [--keep]
#
# The mutation control for `scripts/hooks/post-agent.sh`: proves the launch-*
# suite is not vacuous by breaking one property of the hook at a time and
# requiring at least one case to go red for each. Same construction as
# tests/tools/mutants-pre-agent.sh (read its header first) — a mutant is
# applied to a COPY of the tree in a temp directory, never the working tree,
# with logs outside the copied tree so the measurement cannot write into its
# own subject, and a `real` verdict strips pure rule-coverage FAIL lines
# (`no positive case` / `no negative control`) before deciding SURVIVED vs
# killed, because those fire on every narrow --filter regardless of the
# mutant and would otherwise manufacture a false `killed`.
#
# Four mutants, one per property task-7-brief.md names explicitly:
#   1. the resolved-tier comparison is inverted (a downgrade reads as fine
#      and vice versa)
#   2. the state write is keyed on tool_use_id instead of agentId (the join
#      key SubagentStop needs)
#   3. the tool_response-as-STRING path is removed (both the fromjson step
#      and the command-grep fallback), collapsing the tolerant reader to the
#      object shape only
#   4. the PostToolUse event guard is dropped
#
# Exit status: 0 only when every mutant was applied, every mutant was
# killed, and the final restore matches the pristine hash.
#
#   bash tests/tools/mutants-post-agent.sh
#   bash tests/tools/mutants-post-agent.sh --keep   # leave the temp root behind
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
    printf 'mutants-post-agent.sh: required tool not found on PATH: %s\n' "$tool" >&2
    exit 1
  fi
done

WV_TMP="$(mktemp -d "${TMPDIR:-/tmp}/wave-mutants-post.XXXXXX")" || exit 1
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

WV_TARGET="$WV_TREE/scripts/hooks/post-agent.sh"
WV_PRISTINE="$WV_TMP/post-agent.pristine.sh"
cp "$WV_TARGET" "$WV_PRISTINE" || exit 1
WV_BASE_SHA="$(sha256sum < "$WV_PRISTINE" | cut -d' ' -f1)"

wv_restore() {
  cp "$WV_PRISTINE" "$WV_TARGET"
  local now
  now="$(sha256sum < "$WV_TARGET" | cut -d' ' -f1)"
  if [ "$now" != "$WV_BASE_SHA" ]; then
    printf 'FATAL: restore failed (%s != %s)\n' "$now" "$WV_BASE_SHA" >&2
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
  # wv_run_mutant <label> <body-function> <filter>...
  local label="$1" body="$2"
  shift 2
  wv_total=$((wv_total + 1))

  local patch
  patch="$(wv_build_patch "$label" "$body")"
  if ! python3 "$patch" "$WV_TARGET" 2>"$WV_LOGS/$label.patch.err"; then
    wv_rows+=("$label|NOT-APPLIED|$(tr '\n' ' ' < "$WV_LOGS/$label.patch.err" | tail -c 40)|-")
    wv_survived=$((wv_survived + 1))
    wv_restore
    return
  fi
  local mut_sha
  mut_sha="$(sha256sum < "$WV_TARGET" | cut -d' ' -f1)"
  if [ "$mut_sha" = "$WV_BASE_SHA" ]; then
    wv_rows+=("$label|NOT-APPLIED|patch changed nothing (hash unchanged)|-")
    wv_survived=$((wv_survived + 1))
    wv_restore
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
  wv_restore
}

# --- 1. the resolved-tier comparison is inverted ---------------------------
wv_body_tierinverted() { cat <<'PY'
old = '&& [ "$resolved_tier" -lt "$requested_tier" ]; then'
new = '&& [ "$resolved_tier" -gt "$requested_tier" ]; then'
assert old in s, "anchor missing: the resolved-tier comparison"
s = s.replace(old, new)
PY
}

# --- 2. the join key is tool_use_id instead of agentId ---------------------
wv_body_joinkeywrong() { cat <<'PY'
old = 'wv_write_active "$agent_id" "$phase" "$role" "$WV_MODEL_TRIM" \\\n    "$resolved_model_val" "$WV_TOOL_USE_ID" "$status_field"'
new = 'wv_write_active "$WV_TOOL_USE_ID" "$phase" "$role" "$WV_MODEL_TRIM" \\\n    "$resolved_model_val" "$WV_TOOL_USE_ID" "$status_field"'
assert old in s, "anchor missing: the active-record call"
s = s.replace(old, new)
PY
}

# --- 3. the tool_response-as-string path is removed ------------------------
wv_body_stringpathremoved() { cat <<'PY'
old = '''  val="$(printf '%s' "$WV_JSON" | jq -r --arg n "$name" \\
    '(.tool_response | fromjson?)[$n]? // empty' 2>/dev/null)"
  if [ -n "$val" ]; then printf '%s' "$val"; return 0; fi

  local raw
  raw="$(printf '%s' "$WV_JSON" | jq -r \\
    '.tool_response | if type == "string" then . else tostring end' 2>/dev/null)"
  if [ -n "$raw" ]; then
    val="$(printf '%s' "$raw" | command grep -o "\\"$name\\":\\"[^\\"]*\\"" | head -n1)"
    if [ -n "$val" ]; then
      val="${val#*:\\"}"
      val="${val%\\"}"
      printf '%s' "$val"
      return 0
    fi
  fi
  return 1'''
new = '  return 1'
assert old in s, "anchor missing: the string/grep fallback branches"
s = s.replace(old, new)
PY
}

# --- 4. the PostToolUse event guard is dropped ------------------------------
wv_body_eventguard() { cat <<'PY'
old = '  [ "$WV_EVENT" = "PostToolUse" ] || return 0\n'
assert old in s, "anchor missing: the event guard"
s = s.replace(old, "")
PY
}

# --- 5. the unperformed downgrade check goes back to being silent ----------
wv_body_uncheckedquiet() { cat <<'PY'
old = '  elif [ -z "$requested_tier" ]; then'
new = '  elif [ "zzz-never" = "$requested_tier" ]; then'
assert old in s, "anchor missing: the no-requested-tier branch"
s = s.replace(old, new)
PY
}

# THE EXPECTED KILLER, one per mutant. Each names the case that must be among the
# reds — measured from a real run, not chosen — so a mutant credited to some other
# case in the same filter is reported WRONG-CASE rather than killed. Membership,
# not first place: a case added later that also reds does not disturb these.
WV_EXPECT[tierinverted]=launch-192-truncated-downgrade
WV_EXPECT[joinkeywrong]=launch-190-object-launched
WV_EXPECT[stringpathremoved]=launch-191-string-launched
WV_EXPECT[eventguard]=postguard-001-wrong-event-silent
WV_EXPECT[uncheckedquiet]=launch-193b-no-requested-tier-warn

wv_run_mutant tierinverted       wv_body_tierinverted       'launch-19*'
wv_run_mutant joinkeywrong       wv_body_joinkeywrong       'launch-19*'
wv_run_mutant stringpathremoved  wv_body_stringpathremoved  'launch-19*'
wv_run_mutant eventguard         wv_body_eventguard         'postguard-*' 'launch-*'
wv_run_mutant uncheckedquiet    wv_body_uncheckedquiet    'launch-193*'

# --- the table --------------------------------------------------------------

printf '\n%-17s %-11s %-33s %s\n' MUTANT VERDICT EFFECT 'FIRST CASE THAT CAUGHT IT'
printf '%s\n' '-----------------------------------------------------------------------------------------'
wv_row=""
for wv_row in "${wv_rows[@]:-}"; do
  [ -z "$wv_row" ] && continue
  IFS='|' read -r wv_label wv_verdict wv_effect wv_first <<<"$wv_row"
  printf '%-17s %-11s %-33s %s\n' "$wv_label" "$wv_verdict" "$wv_effect" "$wv_first"
done
printf '%s\n' '-----------------------------------------------------------------------------------------'

wv_final="$(sha256sum < "$WV_TARGET" | cut -d' ' -f1)"
if [ "$wv_final" = "$WV_BASE_SHA" ]; then wv_restored=yes; else wv_restored=NO; fi
printf 'mutants=%s survived=%s restored=%s\n' "$wv_total" "$wv_survived" "$wv_restored"

[ "$wv_survived" -eq 0 ] && [ "$wv_restored" = "yes" ]
