#!/usr/bin/env bash
# scripts/hooks/pre-commit-guard.sh — the PreToolUse hook on `Bash`, matcher
# `^Bash$`, that guards `git commit` during an active wave (spec section 10,
# invariant 6).
#
# Two independent rules, evaluated in hooks/reasons.tsv's precedence order
# (W-COMMIT-DOC before W-COMMIT-TRAILER), each capable of firing on its own:
#
#   W-COMMIT-DOC      a staged path matches a row of hooks/planning-paths.tsv
#                      (downgraded to a warning by .wave/approvals/commit-doc.md)
#   W-COMMIT-TRAILER  the message text carries an AI-attribution trailer
#
# Kept ON in every mode, including solo (spec section 13 lists solo's
# enforcement as sections 7, 9 and 10 — this script IS section 10): it is a
# cheap invariant, unlike the tag/order/round machinery solo switches off.
#
# Detecting "is this a git commit" is done with bash's own `[[ =~ ]]`
# (glibc's regex engine), never `command grep`, so a broken or wrapped `grep`
# on PATH cannot make the whole script go silently blind to a commit — only
# the two GATING SCANS below (Global Constraint 7) go through `command grep`,
# and each is built to warn (W-STATE) rather than guess when its count cannot
# be measured. `git` itself is run as `git -C "<stdin cwd>"`, never
# `CLAUDE_PROJECT_DIR`: the guard has to inspect the index the commit will
# actually use, including a worktree's own index (spec section 10 / AC-310).
#
# The whole `tool_input.command` string is scanned for a trailer, not just a
# `-m` argument: a heredoc (`git commit -F - <<'EOF' ... EOF`) puts the
# message text directly in the command string the client sends, and `--amend
# --no-edit` puts it nowhere in the command at all, which is why that one
# shape also reads `git log -1 --format=%B` (spec section 10).

set -u

WV_HOOK_DIR="$(cd "${BASH_SOURCE[0]%/*}" 2>/dev/null && pwd)"
# shellcheck source=scripts/hooks/lib.sh
source "$WV_HOOK_DIR/lib.sh"

# Routing only — not a compliance measurement, so it must not depend on an
# external `grep` that a test (or a broken PATH) can wrap into silence. A
# declared bound: `^`/`[;&|]` only see a `git commit` that starts the command
# or follows one of the shell's own compound-separators on the SAME line as
# read by bash's single-buffer regex match; a `git commit` reached only after
# a literal newline with no `;`/`&`/`|` before it is not detected. Every
# shape spec section 10 and the AC corpus name (`git -C dir commit`, `cd x &&
# git commit`, repeated spaces, `--amend --no-edit`, a heredoc whose `git
# commit ... <<'EOF'` line is the command's first line) starts right at byte
# 0 or right after such a separator, so this bound is never hit by them.
WV_PCG_COMMIT_RE='(^|[;&|])[[:space:]]*git([[:space:]]+-C[[:space:]]+[^[:space:]]+)?[[:space:]]+commit\b'

# The five literal attribution-trailer forms (task brief, binding details):
# deliberately narrow so a FUNCTIONAL mention of "claude" in code or in a
# commit message — this very plugin is named claude-wave-plugin — is never
# touched. `[` and `]` are escaped for ERE; `.` in "anthropic.com" is escaped
# for precision, though an unescaped `.` there would still only ever match a
# character, never widen what counts as a trailer.
WV_PCG_TRAILER_RE='Co-Authored-By: Claude|Co-Authored-By: [^[:space:]]*@anthropic\.com|Generated with \[Claude Code\]|Claude-Session: https|https://claude\.ai/code/session_'

declare -a WV_PCG_GLOBS=() WV_PCG_LABELS=()

wv_pcg_load_rows() {
  WV_PCG_GLOBS=()
  WV_PCG_LABELS=()
  local tsv="$WV_PLUGIN_DIR/hooks/planning-paths.tsv"
  [ -f "$tsv" ] || return 0
  local glob label
  while IFS=$'\t' read -r glob label; do
    case "$glob" in ''|'#'*|glob) continue ;; esac
    WV_PCG_GLOBS+=("$glob")
    WV_PCG_LABELS+=("$label")
  done < "$tsv"
  return 0
}

wv_pcg_glob_to_ere() {
  # wv_pcg_glob_to_ere <glob> -> an anchored ERE on stdout. `**` becomes
  # `.*` (crosses `/`), a lone `*` becomes `[^/]*` (one path segment), a
  # `[...]` character class (the one real use: `wave[0-9]`) is passed
  # through untouched, and every other ERE metacharacter is escaped first so
  # it is never mistaken for one of the two wildcard forms.
  local g="$1"
  local n="${#g}" i c escaped="" out=""
  for ((i = 0; i < n; i++)); do
    c="${g:i:1}"
    case "$c" in
      '\') escaped+='\\' ;;
      '.'|'+'|'?'|'('|')'|'{'|'}'|'|'|'^'|'$') escaped+="\\$c" ;;
      *) escaped+="$c" ;;
    esac
  done
  local m="${#escaped}" j=0
  while [ "$j" -lt "$m" ]; do
    c="${escaped:j:1}"
    if [ "$c" = "*" ]; then
      if [ "$((j + 1))" -lt "$m" ] && [ "${escaped:j+1:1}" = "*" ]; then
        out+=$'\x01'
        j=$((j + 2))
        continue
      fi
      out+='[^/]*'
      j=$((j + 1))
      continue
    fi
    out+="$c"
    j=$((j + 1))
  done
  out="${out//$'\x01'/.*}"
  printf '^%s$' "$out"
}

wv_pcg_combined_regex() {
  # Assumes wv_pcg_load_rows has already been called in the CALLER's shell
  # (never here — this function is always invoked via a command
  # substitution, i.e. a subshell, whose variable writes do not survive it).
  local i out=""
  for i in "${!WV_PCG_GLOBS[@]}"; do
    out="${out:+$out|}$(wv_pcg_glob_to_ere "${WV_PCG_GLOBS[$i]}")"
  done
  printf '%s' "$out"
}

WV_PCG_COUNT=""

wv_pcg_scan() {
  # wv_pcg_scan <text> <regex> <label> — the Global Constraint 7 gating-scan
  # contract (mirrors lib.sh's wv_scan / pre-agent.sh's wv_scan_text) applied
  # to in-memory text: sets WV_PCG_COUNT and returns 0, or warns W-STATE and
  # returns 1 when `command grep` returns no usable count at all. Never
  # called through a command substitution — the warning it queues must reach
  # THIS shell's queue, not a subshell's copy that dies with it.
  WV_PCG_COUNT=""
  local text="$1" regex="$2" label="$3" count
  count="$(command grep -cE -- "$regex" <<<"$text" 2>/dev/null)"
  case "$count" in
    ''|*[!0-9]*)
      wv_rule_warn W-STATE "the $label scan returned no count, so it did not run and nothing was measured; re-run once grep is behaving normally"
      return 1
      ;;
  esac
  WV_PCG_COUNT="$count"
  return 0
}

wv_pcg_doc_check() {
  local staged="$1"
  [ -n "$staged" ] || return 0

  # Loaded as a plain statement, NOT inside the command substitution below:
  # `$(wv_pcg_combined_regex)` runs in a subshell, and a subshell's writes to
  # the WV_PCG_GLOBS / WV_PCG_LABELS globals would vanish the moment it exits
  # — the per-path loop further down needs those arrays populated in THIS
  # shell.
  wv_pcg_load_rows
  local combined
  combined="$(wv_pcg_combined_regex)"
  [ -n "$combined" ] || return 0

  wv_pcg_scan "$staged" "$combined" "staged path list" || return 0
  [ "$WV_PCG_COUNT" -gt 0 ] || return 0

  # The aggregate scan proved SOMETHING matches; per path/row attribution
  # (for naming the exact row in the reason) is a second, independent
  # `command grep` per candidate — still Global-Constraint-7 compliant, and
  # if it degrades differently than the aggregate scan just did, the result
  # is silence rather than a false positive (checked below).
  local -a hit_paths=() hit_descs=()
  local path
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    local i glob label ere
    for i in "${!WV_PCG_GLOBS[@]}"; do
      glob="${WV_PCG_GLOBS[$i]}"
      label="${WV_PCG_LABELS[$i]}"
      ere="$(wv_pcg_glob_to_ere "$glob")"
      if command grep -qE -- "$ere" <<<"$path" 2>/dev/null; then
        hit_paths+=("$path")
        hit_descs+=("$path (matches \`$glob\` $label)")
        break
      fi
    done
  done <<<"$staged"

  [ "${#hit_paths[@]}" -gt 0 ] || return 0

  local desc_joined path_joined d p
  desc_joined=""
  for d in "${hit_descs[@]}"; do
    desc_joined="${desc_joined:+$desc_joined, }$d"
  done
  path_joined=""
  for p in "${hit_paths[@]}"; do
    path_joined="${path_joined:+$path_joined }$p"
  done

  if [ -f "$WV_WAVE_DIR/approvals/commit-doc.md" ]; then
    wv_rule_warn W-COMMIT-DOC "$desc_joined" "$path_joined"
  else
    wv_rule_deny W-COMMIT-DOC "$desc_joined" "$path_joined"
  fi
  return 0
}

wv_pcg_trailer_check() {
  local scan_text="$1"
  wv_pcg_scan "$scan_text" "$WV_PCG_TRAILER_RE" "commit message" || return 0
  [ "$WV_PCG_COUNT" -gt 0 ] || return 0

  local matched
  matched="$(printf '%s\n' "$scan_text" | command grep -m1 -oE -- "$WV_PCG_TRAILER_RE" 2>/dev/null)"
  [ -n "$matched" ] || matched="(a matching line could not be re-extracted)"
  wv_rule_deny W-COMMIT-TRAILER "$matched"
  return 0
}

wv_main() {
  wv_parse_stdin || return 0
  [ "$WV_EVENT" = "PreToolUse" ] || return 0
  [ "$WV_TOOL" = "Bash" ] || return 0

  # Only the main session is gated; a subagent's own commits are not judged
  # by this rule (spec section 8, applied consistently here too).
  [ -z "$WV_AGENT_ID" ] || return 0

  wv_project_root || return 0
  wv_state_read || return 0
  # No mode filter: this guard stays on in full, demo AND solo (AC-335).

  local cmd
  cmd="$(wv_json '.tool_input.command // empty')"
  [ -n "$cmd" ] || return 0

  [[ "$cmd" =~ $WV_PCG_COMMIT_RE ]] || return 0

  local cwd="${WV_CWD:-}"
  [ -n "$cwd" ] || cwd="$PWD"
  git -C "$cwd" rev-parse --show-toplevel >/dev/null 2>&1 || return 0

  local staged
  staged="$(git -C "$cwd" diff --cached --name-only 2>/dev/null)"

  wv_pcg_doc_check "$staged"
  # wv_deny's own WV_EMITTED guard makes the trailer check below a no-op if
  # the doc check just denied — one JSON object per invocation, first wins,
  # in the reasons.tsv precedence order (W-COMMIT-DOC before W-COMMIT-TRAILER).

  local scan_text="$cmd"
  case "$cmd" in
    *--amend*)
      case "$cmd" in
        *--no-edit*)
          local prev
          prev="$(git -C "$cwd" log -1 --format=%B 2>/dev/null)"
          if [ -n "$prev" ]; then
            scan_text="$scan_text
$prev"
          fi
          ;;
      esac
      ;;
  esac
  wv_pcg_trailer_check "$scan_text"

  return 0
}

wv_main
wv_emit_flush
exit 0
