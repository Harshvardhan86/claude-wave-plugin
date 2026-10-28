#!/usr/bin/env bash
# scripts/wave-init.sh — starts a wave: writes .wave/state.json (spec section
# 4), creates the .wave/ directory set and lock, appends .wave/ to
# .git/info/exclude (never .gitignore), and installs a repo-local
# .git/hooks/commit-msg guard when one is not already present.
#
# Usage:
#   wave-init.sh --wave <id> (--mode full|demo | --solo) [--ui|--no-ui]
#                [--cr|--no-cr] [--vocabulary|--no-vocabulary]
#                [--behaviour-change|--no-behaviour-change]
#                [--enforce block|warn] --feature <text> [--force]
#
#   <id> is 1-24 characters of [A-Za-z0-9._-]. It is bounded here because it is
#   interpolated into the dispatch tag and twice into the session banner, whose
#   rendered length is held at 400 characters (scripts/hooks/session-start.sh
#   derives its own budget from this bound).
#
# This is a lifecycle script, not a hook: it prints plain human-readable
# lines (never the hook JSON shapes in scripts/hooks/lib.sh), uses `set -u`
# (never `set -e`, Global Constraint 8), and exits non-zero on any rejected
# argument or on a pre-existing active wave without --force — writing
# nothing to disk in either case.
set -u

WV_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/hooks/lib.sh
source "$WV_SCRIPT_DIR/hooks/lib.sh"

wv_die() {
  printf 'wave-init.sh: %s\n' "$*" >&2
  exit 1
}

# ---------------------------------------------------------------------------
# 1. Argument parsing + validation. Nothing is written to disk until every
#    argument has been accepted (Steps 1-2 of the task brief).
# ---------------------------------------------------------------------------

wave_id=""
mode=""
solo=0
ui="unknown"
cr="unknown"
vocabulary="unknown"
behaviour_change="unknown"
enforce="block"
enforce_given=0
feature=""
force=0

while [ $# -gt 0 ]; do
  case "$1" in
    --wave)
      [ $# -ge 2 ] || wv_die "--wave requires a value"
      wave_id="$2"; shift 2 ;;
    --mode)
      [ $# -ge 2 ] || wv_die "--mode requires a value"
      mode="$2"; shift 2 ;;
    --solo)
      solo=1; shift ;;
    --ui)
      ui="true"; shift ;;
    --no-ui)
      ui="false"; shift ;;
    --cr)
      cr="true"; shift ;;
    --no-cr)
      cr="false"; shift ;;
    --vocabulary)
      vocabulary="true"; shift ;;
    --no-vocabulary)
      vocabulary="false"; shift ;;
    --behaviour-change)
      behaviour_change="true"; shift ;;
    --no-behaviour-change)
      behaviour_change="false"; shift ;;
    --enforce)
      [ $# -ge 2 ] || wv_die "--enforce requires a value"
      enforce="$2"; enforce_given=1; shift 2 ;;
    --feature)
      [ $# -ge 2 ] || wv_die "--feature requires a value"
      feature="$2"; shift 2 ;;
    --force)
      force=1; shift ;;
    *)
      wv_die "unknown argument: $1" ;;
  esac
done

if [ "$solo" = "1" ]; then
  mode="solo"
else
  case "$mode" in
    full|demo) : ;;
    "") wv_die "missing --mode (full|demo) or --solo" ;;
    *) wv_die "invalid --mode: '$mode' (want full or demo, or pass --solo)" ;;
  esac
fi

[ -n "$wave_id" ] || wv_die "missing --wave <id>"
# THE WAVE ID IS A BOUNDED FIELD, and this is the one place that can bound it.
#
# It is interpolated into the dispatch tag `[W:<id> P:… R:…]` and TWICE into the
# W-SESSION banner, whose rendered length tests/tools/reason-corpus.sh holds at 400
# characters. Rejecting only a space or a `]` left the length unbounded: a
# 40-character id rendered a 458-character banner, so the bound scripts/hooks/
# session-start.sh states held for the fixtures and not for real input. A render-time
# truncation would have to be repeated at every interpolation and would silently
# rename the wave in a message; a creation-time bound is one check, in front of one
# writer, with a person there to read the refusal.
#
# 24 characters is long enough for a date-stamped (`2026-09-10-hooks`) or
# ticket-shaped (`WAVE-1234.hotfix`) id and short enough that the banner's own
# character budget can be derived from it. The character class is what a value
# carried inside a bracketed tag, a filename glob, a jq string and a shell word can
# all hold without quoting games: no space, no `]`, no `/`, no `*`, no `$`.
case "$wave_id" in
  *[!A-Za-z0-9._-]*)
    wv_die "invalid --wave: '$wave_id' must use only letters, digits, '.', '_' and '-' — the id goes into the dispatch tag [W:<id> …], into a filename glob and into every hook's session banner" ;;
esac
if [ "${#wave_id}" -gt 24 ]; then
  wv_die "invalid --wave: '$wave_id' is ${#wave_id} characters; the limit is 24 because the id is interpolated twice into the session banner, whose rendered length is bounded at 400 characters"
fi

case "$enforce" in
  block|warn) : ;;
  *) wv_die "invalid --enforce: '$enforce' (want block or warn)" ;;
esac
[ "$enforce_given" = "1" ] || enforce="block"

[ -n "$feature" ] || wv_die "missing --feature <text>"

# ---------------------------------------------------------------------------
# 2. Project root. Unlike wv_project_root (scripts/hooks/lib.sh), which only
#    ever looks for an EXISTING .wave/state.json, wave-init.sh has to find a
#    root before any state exists: CLAUDE_PROJECT_DIR; else cwd with a
#    measured .claude/worktrees/<name> suffix stripped; else the git
#    toplevel; else cwd itself (spec section 4, first two clauses — the third
#    clause does not apply because there is nothing to find yet).
# ---------------------------------------------------------------------------

wv_resolve_new_root() {
  if [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ -d "$CLAUDE_PROJECT_DIR" ]; then
    realpath "$CLAUDE_PROJECT_DIR" 2>/dev/null && return 0
  fi
  local base
  base="$(realpath "$PWD" 2>/dev/null)" || return 1
  if [[ "$base" =~ ^(.+)/\.claude/worktrees/[^/]+$ ]]; then
    local stripped="${BASH_REMATCH[1]}"
    [ -d "$stripped" ] && base="$stripped"
  fi
  local top
  top="$(git -C "$base" rev-parse --show-toplevel 2>/dev/null)"
  if [ -n "$top" ]; then
    realpath "$top" 2>/dev/null && return 0
  fi
  printf '%s' "$base"
}

root="$(wv_resolve_new_root)"
[ -n "$root" ] || wv_die "could not resolve a project root from $PWD"

wave_dir="$root/.wave"
state_file="$wave_dir/state.json"

# ---------------------------------------------------------------------------
# 3. The lock, taken BEFORE the archive-or-refuse decision and held through
#    the final write (step 6). `.wave/lock` is never replaced across a
#    close/init cycle (scripts/hooks/lib.sh's header), so under --force this
#    is the SAME lock file a still-finishing subagent's locked
#    wv_state_update against the OLD wave may be holding; without taking it
#    here, that write can land after ours and clobber the new wave's state.
#    WV_WAVE_DIR / wv_lock_acquire / wv_lock_release are scripts/hooks/lib.sh's
#    (nested-safe); reused rather than re-implemented.
# ---------------------------------------------------------------------------

mkdir -p "$wave_dir"
WV_WAVE_DIR="$wave_dir"
[ -e "$wave_dir/lock" ] || : > "$wave_dir/lock"

wv_lock_acquire || wv_die "could not take the wave lock $wave_dir/lock within 10s; another process is still writing state — retry once it finishes"

# ---------------------------------------------------------------------------
# 4. A pre-existing state.json: archive a closed one, refuse an active one
#    unless --force, and archive whatever it was when replacing it. Held
#    under the lock acquired above, so the read of `.status` and the
#    subsequent archive/write cannot race a concurrent wv_state_update.
# ---------------------------------------------------------------------------

if [ -e "$state_file" ]; then
  prior_status="$(jq -r '.status // empty' "$state_file" 2>/dev/null)"
  prior_started="$(jq -r '.started // empty' "$state_file" 2>/dev/null)"
  if [ -z "$prior_status" ]; then
    wv_lock_release
    wv_die "$state_file exists and is not valid JSON; remove or repair it by hand before running wave-init.sh"
  fi
  if [ "$prior_status" = "active" ] && [ "$force" != "1" ]; then
    wv_lock_release
    wv_die "an active wave already exists at $state_file; run scripts/wave-close.sh first, or pass --force"
  fi
  mkdir -p "$wave_dir/archive"
  [ -n "$prior_started" ] || prior_started="unknown-$(date -u +%Y%m%dT%H%M%SZ)"
  archive_target="$wave_dir/archive/${prior_started}-state.json"
  mv -f "$state_file" "$archive_target"
  printf 'wave-init.sh: archived the prior %s state to %s\n' "$prior_status" "$archive_target" >&2
fi

# ---------------------------------------------------------------------------
# 5. The rest of the directory set (the lock already exists — step 3).
# ---------------------------------------------------------------------------

for d in approvals findings checkpoints screenshots reports archive; do
  mkdir -p "$wave_dir/$d"
done

# ---------------------------------------------------------------------------
# .git/info/exclude — never .gitignore. Idempotent: running this twice must
# leave exactly one `.wave/` line.
#
# Every `git rev-parse --git-path` result goes through wv_git_path_abs: git
# prints a path RELATIVE to the directory it ran in from the main worktree
# (`.git/info/exclude`) but an ABSOLUTE one from a linked worktree (the
# repository's common directory), so joining it onto $root unconditionally
# writes into a nested directory git never reads
# (tests/cases/init-linked-worktree.sh).
# ---------------------------------------------------------------------------

wv_git_path_abs() {
  # wv_git_path_abs <root> <git-path output> -> the path, absolute.
  case "$2" in
    /*) printf '%s' "$2" ;;
    *) printf '%s/%s' "$1" "$2" ;;
  esac
}

# A bare repository (no work tree) gets no exclude line either: nothing is
# ever committed there, and init writes nothing under its git directory
# (tests/cases/init-no-worktree.sh). A directory that is no repository at all
# has no --git-path, so it takes neither branch.
exclude_rel=""
if [ "$(git -C "$root" rev-parse --is-inside-work-tree 2>/dev/null)" = "true" ]; then
  exclude_rel="$(git -C "$root" rev-parse --git-path info/exclude 2>/dev/null)"
fi
if [ -n "$exclude_rel" ]; then
  exclude_file="$(wv_git_path_abs "$root" "$exclude_rel")"
  mkdir -p "$(dirname "$exclude_file")"
  [ -e "$exclude_file" ] || : > "$exclude_file"
  if ! command grep -qxF '.wave/' "$exclude_file" 2>/dev/null; then
    printf '%s\n' '.wave/' >> "$exclude_file"
    printf 'wave-init.sh: added .wave/ to %s\n' "$exclude_file" >&2
  fi
fi

# ---------------------------------------------------------------------------
# 6. The repo-local commit-msg guard. .git/ is Write-tool-protected, hence a
#    heredoc written by this already-running bash process rather than by an
#    editor. Never overwrites a foreign hook (spec section 10 / AC-314).
#
#    THE TEMPLATE IS VERSIONED. Its second line is the owned marker
#    `# wave-orchestrator-owned commit-msg hook; template <N>`. A hook that
#    carries that exact line was written by this script and is regenerated to
#    the current template (state "upgraded" when its bytes change, "installed"
#    when it was already current), so a repository initialised by an older
#    release receives the current WV_TRAILER_ERE. The hook 0.2.0 and 0.2.1
#    installed predates the marker; it is recognised by its FULL CONTENT
#    (wv_released_commit_msg_hook, compared byte for byte, never by a name
#    mention) and, only while unmodified, upgraded the same way. Those bytes
#    are an inert data file shipped with the plugin,
#    hooks/released/commit-msg-0.2.1.hook (never executed, never sourced),
#    pinned to the release by tests/cases/commitmsg-released-data-pin.sh; a
#    plugin tree without it treats every unmarked hook as foreign. Any other
#    existing hook is foreign and left byte-identical ("skipped-existing"),
#    including that released template with any local change; the notice says
#    how to refresh it (tests/cases/commitmsg-owned-hook-upgrade.sh). A write
#    that fails at any step, or renders bytes that differ from the template,
#    records "install-failed", never "installed"
#    (tests/cases/init-hook-install-failed.sh,
#    tests/cases/init-hook-render-fault.sh). Edits to
#    an owned hook are not kept: delete its marker line to keep a customised
#    hook.
# ---------------------------------------------------------------------------

WV_COMMIT_MSG_TEMPLATE=2
WV_COMMIT_MSG_MARKER_ERE='^# wave-orchestrator-owned commit-msg hook; template [0-9]+$'

WV_RELEASED_COMMIT_MSG_HOOK="$WV_SCRIPT_DIR/../hooks/released/commit-msg-0.2.1.hook"

wv_released_commit_msg_hook() {
  # The exact bytes the 0.2.0 and 0.2.1 wave-init.sh wrote (one unmarked
  # template, identical in both releases), read as data: a hook equal to this
  # is one this script installed and nobody has changed since. The caller
  # checks the file is present first; an absent file matches nothing.
  cat -- "$WV_RELEASED_COMMIT_MSG_HOOK" 2>/dev/null
}

wv_commit_msg_hook_render() {
  # The current owned template on stdout. EVERY COMMAND'S STATUS PROPAGATES:
  # the template is written by several commands, and a function's status is
  # only its last command's, so without `|| return 1` on each an early one
  # that fails is masked by a later one that succeeds and a hook missing its
  # head reads as written (tests/cases/init-hook-render-fault.sh). Callers
  # never trust this status alone: wv_render_checked also compares the bytes
  # against an independently rendered reference.
  printf '#!/usr/bin/env bash\n' || return 1
  printf '# wave-orchestrator-owned commit-msg hook; template %s\n' "$WV_COMMIT_MSG_TEMPLATE" || return 1
  cat <<'WV_COMMIT_MSG_HOOK_HEAD' || return 1
# Installed by wave-init.sh. Refuses a commit message
# that carries an AI-attribution trailer. Uses `command grep`, never a bare
# `grep` (Global Constraint 7): a wrapped searcher can decline the message
# file and print nothing where real grep prints 0, which must never read as
# "no trailer found". wave-init.sh regenerates this file while the line
# above is present; delete that line to keep local edits.
set -u
msg_file="${1:-}"
[ -n "$msg_file" ] && [ -r "$msg_file" ] || exit 0
WV_COMMIT_MSG_HOOK_HEAD
  # The pattern is the shared WV_TRAILER_ERE from lib.sh, baked in verbatim.
  printf "pattern='%s'\n" "$WV_TRAILER_ERE" || return 1
  cat <<'WV_COMMIT_MSG_HOOK_TAIL' || return 1
offending="$(command grep -nE "$pattern" -- "$msg_file" 2>/dev/null)"
if [ -n "$offending" ]; then
  printf 'commit-msg: this message carries an AI-attribution trailer, which is not allowed:\n%s\n' "$offending" >&2
  exit 1
fi
exit 0
WV_COMMIT_MSG_HOOK_TAIL
  return 0
}

wv_render_fail=""
wv_render_ref=""

wv_render_checked() {
  # wv_render_checked <file> — render the template into <file> and VERIFY it:
  # every render command succeeded, the bytes equal a second, independent
  # render into a reference file in .wave/ (cmp), and the result passes
  # `bash -n`. On success the reference stays at $wv_render_ref so the caller
  # can compare the file once more after moving it into place; the caller
  # removes it (wv_render_ref_drop). On failure returns 1 with
  # $wv_render_fail naming the step that failed, and no reference is kept.
  local f="$1"
  wv_render_fail=""
  wv_render_ref_drop
  if ! wv_commit_msg_hook_render > "$f" 2>/dev/null; then
    wv_render_fail="cannot write $f"
    return 1
  fi
  if ! wv_render_ref="$(mktemp "$wave_dir/.commit-msg-ref.XXXXXX" 2>/dev/null)" || [ -z "$wv_render_ref" ]; then
    wv_render_ref=""
    wv_render_fail="cannot create a reference copy of the template in $wave_dir"
    return 1
  fi
  if ! wv_commit_msg_hook_render > "$wv_render_ref" 2>/dev/null; then
    wv_render_fail="cannot write the reference copy of the template $wv_render_ref"
    wv_render_ref_drop
    return 1
  fi
  if ! cmp -s -- "$f" "$wv_render_ref"; then
    wv_render_fail="the template rendered into $f differs from an independently rendered reference copy"
    wv_render_ref_drop
    return 1
  fi
  if ! bash -n "$f" 2>/dev/null; then
    wv_render_fail="the template rendered into $f fails a bash syntax check"
    wv_render_ref_drop
    return 1
  fi
  return 0
}

wv_render_ref_drop() {
  [ -n "$wv_render_ref" ] && rm -f "$wv_render_ref" 2>/dev/null
  wv_render_ref=""
  return 0
}

wv_sh_quote() {
  # One POSIX-shell word for $1, single-quoted (an embedded ' becomes '\''),
  # so a printed command stays one argument in sh and bash alike, whatever
  # the path holds (tests/cases/init-hookspath-remedy.sh).
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

wv_render_wave_check() {
  # Render the current check to .wave/hooks/commit-msg for a project hook
  # manager to call, verified the way the hook itself is (wv_render_checked,
  # then chmod, mv and a comparison of the moved file against the reference).
  # Sets wave_check; returns non-zero, with $wave_check_fail naming the step,
  # when it could not be written whole, verified and executable; a check that
  # failed verification after the move is removed, never left in place.
  local tmp=""
  wave_check="$wave_dir/hooks/commit-msg"
  wave_check_fail=""
  if ! mkdir -p "$wave_dir/hooks" 2>/dev/null; then
    wave_check_fail="cannot create $wave_dir/hooks"
  elif ! tmp="$(mktemp "$wave_dir/hooks/.commit-msg.XXXXXX" 2>/dev/null)" || [ -z "$tmp" ]; then
    tmp=""
    wave_check_fail="cannot create a file in $wave_dir/hooks"
  elif ! wv_render_checked "$tmp"; then
    wave_check_fail="$wv_render_fail"
  elif ! chmod +x "$tmp" 2>/dev/null; then
    wave_check_fail="cannot make $tmp executable"
  elif ! mv -f "$tmp" "$wave_check" 2>/dev/null; then
    wave_check_fail="cannot move the check into place at $wave_check"
  else
    tmp=""
    if ! cmp -s -- "$wave_check" "$wv_render_ref"; then
      wave_check_fail="$wave_check differs from the reference copy after the move (removed)"
      rm -f "$wave_check" 2>/dev/null
    fi
  fi
  [ -n "$tmp" ] && rm -f "$tmp" 2>/dev/null
  wv_render_ref_drop
  [ -z "$wave_check_fail" ]
}

wv_wave_check_remedy() {
  # The notice for a guard that is not installed; $1 is the reason, $2 what
  # the remedy asks for before the command (the check path is shell-quoted).
  # Sets commit_msg_check: "written" (verified) or "failed" (recorded in the
  # state, so a failed fallback is not only a line of stderr).
  if wv_render_wave_check; then
    commit_msg_check="written"
    printf 'wave-init.sh: %s, so the commit-msg guard is not installed. The PreToolUse(Bash) commit guard still refuses a trailer line in this session. remedy: %s: bash %s "$1"\n' "$1" "$2" "$(wv_sh_quote "$wave_check")" >&2
  else
    commit_msg_check="failed"
    printf 'wave-init.sh: %s, so the commit-msg guard is not installed, and the fallback check %s could not be written and verified either (%s). The PreToolUse(Bash) commit guard still refuses a trailer line in this session; fix the cause and run scripts/wave-init.sh again\n' "$1" "$wave_check" "$wave_check_fail" >&2
  fi
}

# A project that manages its hooks with core.hooksPath (any scope git reads:
# system, global, local, worktree) keeps that directory to itself: nothing is
# written there, nor into .git/hooks. The current check is rendered into
# .wave/hooks/commit-msg instead so the project's hook manager can call it
# (tests/cases/init-hookspath.sh); the PreToolUse(Bash) commit guard enforces
# regardless. "Configured" is the EXIT STATUS of `git config --get`, never the
# length of its value: an empty core.hooksPath is still read by git (it
# resolves the hook to /commit-msg), so it takes this path too.
#
# A project that is not a git repository, or is a bare one (no work tree, so no
# commit is made there and a hook would never run), gets no hook at all and the
# state records "not-a-repo" (tests/cases/init-no-worktree.sh): a state never
# claims an install that did not happen.
commit_msg_hook="installed"
commit_msg_check="none"
hook_rel=""
hooks_path_cfg="$(git -C "$root" config --get core.hooksPath 2>/dev/null)"
hooks_path_rc=$?
if [ "$(git -C "$root" rev-parse --is-inside-work-tree 2>/dev/null)" != "true" ]; then
  commit_msg_hook="not-a-repo"
  printf 'wave-init.sh: the commit-msg guard was not installed because there is no work-tree repository here. The PreToolUse(Bash) commit guard still refuses a trailer line in this session\n' >&2
elif [ "$hooks_path_rc" = "0" ]; then
  commit_msg_hook="skipped-hookspath"
  wv_wave_check_remedy "the project sets core.hooksPath = $(wv_sh_quote "$hooks_path_cfg"); git runs hooks only from that directory, and it belongs to the project" \
    "call the wave's commit-msg check from the project's own commit-msg hook"
else
  hook_rel="$(git -C "$root" rev-parse --git-path hooks/commit-msg 2>/dev/null)"
fi
if [ -n "$hook_rel" ]; then
  hook_file="$(wv_git_path_abs "$root" "$hook_rel")"
  hook_owned=0
  released_present=0
  [ -f "$WV_RELEASED_COMMIT_MSG_HOOK" ] && [ -s "$WV_RELEASED_COMMIT_MSG_HOOK" ] && released_present=1
  if [ -e "$hook_file" ] && command grep -qE "$WV_COMMIT_MSG_MARKER_ERE" "$hook_file" 2>/dev/null; then
    hook_owned=1
  elif [ -f "$hook_file" ] && [ "$released_present" = "1" ] && wv_released_commit_msg_hook | cmp -s - "$hook_file"; then
    hook_owned=1 # the unmodified released template
  fi
  if [ -e "$hook_file" ] && [ "$hook_owned" = "0" ] && [ "$released_present" = "0" ]; then
    printf 'wave-init.sh: the released-hook data file %s is missing, so an unmarked %s cannot be recognised as an earlier install and is treated as foreign; reinstall the plugin to restore it\n' "$WV_RELEASED_COMMIT_MSG_HOOK" "$hook_file" >&2
  fi
  if [ -e "$hook_file" ] && [ "$hook_owned" = "0" ]; then
    commit_msg_hook="skipped-existing"
    printf 'wave-init.sh: %s already exists and was left untouched; the PreToolUse(Bash) fast path remains the only guard for that hook chain. If it is a hook an earlier wave-init.sh installed (its second line reads "# Installed by wave-init.sh") and later changed by hand, which is why it was not upgraded, remove it and the next scripts/wave-init.sh installs the current guard\n' "$hook_file" >&2
  else
    # EVERY STEP IS CHECKED, AND SO ARE THE BYTES. "installed" / "upgraded" is
    # printed and recorded only when the file now at the hook path is
    # byte-identical to the intended template: rendered into a temp file with
    # every command's status checked, compared with an independently rendered
    # reference and syntax-checked (wv_render_checked), made executable, moved
    # into place, then compared with the reference once more. The first
    # failure records "install-failed", names the failed step and renders the
    # fallback check, itself verified the same way
    # (tests/cases/init-hook-install-failed.sh,
    # tests/cases/init-hook-render-fault.sh). An owned hook that is already
    # current is compared against a verified render kept in .wave/, without a
    # temp file in the hooks directory, so a read-only hooks directory does not
    # turn a current hook into a failure.
    hook_dir="$(dirname "$hook_file")"
    hook_tmp=""
    hook_fail=""
    hook_changed=1
    hook_cur=""
    if [ "$hook_owned" = "1" ]; then
      if ! hook_cur="$(mktemp "$wave_dir/.commit-msg-cur.XXXXXX" 2>/dev/null)" || [ -z "$hook_cur" ]; then
        hook_cur=""
        hook_fail="cannot create a file in $wave_dir to compare the existing hook with"
      elif ! wv_render_checked "$hook_cur"; then
        hook_fail="$wv_render_fail"
      elif cmp -s -- "$hook_cur" "$hook_file"; then
        chmod +x "$hook_file" 2>/dev/null || hook_fail="cannot make $hook_file executable"
        hook_changed=0
      fi
      wv_render_ref_drop
      [ -n "$hook_cur" ] && rm -f "$hook_cur" 2>/dev/null
    fi
    if [ -z "$hook_fail" ] && [ "$hook_changed" = "1" ]; then
      if ! mkdir -p "$hook_dir" 2>/dev/null; then
        hook_fail="cannot create the hooks directory $hook_dir"
      elif ! hook_tmp="$(mktemp "$hook_dir/.commit-msg.XXXXXX" 2>/dev/null)" || [ -z "$hook_tmp" ]; then
        hook_tmp=""
        hook_fail="cannot create a file in the hooks directory $hook_dir"
      elif ! wv_render_checked "$hook_tmp"; then
        hook_fail="$wv_render_fail"
      elif ! chmod +x "$hook_tmp" 2>/dev/null; then
        hook_fail="cannot make $hook_tmp executable"
      elif ! mv -f "$hook_tmp" "$hook_file" 2>/dev/null; then
        hook_fail="cannot move the new hook into place at $hook_file"
      else
        hook_tmp=""
        if ! cmp -s -- "$hook_file" "$wv_render_ref"; then
          hook_fail="$hook_file differs from the reference copy of the template after the move (removed)"
          rm -f "$hook_file" 2>/dev/null
        fi
      fi
      [ -n "$hook_tmp" ] && rm -f "$hook_tmp" 2>/dev/null
      wv_render_ref_drop
    fi
    if [ -n "$hook_fail" ]; then
      commit_msg_hook="install-failed"
      wv_wave_check_remedy "$hook_fail" \
        "fix the cause and run scripts/wave-init.sh again, or call the wave's commit-msg check from a commit-msg hook git runs"
    elif [ "$hook_changed" = "1" ]; then
      if [ "$hook_owned" = "1" ]; then
        commit_msg_hook="upgraded"
        printf 'wave-init.sh: upgraded %s to commit-msg template %s\n' "$hook_file" "$WV_COMMIT_MSG_TEMPLATE" >&2
      else
        printf 'wave-init.sh: installed %s\n' "$hook_file" >&2
      fi
    fi
  fi
fi

# ---------------------------------------------------------------------------
# 7. Write the whole state.json in one shot (spec section 4), still under the
#    lock taken in step 3.
# ---------------------------------------------------------------------------

started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
base_sha="$(git -C "$root" rev-parse HEAD 2>/dev/null)"
# The plugin release creating this wave, read as data from the manifest. An
# additive field (schema stays 1): a state without it was created before
# 0.3.0. A later release keys row exemptions on it (lib.sh wv_row_superseded),
# so nothing but this script writes it and scripts/wave-set.sh refuses the key.
created_by="$(jq -r '.version // empty' "$WV_SCRIPT_DIR/../.claude-plugin/plugin.json" 2>/dev/null)"
case "$created_by" in
  [0-9]*.[0-9]*.[0-9]*) case "$created_by" in *[!A-Za-z0-9.+-]*) created_by="unknown" ;; esac ;;
  *) created_by="unknown" ;;
esac

state_tmp="$(mktemp "$wave_dir/.state-init.XXXXXX")"
if ! jq -n \
  --arg wave "$wave_id" \
  --arg mode "$mode" \
  --argjson ui "$([ "$ui" = "unknown" ] && printf '"unknown"' || printf '%s' "$ui")" \
  --argjson cr "$([ "$cr" = "unknown" ] && printf '"unknown"' || printf '%s' "$cr")" \
  --argjson vocabulary "$([ "$vocabulary" = "unknown" ] && printf '"unknown"' || printf '%s' "$vocabulary")" \
  --argjson bc "$([ "$behaviour_change" = "unknown" ] && printf '"unknown"' || printf '%s' "$behaviour_change")" \
  --arg enforce "$enforce" \
  --arg feature "$feature" \
  --arg started "$started" \
  --arg base_sha "$base_sha" \
  --arg commit_msg_hook "$commit_msg_hook" \
  --arg commit_msg_check "$commit_msg_check" \
  --arg created_by "$created_by" \
  '{
    schema: 1,
    wave: $wave,
    mode: $mode,
    status: "active",
    ui: $ui,
    behaviour_change: $bc,
    cr_enabled: $cr,
    vocabulary: $vocabulary,
    enforce: $enforce,
    feature: $feature,
    started: $started,
    ended: null,
    base_sha: $base_sha,
    phases: {},
    active: {},
    pending: {},
    rounds: {},
    commit_msg_hook: $commit_msg_hook,
    commit_msg_check: $commit_msg_check,
    created_by: $created_by
  }' > "$state_tmp"
then
  rm -f "$state_tmp"
  wv_lock_release
  wv_die "could not build $state_file (jq failed)"
fi
# The once-per-wave close-time markers (scripts/hooks/lib.sh wv_close_announce,
# scripts/hooks/subagent-stop.sh) live in this project's one .wave/ directory, so
# they belong to the wave being replaced. Removed here, after the new state was
# built and before it is installed, still under the lock: a refused init (any
# wv_die above) leaves them in place, and a new wave starts with none, so its
# verdict, scorecard pointer and leftover warning are announced again
# (tests/cases/init-two-wave-markers.sh).
rm -f "$wave_dir/.undelivered-warned" "$wave_dir/.scorecard-printed" "$wave_dir/.leftover-warned"
mv -f "$state_tmp" "$state_file"
# Every scope answer given here is recorded the way scripts/wave-set.sh records
# one (`<ts> <key>=<value>`, with wave-set.sh's key), so .wave/approvals/scope.md
# holds the answers /wave-start passes as flags too. "unknown" was not given.
for wv_pair in "ui=$ui" "cr=$cr" "vocabulary=$vocabulary" "behaviour-change=$behaviour_change"; do
  [ "${wv_pair#*=}" = "unknown" ] && continue
  printf '%s %s\n' "$started" "$wv_pair" >> "$wave_dir/approvals/scope.md"
done
wv_lock_release

printf 'wave-init.sh: wave %s started in %s mode at %s\n' "$wave_id" "$mode" "$state_file"
exit 0
