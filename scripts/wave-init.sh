#!/usr/bin/env bash
# scripts/wave-init.sh — starts a wave: writes .wave/state.json (spec section
# 4), creates the .wave/ directory set and lock, appends .wave/ to
# .git/info/exclude (never .gitignore), and installs a repo-local
# .git/hooks/commit-msg guard when one is not already present.
#
# Usage:
#   wave-init.sh --wave <id> (--mode full|demo | --solo) [--ui|--no-ui]
#                [--cr|--no-cr] [--enforce block|warn] --feature <text> [--force]
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
case "$wave_id" in
  *' '*|*']'*)
    wv_die "invalid --wave: '$wave_id' contains a space or ']', which would make the dispatch tag ungrammatical" ;;
esac

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
# 3. A pre-existing state.json: archive a closed one, refuse an active one
#    unless --force, and archive whatever it was when replacing it.
# ---------------------------------------------------------------------------

if [ -e "$state_file" ]; then
  prior_status="$(jq -r '.status // empty' "$state_file" 2>/dev/null)"
  prior_started="$(jq -r '.started // empty' "$state_file" 2>/dev/null)"
  if [ -z "$prior_status" ]; then
    wv_die "$state_file exists and is not valid JSON; remove or repair it by hand before running wave-init.sh"
  fi
  if [ "$prior_status" = "active" ] && [ "$force" != "1" ]; then
    wv_die "an active wave already exists at $state_file; run scripts/wave-close.sh first, or pass --force"
  fi
  mkdir -p "$wave_dir/archive"
  [ -n "$prior_started" ] || prior_started="unknown-$(date -u +%Y%m%dT%H%M%SZ)"
  archive_target="$wave_dir/archive/${prior_started}-state.json"
  mv -f "$state_file" "$archive_target"
  printf 'wave-init.sh: archived the prior %s state to %s\n' "$prior_status" "$archive_target" >&2
fi

# ---------------------------------------------------------------------------
# 4. The directory set + the lock.
# ---------------------------------------------------------------------------

for d in approvals findings checkpoints screenshots reports archive; do
  mkdir -p "$wave_dir/$d"
done
[ -e "$wave_dir/lock" ] || : > "$wave_dir/lock"

# ---------------------------------------------------------------------------
# .git/info/exclude — never .gitignore. Idempotent: running this twice must
# leave exactly one `.wave/` line.
# ---------------------------------------------------------------------------

exclude_rel="$(git -C "$root" rev-parse --git-path info/exclude 2>/dev/null)"
if [ -n "$exclude_rel" ]; then
  exclude_file="$root/$exclude_rel"
  mkdir -p "$(dirname "$exclude_file")"
  [ -e "$exclude_file" ] || : > "$exclude_file"
  if ! command grep -qxF '.wave/' "$exclude_file" 2>/dev/null; then
    printf '%s\n' '.wave/' >> "$exclude_file"
    printf 'wave-init.sh: added .wave/ to %s\n' "$exclude_file" >&2
  fi
fi

# ---------------------------------------------------------------------------
# 5. The repo-local commit-msg guard. .git/ is Write-tool-protected, hence a
#    heredoc written by this already-running bash process rather than by an
#    editor. Never overwrites a foreign hook (spec section 10 / AC-314).
# ---------------------------------------------------------------------------

commit_msg_hook="installed"
hook_rel="$(git -C "$root" rev-parse --git-path hooks/commit-msg 2>/dev/null)"
if [ -n "$hook_rel" ]; then
  hook_file="$root/$hook_rel"
  if [ -e "$hook_file" ]; then
    commit_msg_hook="skipped-existing"
    printf 'wave-init.sh: %s already exists and was left untouched; the PreToolUse(Bash) fast path remains the only guard for that hook chain\n' "$hook_file" >&2
  else
    mkdir -p "$(dirname "$hook_file")"
    hook_tmp="$(mktemp "$(dirname "$hook_file")/.commit-msg.XXXXXX")"
    cat > "$hook_tmp" <<'WV_COMMIT_MSG_HOOK'
#!/usr/bin/env bash
# Installed by wave-init.sh (claude-wave-plugin). Refuses a commit message
# that carries an AI-attribution trailer. Uses `command grep`, never a bare
# `grep` (Global Constraint 7): a wrapped searcher can decline the message
# file and print nothing where real grep prints 0, which must never read as
# "no trailer found".
set -u
msg_file="${1:-}"
[ -n "$msg_file" ] && [ -r "$msg_file" ] || exit 0
pattern='Co-Authored-By:.*(Claude|Anthropic)|Generated with.*Claude Code|claude\.ai/code/session'
offending="$(command grep -nE "$pattern" -- "$msg_file" 2>/dev/null)"
if [ -n "$offending" ]; then
  printf 'commit-msg: this message carries an AI-attribution trailer, which is not allowed:\n%s\n' "$offending" >&2
  exit 1
fi
exit 0
WV_COMMIT_MSG_HOOK
    mv -f "$hook_tmp" "$hook_file"
    chmod +x "$hook_file"
    printf 'wave-init.sh: installed %s\n' "$hook_file" >&2
  fi
fi

# ---------------------------------------------------------------------------
# 6. Write the whole state.json in one shot (spec section 4).
# ---------------------------------------------------------------------------

started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
base_sha="$(git -C "$root" rev-parse HEAD 2>/dev/null)"

state_tmp="$(mktemp "$wave_dir/.state-init.XXXXXX")"
if ! jq -n \
  --arg wave "$wave_id" \
  --arg mode "$mode" \
  --argjson ui "$([ "$ui" = "unknown" ] && printf '"unknown"' || printf '%s' "$ui")" \
  --argjson cr "$([ "$cr" = "unknown" ] && printf '"unknown"' || printf '%s' "$cr")" \
  --arg enforce "$enforce" \
  --arg feature "$feature" \
  --arg started "$started" \
  --arg base_sha "$base_sha" \
  --arg commit_msg_hook "$commit_msg_hook" \
  '{
    schema: 1,
    wave: $wave,
    mode: $mode,
    status: "active",
    ui: $ui,
    behaviour_change: "unknown",
    cr_enabled: $cr,
    enforce: $enforce,
    feature: $feature,
    started: $started,
    ended: null,
    base_sha: $base_sha,
    phases: {},
    active: {},
    pending: {},
    rounds: {},
    commit_msg_hook: $commit_msg_hook
  }' > "$state_tmp"
then
  rm -f "$state_tmp"
  wv_die "could not build $state_file (jq failed)"
fi
mv -f "$state_tmp" "$state_file"

printf 'wave-init.sh: wave %s started in %s mode at %s\n' "$wave_id" "$mode" "$state_file"
exit 0
