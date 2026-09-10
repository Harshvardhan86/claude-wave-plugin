#!/usr/bin/env bash
# scripts/hooks/lib.sh — the shared library every wave hook script sources.
#
# Responsibilities: parse the hook's stdin, resolve the project root, read and
# update `.wave/state.json` under a lock, map a model string to a tier, and
# emit the deny / warn / block shapes the client understands.
#
# Non-negotiable properties, all of them load-bearing:
#
#   * Exactly ONE JSON object reaches stdout per invocation. A hook evaluates
#     many rules in one call, so the first emitter wins and every later one is
#     refused: two objects mean the client parses one and silently loses the
#     other. Warnings queued before that object ride on it as
#     `additionalContext`; warnings queued after it are dropped, because the
#     event has no second channel.
#   * `set -u`, and NEVER errexit (`-e`) or `-o pipefail`. A hook must not fail
#     closed on its own bug; every path returns a status the caller can ignore.
#   * `jq` or `flock` missing -> exactly one stderr line and `exit 0`. A hook
#     that cannot read its input has measured nothing.
#   * No deny, block or rule warning is emitted unless `WV_PARSED=1` (stdin was
#     really parsed). Everything except the `W-STATE` channel additionally
#     needs `WV_STATE_OK=1`, because `W-STATE` is how "I could not measure the
#     state" is reported.
#   * State writes take `flock -w 10` on the dedicated `.wave/lock` file, held
#     across the whole read-modify-write *including* the rename. Locking
#     `state.json` itself would lose updates silently: `tmp && mv` replaces the
#     locked inode, so a concurrent holder would be locking a file that is no
#     longer the state file.
#   * Every gating scan goes through `command grep` (a wrapped searcher can
#     decline a file and print nothing where real grep prints `0`), and an
#     absent count is a FAILED scan, never a clean zero.
#
# Rule reasons are rendered from `hooks/reasons.tsv` (one printf template per
# rule id). Until that file exists, a built-in fallback renders
# `[<id>] <detail>; remedy: …`, which keeps the shape every reason must have:
# the `[<id>] ` prefix, exactly one `W-` token, and a remedy clause.

set -u

# ---------------------------------------------------------------------------
# 0. Tool guard. Runs FIRST and uses only shell builtins, so a stripped PATH
#    produces exactly one line of stderr and nothing else.
# ---------------------------------------------------------------------------

wv_stderr() { printf 'wave-plugin: %s\n' "$*" >&2; }

for wv_required_tool in jq flock; do
  if ! command -v "$wv_required_tool" >/dev/null 2>&1; then
    wv_stderr "$wv_required_tool was not found on PATH; wave enforcement is disabled for this call."
    exit 0
  fi
done
unset wv_required_tool

# ---------------------------------------------------------------------------
# 1. Where our own data files live. Derived from this file's path (builtins
#    only), because that is true by construction; CLAUDE_PLUGIN_ROOT is only a
#    fallback for an unusual install layout.
# ---------------------------------------------------------------------------

WV_HOOKS_DIR="$(cd "${BASH_SOURCE[0]%/*}" 2>/dev/null && pwd)"
WV_PLUGIN_DIR="$(cd "$WV_HOOKS_DIR/../.." 2>/dev/null && pwd)"
if [ ! -d "$WV_PLUGIN_DIR/hooks" ] && [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -d "$CLAUDE_PLUGIN_ROOT/hooks" ]; then
  WV_PLUGIN_DIR="$CLAUDE_PLUGIN_ROOT"
fi
WV_REASONS_TSV="$WV_PLUGIN_DIR/hooks/reasons.tsv"
WV_MODELS_TSV="$WV_PLUGIN_DIR/hooks/models.tsv"
WV_PHASES_TSV="$WV_PLUGIN_DIR/hooks/phases.tsv"

# ---------------------------------------------------------------------------
# 2. Every variable this library exports, initialised before anything reads it.
# ---------------------------------------------------------------------------

WV_JSON=""          # raw stdin
WV_EVENT=""         # hook_event_name
WV_TOOL=""          # tool_name
WV_AGENT_ID=""      # agent_id (present only inside a subagent)
WV_CWD=""           # cwd as the client sent it
WV_PARSED=0         # the positive parse marker every deny path checks

WV_ROOT=""          # resolved project root
WV_WAVE_DIR=""      # resolved <root>/.wave
WV_STATE_FILE=""    # resolved <root>/.wave/state.json

WV_STATE=""         # raw state.json contents
WV_MODE=""
WV_STATUS=""
WV_ENFORCE="block"  # block is the default and the safe fallback
WV_WAVE=""
WV_UI=""
WV_BC=""            # behaviour_change
WV_CR=""            # cr_enabled
WV_STATE_OK=0

WV_EMITTED=0        # 1 once one JSON object has been written to stdout
WV_WARNINGS=""      # rendered warnings, newline separated, flushed once
WV_PHASE="${WV_PHASE:-}"   # set by the calling hook when it knows the phase
WV_SCHEMA_MAX=1

# ---------------------------------------------------------------------------
# 3. Reason rendering.
# ---------------------------------------------------------------------------

wv_specifier_count() {
  # wv_specifier_count <printf template> -> how many conversion specifiers it
  # consumes. `%%` is a literal percent and consumes nothing; no shipped template
  # uses one, and this counts correctly if one ever does.
  local t="${1:-}"
  t="${t//%%/}"
  local n=0
  while [ -n "$t" ]; do
    case "$t" in
      *%*)
        t="${t#*%}"
        # Skip flags, width and precision, then the conversion letter.
        while [ -n "$t" ]; do
          case "$t" in
            [-\#0\ +.0-9]*) t="${t#?}" ;;
            *) break ;;
          esac
        done
        case "$t" in
          [a-zA-Z]*) n=$((n + 1)); t="${t#?}" ;;
        esac
        ;;
      *) break ;;
    esac
  done
  printf '%s' "$n"
}

wv_render() {
  # wv_render <rule-id> [args...] -> the rendered reason on stdout.
  local rule="$1"
  shift
  local tmpl="" id precedence text   # precedence is column 2; read to reach column 3
  if [ -f "$WV_REASONS_TSV" ]; then
    while IFS=$'\t' read -r id precedence text; do
      case "$id" in ''|'#'*|rule_id) continue ;; esac
      if [ "$id" = "$rule" ]; then
        tmpl="$text"
        break
      fi
    done < "$WV_REASONS_TSV"
  fi
  local out=""
  if [ -n "$tmpl" ]; then
    # THE ARGUMENT COUNT IS FORCED TO MATCH THE TEMPLATE, and this is not
    # defensive tidiness. `printf` REUSES its format string whenever it is given
    # more arguments than the format consumes, so ONE surplus argument does not
    # get dropped: the whole reason renders a second time, and the result carries
    # TWO `W-` tokens. Every consumer of a reason reads the rule off
    # `W-[A-Z0-9-]+` (the harness's assert_single_rule_token, the operator, the
    # scorecard), so it would read the wrong rule off a doubled reason, and the
    # doubling would look like a rendering quirk rather than the arity bug it is.
    #
    # Surplus arguments are therefore DISCARDED and missing ones rendered empty:
    # a reason that is short a fact is a poor message, a reason that names two
    # rules is a wrong one. The arity itself is checked statically, at every call
    # site, by tests/tools/reason-corpus.sh — this guard is what stops a call site
    # nobody has run yet from corrupting a reason in production, not a licence to
    # let one exist.
    local want args_seen=0 arg
    want="$(wv_specifier_count "$tmpl")"
    local -a rargs=()
    for arg in "$@"; do
      [ "$args_seen" -lt "$want" ] || break
      rargs+=("$arg")
      args_seen=$((args_seen + 1))
    done
    while [ "$args_seen" -lt "$want" ]; do
      rargs+=("")
      args_seen=$((args_seen + 1))
    done
    # shellcheck disable=SC2059  # the template IS the format string (data over code)
    out="$(printf "$tmpl" "${rargs[@]+"${rargs[@]}"}" 2>/dev/null)"
  fi
  if [ -z "$out" ]; then
    local detail="$*"
    [ -n "$detail" ] || detail="the rule fired"
    out="$(printf '[%s] %s; remedy: see hooks/reasons.tsv, which has no template for this rule yet.' \
      "$rule" "$detail")"
  fi
  printf '%s' "$out"
}

# ---------------------------------------------------------------------------
# 4. stdin.
# ---------------------------------------------------------------------------

wv_parse_stdin() {
  # Reads the whole of stdin. Sets WV_JSON / WV_EVENT / WV_TOOL / WV_AGENT_ID /
  # WV_CWD and WV_PARSED=1. Returns 1 (fail open, one stderr line) when stdin
  # is empty or is not a JSON object.
  WV_PARSED=0
  WV_JSON=""
  WV_EVENT=""
  WV_TOOL=""
  WV_AGENT_ID=""
  WV_CWD=""

  local raw
  raw="$(cat)"
  if [ -z "$raw" ]; then
    wv_stderr "hook stdin was empty; nothing was measured, allowing."
    return 1
  fi
  # The fields are joined with US (0x1f), never a tab: tab is IFS whitespace,
  # so `IFS=$'\t' read` collapses two adjacent tabs into one delimiter and an
  # absent agent_id would silently shift cwd into it.
  local fields
  fields="$(printf '%s' "$raw" | jq -r '
      if type == "object" then
        [ (.hook_event_name // ""), (.tool_name // ""), (.agent_id // ""), (.cwd // "") ]
        | join("\u001f")
      else
        empty
      end' 2>/dev/null)"
  if [ -z "$fields" ]; then
    wv_stderr "hook stdin was not a JSON object; nothing was measured, allowing."
    return 1
  fi
  IFS=$'\x1f' read -r WV_EVENT WV_TOOL WV_AGENT_ID WV_CWD <<<"$fields"
  WV_JSON="$raw"
  WV_PARSED=1
  return 0
}

wv_json() {
  # wv_json '<jq filter>' -> the filter applied to the parsed stdin, raw.
  [ -n "$WV_JSON" ] || return 1
  printf '%s' "$WV_JSON" | jq -r "$1" 2>/dev/null
}

# ---------------------------------------------------------------------------
# 5. Project root.
# ---------------------------------------------------------------------------

wv_inside_root() {
  # wv_inside_root <resolved-path> — true when it is under WV_ROOT.
  [ -n "$WV_ROOT" ] || return 1
  case "$1" in
    "$WV_ROOT"/*) return 0 ;;
    *) return 1 ;;
  esac
}

wv_resolve_input_path() {
  # wv_resolve_input_path <raw> -> the canonicalised absolute path on stdout.
  # Shared by pre-edit.sh and pre-read.sh (spec sections 8.1/8.2): a relative
  # <raw> resolves against WV_CWD (falling back to $PWD, which is what the
  # test harness's run_hook relies on when a case's stdin sends no `cwd` at
  # all). Returns 1 — and every caller then treats the input as unmeasured
  # and exits 0 — when <raw> is empty or carries a literal newline
  # (Interfaces: "an absent or newline-bearing file_path exits 0"), or when
  # it cannot be canonicalised at all.
  #
  # `-m`: no path component needs to exist. A `Write` routinely targets a
  # file that does not exist yet, and plain `realpath` refuses unless every
  # component but the last is already on disk; `-m` still resolves `..` and
  # any symlink in a prefix that DOES exist (spec section 8.1: "a symlink
  # under .wave/ pointing at project source does not launder an edit"), it
  # just does not require the final target itself to be real.
  local raw="${1:-}"
  [ -n "$raw" ] || return 1
  case "$raw" in *$'\n'*) return 1 ;; esac
  local abs
  case "$raw" in
    /*) abs="$raw" ;;
    *)
      local base="${WV_CWD:-}"
      [ -n "$base" ] || base="$PWD"
      abs="$base/$raw"
      ;;
  esac
  local resolved
  resolved="$(realpath -m "$abs" 2>/dev/null)"
  [ -n "$resolved" ] || return 1
  printf '%s' "$resolved"
  return 0
}

wv_project_root() {
  # Sets WV_ROOT. Returns 1 when no project with a wave state could be found,
  # which every caller treats as "no wave" and exits 0 on.
  #
  # Order (spec section 4): CLAUDE_PROJECT_DIR; else `cwd` with a measured
  # `/.claude/worktrees/<name>` suffix stripped; else the nearest ancestor of
  # `cwd` holding `.wave/state.json`, with the walk stopped at
  # `git rev-parse --show-toplevel` so a nested unrelated repository never
  # inherits another project's wave.
  WV_ROOT=""

  local resolved=""
  if [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ -d "$CLAUDE_PROJECT_DIR" ]; then
    resolved="$(realpath "$CLAUDE_PROJECT_DIR" 2>/dev/null)"
    if [ -n "$resolved" ]; then
      WV_ROOT="$resolved"
      return 0
    fi
  fi

  # The client always sends an absolute cwd; `realpath` also lets a test drive
  # a project-relative one, and is a no-op on an absolute path.
  local base="${WV_CWD:-}"
  [ -n "$base" ] || base="$PWD"
  base="$(realpath "$base" 2>/dev/null)"
  [ -n "$base" ] || return 1

  # Measured worktree shape: <project>/.claude/worktrees/agent-<agent_id>.
  if [[ "$base" =~ ^(.+)/\.claude/worktrees/[^/]+$ ]]; then
    local stripped="${BASH_REMATCH[1]}"
    [ -d "$stripped" ] && base="$stripped"
  fi

  local top=""
  top="$(git -C "$base" rev-parse --show-toplevel 2>/dev/null)"
  [ -n "$top" ] && top="$(realpath "$top" 2>/dev/null)"

  local dir="$base"
  while [ -n "$dir" ] && [ "$dir" != "/" ]; do
    if [ -e "$dir/.wave/state.json" ] || [ -L "$dir/.wave" ]; then
      WV_ROOT="$dir"
      return 0
    fi
    if [ -n "$top" ] && [ "$dir" = "$top" ]; then
      break
    fi
    dir="${dir%/*}"
  done
  return 1
}

# ---------------------------------------------------------------------------
# 6. State.
# ---------------------------------------------------------------------------

wv_state_read() {
  # Sets WV_STATE / WV_MODE / WV_STATUS / WV_ENFORCE / WV_WAVE / WV_UI / WV_BC /
  # WV_CR / WV_STATE_OK, plus WV_WAVE_DIR and WV_STATE_FILE (both resolved).
  #
  # Returns 1 — and the caller then exits 0 — when there is no wave, when the
  # wave is not active (silent, per "no wave, no hooks"), or when the state
  # could not be trusted (a W-STATE warning, WV_STATE_OK left at 0).
  WV_STATE=""
  WV_MODE=""
  WV_STATUS=""
  WV_ENFORCE="block"
  WV_WAVE=""
  WV_UI=""
  WV_BC=""
  WV_CR=""
  WV_STATE_OK=0
  WV_WAVE_DIR=""
  WV_STATE_FILE=""

  [ -n "$WV_ROOT" ] || return 1

  local wave_dir="$WV_ROOT/.wave"
  [ -e "$wave_dir" ] || return 1

  local resolved_wave
  resolved_wave="$(realpath "$wave_dir" 2>/dev/null)"
  if [ -z "$resolved_wave" ] || ! wv_inside_root "$resolved_wave"; then
    wv_warn W-STATE "$wave_dir resolves to ${resolved_wave:-a path that does not exist}, outside the project root $WV_ROOT, so it is refused and nothing is written through it"
    return 1
  fi

  local state_path="$resolved_wave/state.json"
  [ -e "$state_path" ] || return 1

  local resolved_state
  resolved_state="$(realpath "$state_path" 2>/dev/null)"
  if [ -z "$resolved_state" ] || ! wv_inside_root "$resolved_state"; then
    wv_warn W-STATE "$state_path resolves to ${resolved_state:-a path that does not exist}, outside the project root $WV_ROOT, so it is refused and never written to"
    return 1
  fi

  local blob
  blob="$(jq -r '
      def field(k): if has(k) then (.[k] | tostring) else "" end;
      [ field("schema"), field("status"), field("mode"), field("enforce"),
        field("wave"), field("ui"), field("behaviour_change"), field("cr_enabled") ]
      | join("\u001f")
    ' "$resolved_state" 2>/dev/null)"
  if [ -z "$blob" ]; then
    wv_warn W-STATE "$(wv_rel "$resolved_state") is not valid JSON, so the wave state could not be read; re-run scripts/wave-init.sh to rewrite it"
    return 1
  fi

  local schema status mode enforce wave ui bc cr
  IFS=$'\x1f' read -r schema status mode enforce wave ui bc cr <<<"$blob"

  WV_STATUS="$status"
  # A closed or unrecognised status enforces nothing, and says nothing.
  [ "$status" = "active" ] || return 1

  if [ "$schema" != "$WV_SCHEMA_MAX" ]; then
    # A HIGHER schema than this plugin knows means the plugin is behind; a LOWER
    # one means the state file is. Telling an operator with schema 0 to "upgrade
    # the plugin" sends them the wrong way, so the two are reported apart.
    local schema_advice="re-run scripts/wave-init.sh to rewrite it at schema $WV_SCHEMA_MAX"
    case "$schema" in
      ''|*[!0-9]*) : ;;
      *) [ "$schema" -gt "$WV_SCHEMA_MAX" ] && schema_advice="upgrade the plugin, which reads up to schema $WV_SCHEMA_MAX" ;;
    esac
    wv_warn W-STATE "$(wv_rel "$resolved_state") declares schema ${schema:-none} and this plugin supports $WV_SCHEMA_MAX; $schema_advice"
    return 1
  fi

  if [ -z "$mode" ]; then
    wv_warn W-STATE "$(wv_rel "$resolved_state") has no mode key, so it is half-written; re-run scripts/wave-init.sh"
    return 1
  fi

  case "$enforce" in
    block|warn)
      WV_ENFORCE="$enforce"
      ;;
    "")
      # The documented default. Its absence is not worth reporting.
      WV_ENFORCE="block"
      ;;
    *)
      WV_ENFORCE="block"
      wv_warn W-STATE "$(wv_rel "$resolved_state") has enforce \"$enforce\", which is neither block nor warn, so block is used; fix the value with scripts/wave-set.sh"
      ;;
  esac

  WV_WAVE_DIR="$resolved_wave"
  WV_STATE_FILE="$resolved_state"
  WV_STATE="$(cat "$resolved_state" 2>/dev/null)"
  WV_MODE="$mode"
  WV_WAVE="$wave"
  WV_UI="$ui"
  WV_BC="$bc"
  WV_CR="$cr"
  WV_STATE_OK=1
  return 0
}

# ---- the lock -------------------------------------------------------------
#
# fd 9 (a literal, because bash needs one in `exec 9>>`) is this library's lock
# handle. The lock file is `.wave/lock`, created by wave-init.sh and never
# replaced; it is NOT state.json (see the header).
#
# WV_LOCK_DEPTH makes acquire/release nest safely. Re-opening fd 9 while it is
# already held would replace the descriptor, and the kernel drops the lock with
# the old one: the inner release would then leave the outer caller holding
# nothing while it still believes the state file is protected. So a nested
# acquire only counts up, and only the outermost release closes the descriptor.

WV_LOCK_DEPTH=0

# WHY the failure is classified. `wv_lock_acquire` returns 1 for two entirely
# different reasons — the lock file could not be created or opened at all (a
# read-only or missing `.wave/`), and the lock is held by somebody else for
# longer than the timeout — and the remedies are opposite: fix the permissions
# versus wait for the other hook. Reporting both as "could not take the lock
# within 10s" sends an operator whose `.wave/` is unwritable to wait for a hook
# that is not running. `wv_lock_detail` renders the clause that fits.
WV_LOCK_FAIL=""

# The lock wait, in seconds. 10 is the shipped value (spec section 6) and the one
# every hook uses; the override exists so a test can drive the TIMEOUT path
# deterministically in about a second instead of spending fourteen of them per
# suite run waiting out the real one. It cannot weaken any rule: a lock timeout
# already warns and ALLOWS, so a shorter wait can only make a hook record less,
# never deny more, and anything able to set this hook's environment could simply
# remove `flock` from PATH instead. A non-numeric or zero value is ignored.
WV_LOCK_TIMEOUT=10
case "${WV_LOCK_TIMEOUT_OVERRIDE:-}" in
  ''|*[!0-9]*|0) : ;;
  *) WV_LOCK_TIMEOUT="$WV_LOCK_TIMEOUT_OVERRIDE" ;;
esac

wv_lock_detail() {
  # wv_lock_detail -> the clause naming WHY the last acquisition failed.
  case "$WV_LOCK_FAIL" in
    unwritable) printf 'the wave state lock %s/lock could not be opened for writing (is %s writable?)' \
                  "$(wv_rel "$WV_WAVE_DIR")" "$(wv_rel "$WV_WAVE_DIR")" ;;
    noroot)     printf 'there is no resolved .wave directory to lock' ;;
    *)          printf 'the wave state lock %s/lock was held by another hook for longer than %ss' \
                  "$(wv_rel "$WV_WAVE_DIR")" "$WV_LOCK_TIMEOUT" ;;
  esac
}

wv_lock_acquire() {
  # Returns 0 with the lock held on fd 9. Returns 1 without warning, having set
  # WV_LOCK_FAIL; the caller warns with the message that fits what it was trying
  # to do, using wv_lock_detail for the part that says why.
  WV_LOCK_FAIL=""
  if [ -z "$WV_WAVE_DIR" ]; then
    WV_LOCK_FAIL=noroot
    return 1
  fi
  if [ "$WV_LOCK_DEPTH" -gt 0 ]; then
    WV_LOCK_DEPTH=$((WV_LOCK_DEPTH + 1))
    return 0
  fi
  local lock="$WV_WAVE_DIR/lock"
  if [ ! -e "$lock" ]; then
    { : > "$lock"; } 2>/dev/null || { WV_LOCK_FAIL=unwritable; return 1; }
  fi
  { exec 9>>"$lock"; } 2>/dev/null || { WV_LOCK_FAIL=unwritable; return 1; }
  if flock -w "$WV_LOCK_TIMEOUT" 9; then
    printf '%s\n' "$$" > "$lock" 2>/dev/null
    WV_LOCK_DEPTH=1
    return 0
  fi
  # A stale lock whose recorded holder is dead is taken, not waited on.
  local holder
  holder="$(cat "$lock" 2>/dev/null)"
  case "$holder" in
    ''|*[!0-9]*) : ;;
    *)
      if ! kill -0 "$holder" 2>/dev/null; then
        if flock -w 1 9; then
          printf '%s\n' "$$" > "$lock" 2>/dev/null
          WV_LOCK_DEPTH=1
          return 0
        fi
      fi
      ;;
  esac
  exec 9>&-
  WV_LOCK_FAIL=timeout
  return 1
}

wv_lock_release() {
  # Only the outermost release closes the descriptor, and closing it is what
  # releases the lock.
  [ "$WV_LOCK_DEPTH" -gt 0 ] || return 0
  WV_LOCK_DEPTH=$((WV_LOCK_DEPTH - 1))
  if [ "$WV_LOCK_DEPTH" -eq 0 ]; then
    exec 9>&-
  fi
  return 0
}

wv_ledger_terminate_locked() {
  # Makes sure the ledger ends in a newline before anything is appended to it.
  # A file whose last byte is not a newline is one somebody's write was cut off
  # part-way through; appending onto it MERGES the new line into that one and
  # destroys both, leaving one unparseable line where there were two good ones.
  # Must be called with the lock held. (`$(tail -c 1)` strips a trailing newline,
  # so an already-terminated file gives the empty string and nothing is written.)
  [ -s "$WV_WAVE_DIR/ledger.jsonl" ] || return 0
  [ -n "$(tail -c 1 "$WV_WAVE_DIR/ledger.jsonl" 2>/dev/null)" ] || return 0
  printf '\n' >> "$WV_WAVE_DIR/ledger.jsonl" 2>/dev/null
  return $?
}

wv_ledger_drain_locked() {
  # Drains .wave/ledger.pending/*.json into the ledger exactly once. Must be
  # called with the lock held.
  local spool="$WV_WAVE_DIR/ledger.pending"
  [ -d "$spool" ] || return 0
  local f
  for f in "$spool"/*.json; do
    [ -f "$f" ] || continue
    wv_ledger_terminate_locked
    if cat "$f" >> "$WV_WAVE_DIR/ledger.jsonl" 2>/dev/null; then
      rm -f "$f"
    fi
  done
  # Once more AFTER the drain: the terminator above protects the ledger from an
  # unterminated tail of its own, and this protects it from an unterminated tail
  # that arrived WITH the spooled content (a spool file a crash cut short, or one
  # a tool wrote without a final newline). Either way the next append must start
  # on a line of its own.
  wv_ledger_terminate_locked
  return 0
}

wv_ledger_drain() {
  # The public drain: takes the lock itself. Silent on a timeout — a drain that
  # did not happen is retried by the next writer.
  [ "$WV_STATE_OK" = "1" ] || return 1
  wv_lock_acquire || return 1
  wv_ledger_drain_locked
  wv_lock_release
  return 0
}

wv_state_update() {
  # wv_state_update '<jq filter>' — the whole read-modify-write under the lock,
  # temp file plus mv inside the lock. Returns 1 (and warns) on a lock timeout
  # or an unwritable directory; never denies, never leaves a half-written file.
  local filter="$1"
  if [ "$WV_STATE_OK" != "1" ] || [ -z "$WV_STATE_FILE" ]; then
    return 1
  fi

  if ! wv_lock_acquire; then
    wv_warn W-STATE "$(wv_lock_detail), so nothing was recorded and the state was left untouched"
    return 1
  fi

  wv_ledger_drain_locked

  local rc=1 tmp
  tmp="$(mktemp "$WV_WAVE_DIR/.state.XXXXXX" 2>/dev/null)"
  if [ -n "$tmp" ]; then
    if jq "$filter" "$WV_STATE_FILE" > "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
      if mv -f "$tmp" "$WV_STATE_FILE" 2>/dev/null; then
        rc=0
      fi
    fi
    [ "$rc" = "0" ] || rm -f "$tmp"
  fi

  wv_lock_release

  if [ "$rc" != "0" ]; then
    wv_warn W-STATE "could not write $(wv_rel "$WV_STATE_FILE") (is $(wv_rel "$WV_WAVE_DIR") writable?), so nothing was recorded and the state was left untouched"
  else
    WV_STATE="$(cat "$WV_STATE_FILE" 2>/dev/null)"
  fi
  return $rc
}

wv_ledger_spool() {
  # wv_ledger_spool <json line> — the no-lock path: write the line to
  # .wave/ledger.pending/<agent_id>.json for the next acquisition to drain.
  # Exposed separately from wv_ledger_append because a caller that has ALREADY
  # waited out the lock timeout must not wait a second time: two `flock -w 10`
  # calls in one hook is twenty seconds, and a SubagentStop hook has to be back
  # inside the timeout it advertises.
  #
  # Appended, not overwritten: the spool file is per agent, so a second timeout
  # for the same agent would otherwise drop the first line. The drain cats the
  # whole file and removes it, so appending is still drained exactly once.
  local line="$1"
  local spool="$WV_WAVE_DIR/ledger.pending"
  local id="${WV_AGENT_ID:-unknown}"
  if mkdir -p "$spool" 2>/dev/null && printf '%s\n' "$line" >> "$spool/$id.json" 2>/dev/null; then
    wv_warn W-STATE "the wave state lock was busy, so this ledger line was spooled to $(wv_rel "$spool")/$id.json and will be merged by the next hook that takes the lock"
    return 0
  fi
  wv_warn W-STATE "the wave state lock was busy and $(wv_rel "$spool")/$id.json could not be written, so this step is missing from the token ledger"
  return 1
}

wv_ledger_append() {
  # wv_ledger_append '<json line>' — one printf under the same lock. On a lock
  # timeout the line is spooled to .wave/ledger.pending/<agent_id>.json and the
  # next successful acquisition drains it; a ledger line is never lost and
  # never denies.
  local line="$1"
  if [ "$WV_STATE_OK" != "1" ] || [ -z "$WV_WAVE_DIR" ]; then
    return 1
  fi

  if wv_lock_acquire; then
    wv_ledger_drain_locked
    local rc=0
    wv_ledger_terminate_locked
    printf '%s\n' "$line" >> "$WV_WAVE_DIR/ledger.jsonl" 2>/dev/null || rc=1
    wv_lock_release
    if [ "$rc" != "0" ]; then
      wv_warn W-STATE "could not append to $(wv_rel "$WV_WAVE_DIR")/ledger.jsonl, so this step is missing from the token ledger"
    fi
    return $rc
  fi

  wv_ledger_spool "$line"
  return 1
}

# ---------------------------------------------------------------------------
# 7. Model tiers (spec section 7).
# ---------------------------------------------------------------------------

wv_tier_rank() {
  # wv_tier_rank <token> -> the rank, or the literal `unknown` for a declared
  # alias. Returns 1 when the token is not a tier name at all.
  local token="$1" name rank
  if [ -f "$WV_MODELS_TSV" ]; then
    while IFS=$'\t' read -r name rank; do
      case "$name" in ''|'#'*|token) continue ;; esac
      if [ "$name" = "$token" ]; then
        printf '%s' "$rank"
        return 0
      fi
    done < "$WV_MODELS_TSV"
    return 1
  fi
  # Fallback until hooks/models.tsv ships: the same rows that file will carry.
  case "$token" in
    haiku) printf '1' ;;
    sonnet) printf '2' ;;
    opus) printf '3' ;;
    fable) printf '4' ;;
    opusplan|default) printf 'unknown' ;;
    *) return 1 ;;
  esac
  return 0
}

wv_tier() {
  # wv_tier <model-string> -> 1|2|3|4|unknown.
  # Trim, lowercase, split on non-alphanumerics, and require exactly one
  # distinct tier token. Zero matches, two different matches, or a token
  # models.tsv declares `unknown` all give `unknown` (which the caller turns
  # into a warning and an allow, never a deny).
  local raw="${1:-}"
  local lowered
  lowered="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')"
  local tokens
  tokens="$(printf '%s' "$lowered" | tr -c '[:alnum:]' ' ')"

  local token rank found=""
  for token in $tokens; do
    rank="$(wv_tier_rank "$token")" || continue
    if [ "$rank" = "unknown" ]; then
      printf 'unknown'
      return 0
    fi
    if [ -z "$found" ]; then
      found="$rank"
    elif [ "$found" != "$rank" ]; then
      printf 'unknown'
      return 0
    fi
  done

  if [ -z "$found" ]; then
    printf 'unknown'
  else
    printf '%s' "$found"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# 7b. The phase table, by column (spec section 6).
#
# One copy, here, because three scripts read this file: pre-agent.sh judges a
# dispatch against the row, subagent-stop.sh judges the phase's hand-off against
# it, and any later reader needs the same column numbers. They lived as a copy in
# each script until a review ruled the duplication out; the numbers are the
# table's contract, not any one script's.
#
# Every reader here is READ-ONLY with respect to its caller's state: they return
# a row (or one cell) and touch nothing, so a caller that asks about a
# PREDECESSOR's row cannot have the row it was judging moved underneath it.
# ---------------------------------------------------------------------------

WV_COL_CODE=1
WV_COL_MODES=2
WV_COL_WHEN=3
WV_COL_CONDITION=4
WV_COL_AFTER=5
WV_COL_FANOUT=6
WV_COL_LEAD=7
WV_COL_EXECUTOR=8
WV_COL_REVIEWER=9
WV_COL_ARTIFACT=10
WV_COL_MARKER=11
WV_COL_FINDINGS=12

wv_row_line() {
  # wv_row_line <code> -> the row's twelve cells joined with US (0x1f) on stdout.
  # Returns 1 when <code> is not a row.
  #
  # Tabs are re-delimited to US before anything reads them, because tab is IFS
  # WHITESPACE: `IFS=$'\t' read` collapses two adjacent tabs into one delimiter
  # and silently shifts every column after an empty cell — and `after` is empty
  # on the first row of this very file.
  local want="$1" line rec code
  [ -f "$WV_PHASES_TSV" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*|"code"$'\t'*) continue ;; esac
    rec="${line//$'\t'/$'\x1f'}"
    code="${rec%%$'\x1f'*}"
    if [ "$code" = "$want" ]; then
      printf '%s' "$rec"
      return 0
    fi
  done < "$WV_PHASES_TSV"
  return 1
}

wv_row_get() {
  # wv_row_get <code> <1-based column> -> that cell, which may legitimately be
  # empty (`after` is empty on the AC and AD rows). Returns 1 only when the code
  # is not a row at all, so a caller can tell "no such phase" from "no
  # predecessors".
  local rec
  rec="$(wv_row_line "$1")" || return 1
  local -a cells=()
  IFS=$'\x1f' read -r -a cells <<<"$rec"
  printf '%s' "${cells[$(($2 - 1))]:-}"
  return 0
}

# ---------------------------------------------------------------------------
# 8. Gating scans (Global Constraint 7).
# ---------------------------------------------------------------------------

WV_SCAN_COUNT=""

wv_scan() {
  # wv_scan <file> <extended-regex> — sets WV_SCAN_COUNT to the match count and
  # returns 0. An ABSENT count means the scan did not run (a wrapped searcher
  # declining the file, an unreadable path): it warns W-STATE, leaves
  # WV_SCAN_COUNT empty and returns 1. Never reports 0 for that.
  #
  # THIS is the form to call when the warning matters. Its stdout-printing
  # sibling below has to be wrapped in a command substitution to be useful, and a
  # command substitution is a SUBSHELL: `wv_warn` there appends to a COPY of the
  # queue that dies with it, so the caller emits a block or an allow having
  # silently dropped the one line that said it could not measure the file. (Same
  # trap pre-agent.sh's header calls out for wv_condition_met: "never call this
  # through a command substitution — the status is the answer, but the globals
  # are the reason".)
  WV_SCAN_COUNT=""
  local file="$1" regex="$2" count
  count="$(command grep -cE -- "$regex" "$file" 2>/dev/null)"
  case "$count" in
    ''|*[!0-9]*)
      wv_warn W-STATE "the gating scan of $(wv_rel "$file") returned no count, so it did not run and nothing was measured; re-run once the file is readable"
      return 1
      ;;
  esac
  WV_SCAN_COUNT="$count"
  return 0
}

wv_scan_count() {
  # wv_scan_count <file> <extended-regex> -> the match count on stdout, for a
  # caller that only wants the number. Same contract as wv_scan otherwise — but
  # see wv_scan's note on the queued warning: if this is called inside a command
  # substitution (and it has to be, to read the number), the W-STATE it queues on
  # a failed scan does not reach the caller.
  wv_scan "$1" "$2" || return 1
  printf '%s' "$WV_SCAN_COUNT"
  return 0
}

# ---------------------------------------------------------------------------
# 9. Emitters.
# ---------------------------------------------------------------------------

wv_can_emit() {
  # A hook that could not parse its stdin has measured nothing, so it says
  # nothing. W-STATE is the exception to the state gate: it exists precisely to
  # report that the state could not be trusted.
  local rule="$1"
  [ "$WV_PARSED" = "1" ] || return 1
  case "$rule" in
    W-STATE) return 0 ;;
  esac
  [ "$WV_STATE_OK" = "1" ] || return 1
  return 0
}

wv_list_cap() {
  # wv_list_cap <max items> <max chars> <separator> <item>... -> the items joined
  # by <separator>, truncated to whichever of the two budgets binds first, with
  # "(+N more)" naming how many were left out.
  #
  # A reason interpolates a LIST in two places — the staged planning documents a
  # commit was refused for, and the unanswered OPEN: lines of a design review —
  # and both are as long as the user's input. Without a cap the reason's length is
  # unbounded: a commit staging thirty analysis files renders a reason nobody
  # reads, and the 400-character bound tests/tools/reason-corpus.sh enforces would
  # hold only for the fixtures in the corpus, not for any real input. A bound that
  # is a property of the test data is not a bound.
  #
  # BOTH budgets are needed, and an item count alone was measured to be
  # insufficient: four staged paths of 50 characters each already carry the reason
  # past 400. So items are added while the count AND the character budget both
  # allow, and at least one item is always named — a reason that named nothing and
  # said "(+12 more)" would satisfy a length check while telling the operator
  # nothing to act on.
  local max_items="$1" max_chars="$2" sep="$3"
  shift 3
  local out="" n=0 total=$# item
  for item in "$@"; do
    if [ "$n" -gt 0 ]; then
      [ "$n" -lt "$max_items" ] || break
      [ $(( ${#out} + ${#sep} + ${#item} )) -le "$max_chars" ] || break
    fi
    out="${out:+$out$sep}$item"
    n=$((n + 1))
  done
  if [ "$total" -gt "$n" ]; then
    out="$out$sep(+$((total - n)) more)"
  fi
  printf '%s' "$out"
}

wv_rel() {
  # wv_rel <path> -> the path with the project root stripped, so a reason names
  # `.wave/ledger.jsonl` and not `/home/<someone>/<their project>/.wave/…`.
  #
  # A reason is read by a person and matched by a test. The project root is not
  # information either of them needs: it is the same for every path in the
  # message, it is only true on the machine that rendered it, and it pushes the
  # part that matters past the end of a terminal line. A path that is genuinely
  # OUTSIDE the root is returned unchanged — there is nothing to make it relative
  # to, and for the two symlink-escape warnings the absolute target IS the claim.
  local path="${1:-}"
  if [ -n "$WV_ROOT" ]; then
    case "$path" in
      "$WV_ROOT"/*) printf '%s' "${path#"$WV_ROOT"/}"; return 0 ;;
      "$WV_ROOT") printf '.'; return 0 ;;
    esac
  fi
  printf '%s' "$path"
}

wv_warn() {
  # wv_warn <rule> [args...] — queues a rendered warning. Warnings are flushed
  # once, by wv_emit_flush or by the deny that carries them, because only one
  # JSON object may reach stdout.
  local rule="$1"
  shift
  wv_can_emit "$rule" || return 1
  local text
  text="$(wv_render "$rule" "$@")"
  if [ -n "$WV_WARNINGS" ]; then
    WV_WARNINGS="$WV_WARNINGS
$text"
  else
    WV_WARNINGS="$text"
  fi
  return 0
}

wv_warn_channel_is_stdout() {
  # The events measured to accept `additionalContext` (spec section 2).
  case "$WV_EVENT" in
    PreToolUse|PostToolUse|SessionStart|UserPromptSubmit|Stop) return 0 ;;
    *) return 1 ;;
  esac
}

wv_emit_flush() {
  # Emits the queued warnings, once. On an event with an additionalContext
  # channel that is one JSON object; on any other event (SubagentStop,
  # PreCompact) there is no such channel, so they go to stderr.
  #
  # Returns 1 when an object has already been written to stdout: those warnings
  # were either already carried by it or arrived too late for the only channel
  # this event has.
  [ -n "$WV_WARNINGS" ] || return 0
  if wv_warn_channel_is_stdout && [ "$WV_EMITTED" = "1" ]; then
    return 1
  fi
  local text="$WV_WARNINGS"
  WV_WARNINGS=""
  if wv_warn_channel_is_stdout; then
    jq -nc --arg event "$WV_EVENT" --arg context "$text" \
      '{hookSpecificOutput: {hookEventName: $event, additionalContext: $context}}'
    WV_EMITTED=1
  else
    printf '%s\n' "$text" >&2
  fi
  return 0
}

wv_deny() {
  # wv_deny <rule> [args...] — the PreToolUse deny shape, one object on stdout,
  # carrying any queued warnings as additionalContext. Under enforce="warn" the
  # same rule id is emitted through the warn channel instead.
  local rule="$1"
  shift
  wv_can_emit "$rule" || return 1
  [ "$WV_STATE_OK" = "1" ] || return 1
  [ "$WV_EMITTED" = "0" ] || return 1   # one object per invocation; first wins
  local text
  text="$(wv_render "$rule" "$@")"

  if [ "$WV_ENFORCE" = "warn" ]; then
    if [ -n "$WV_WARNINGS" ]; then
      WV_WARNINGS="$WV_WARNINGS
$text"
    else
      WV_WARNINGS="$text"
    fi
    wv_emit_flush
    return 0
  fi

  local extra="$WV_WARNINGS"
  WV_WARNINGS=""
  if [ -n "$extra" ]; then
    jq -nc --arg event "$WV_EVENT" --arg reason "$text" --arg context "$extra" \
      '{hookSpecificOutput: {hookEventName: $event, permissionDecision: "deny", permissionDecisionReason: $reason, additionalContext: $context}}'
  else
    jq -nc --arg event "$WV_EVENT" --arg reason "$text" \
      '{hookSpecificOutput: {hookEventName: $event, permissionDecision: "deny", permissionDecisionReason: $reason}}'
  fi
  WV_EMITTED=1
  return 0
}

wv_block() {
  # wv_block <rule> [args...] — the SubagentStop block shape. Under
  # enforce="warn" that event has no stdout warn channel, so the warning is
  # recorded as state.phases[<phase>].warned plus a `warn` field on a ledger
  # line, and the subagent is allowed to stop.
  local rule="$1"
  shift
  wv_can_emit "$rule" || return 1
  [ "$WV_STATE_OK" = "1" ] || return 1
  [ "$WV_EMITTED" = "0" ] || return 1   # one rule per invocation; first wins
  local text
  text="$(wv_render "$rule" "$@")"

  if [ "$WV_ENFORCE" = "warn" ]; then
    local phase="${WV_PHASE:-unknown}"
    wv_state_update "$(printf '.phases[%s].warned = ((.phases[%s].warned // []) + [%s])' \
      "$(jq -Rn --arg p "$phase" '$p')" \
      "$(jq -Rn --arg p "$phase" '$p')" \
      "$(jq -Rn --arg t "$text" '$t')")"
    wv_ledger_append "$(jq -nc --arg agent "${WV_AGENT_ID:-unknown}" --arg phase "$phase" --arg warn "$text" \
      '{event: "warn", agent_id: $agent, phase: $phase, warn: [$warn]}')"
    # The state row and the ledger line ARE this event's warn channel, so they
    # count as the invocation's one emission.
    WV_EMITTED=1
    return 0
  fi

  # The block object is this event's ONLY stdout, and SubagentStop has no
  # `additionalContext` channel for a warning to ride on — so a queued warning
  # cannot be carried. It must not be DISCARDED either: every warning queued
  # before a block says the hook could not measure something, which is exactly
  # what a reader needs to know when a block arrives (an artifact whose marker
  # scan never ran, a state file it could not write). They go to stderr, one per
  # line, before the object.
  if [ -n "$WV_WARNINGS" ]; then
    printf '%s\n' "$WV_WARNINGS" >&2
    WV_WARNINGS=""
  fi
  jq -nc --arg reason "$text" '{decision: "block", reason: $reason}'
  WV_EMITTED=1
  return 0
}

# ---------------------------------------------------------------------------
# 10. The emit choke point, hoisted from pre-agent.sh (Task 9): every one of
#     pre-agent.sh, pre-edit.sh, pre-read.sh and pre-bash.sh now calls a
#     rule through here rather than through wv_deny / wv_warn directly, so
#     there is exactly one place that neutralises `W-` inside a caller's
#     argument. `W-` becomes `W_` in the ARGUMENTS only, never in the
#     template, so a rendered reason keeps exactly one `W-` token even when
#     the caller quotes dispatch text, a shell command, or a file path that
#     happens to contain something shaped like a rule id
#     (`assert_single_rule_token` extracts it with `W-[A-Z0-9-]+`, and a
#     second token would make a consumer read the wrong rule off it). The
#     rewrite lives at this one choke point rather than at every call site
#     that quotes input, so a rule a future script adds cannot forget it.
# ---------------------------------------------------------------------------

wv_rule_deny() {
  # wv_rule_deny <rule> [args...] — wv_deny with every argument neutralised.
  local rule="$1"
  shift
  if [ "$#" -eq 0 ]; then
    wv_deny "$rule"
    return
  fi
  local -a args=()
  local arg
  for arg in "$@"; do
    args+=("${arg//W-/W_}")
  done
  wv_deny "$rule" "${args[@]}"
}

wv_rule_warn() {
  # wv_rule_warn <rule> [args...] — wv_warn, neutralised the same way.
  local rule="$1"
  shift
  if [ "$#" -eq 0 ]; then
    wv_warn "$rule"
    return
  fi
  local -a args=()
  local arg
  for arg in "$@"; do
    args+=("${arg//W-/W_}")
  done
  wv_warn "$rule" "${args[@]}"
}

# ---------------------------------------------------------------------------
# 11. Phase-order and checkpoint helpers (Task 10), shared by
#     session-start.sh, user-prompt.sh and pre-compact.sh.
#
# These are a MINIMAL, READ-ONLY, ADVISORY-ONLY port of pre-agent.sh's
# wv_condition_met / wv_phase_done / wv_after_unmet. They answer "what would a
# human call the last completed step and the next one" for a banner or a
# reminder — never a gate — so unlike pre-agent.sh's versions they collapse
# every "cannot be measured" case (an unreadable findings file, an unanswered
# ui/behaviour_change/cr flag) to a plain "not met" rather than raising a
# separate W-ARTIFACT / W-MARKER / W-SCOPE deny: nothing here ever denies
# anything, so there is no reason to distinguish "skip" from "cannot tell".
#
# Task 10 does NOT source pre-agent.sh for this — sourcing it would run its
# entire PreToolUse(Agent) rule chain against whatever event is live and then
# `exit 0` before this file's caller ran another line, the same reason
# subagent-stop.sh gives for not sourcing it either. hooks/phases.tsv is read
# again through this library's own wv_row_line / wv_row_get / WV_COL_*
# (section 7b), so the column numbers are still read from one place.
# ---------------------------------------------------------------------------

wv_state_phase_status() {
  # wv_state_phase_status <code> -> state.phases[<code>].status, or "" when
  # the key, the map, or the whole `phases` object is absent. A copy of
  # pre-agent.sh's function of the same name and identical behaviour (it
  # reads only WV_STATE, which this library already owns) — added here
  # because lib.sh section 11's helpers need it and this file does not
  # source pre-agent.sh (see the section-11 header). Harmless if
  # pre-agent.sh's own copy loads after this one; the two can never disagree.
  [ -n "$WV_STATE" ] || return 0
  printf '%s' "$WV_STATE" | jq -r --arg c "$1" \
    'try ((.phases // {})[$c].status // "") catch ""' 2>/dev/null
  return 0
}

wv_up_condition_met() {
  # wv_up_condition_met <code> -> 0 when the row's condition holds in the
  # current state, 1 otherwise (including "cannot be measured", which a gate
  # would refuse to guess and an advisory just treats as not-yet).
  local code="$1" cond file
  cond="$(wv_row_get "$code" "$WV_COL_CONDITION")" || return 1
  case "$cond" in
    ''|always) return 0 ;;
    'ui|behaviour_change')
      [ "$WV_UI" = "true" ] && return 0
      [ "$WV_BC" = "true" ] && return 0
      return 1
      ;;
    cr)
      [ "$WV_CR" = "true" ] && return 0
      return 1
      ;;
    findings:*)
      file="$WV_WAVE_DIR/findings/${cond#findings:}.md"
      [ -f "$file" ] || return 1
      wv_scan "$file" '^FINDINGS: [0-9]+$' || return 1
      [ "$WV_SCAN_COUNT" != "0" ] || return 1
      local line n
      line="$(command grep -m1 -E '^FINDINGS: [0-9]+$' "$file" 2>/dev/null)"
      n="${line#FINDINGS: }"
      case "$n" in ''|*[!0-9]*) return 1 ;; esac
      [ "$((10#$n))" -ge 1 ] && return 0
      return 1
      ;;
    *) return 0 ;;   # an unrecognised keyword: advisory fails open to "met"
  esac
}

wv_up_phase_settled() {
  # wv_up_phase_settled <code> -> 0 when the row counts as settled for the
  # purpose of walking `after`: its state row says done, its `modes` exclude
  # the active mode, or its own condition does not hold (the skip rule).
  local code="$1" modes
  [ "$(wv_state_phase_status "$code")" = "done" ] && return 0
  modes="$(wv_row_get "$code" "$WV_COL_MODES")" || return 1
  case ",$modes," in
    *",$WV_MODE,"*) : ;;
    *) return 0 ;;
  esac
  wv_up_condition_met "$code" && return 1
  return 0
}

WV_UP_VISITED=""

wv_up_after_settled() {
  # wv_up_after_settled <code> -> 0 when every predecessor in `after` is
  # settled (done or skipped), walking through a skipped predecessor into ITS
  # predecessors the same way pre-agent.sh's order walk does, so a wave with
  # cr_enabled false still does not report CR's successor as allowed before
  # TDE-GREEN is actually done.
  WV_UP_VISITED=""
  wv_up_after_settled_walk "$1"
}

wv_up_after_settled_walk() {
  local code="$1" after p
  local -a preds=()
  case " $WV_UP_VISITED " in *" $code "*) return 0 ;; esac
  WV_UP_VISITED="$WV_UP_VISITED $code"
  after="$(wv_row_get "$code" "$WV_COL_AFTER")" || return 0
  [ -n "$after" ] || return 0
  IFS=',' read -ra preds <<<"$after"
  for p in "${preds[@]}"; do
    [ -n "$p" ] || continue
    if [ "$(wv_state_phase_status "$p")" = "done" ]; then
      continue
    fi
    if wv_up_phase_settled "$p"; then
      wv_up_after_settled_walk "$p" || return 1
      continue
    fi
    return 1
  done
  return 0
}

wv_last_done_phase() {
  # wv_last_done_phase -> the LAST row of hooks/phases.tsv (file order) whose
  # `modes` include the active mode and whose state row says done, or "none".
  # Solo mode does not consult phases.tsv anywhere else in this framework;
  # callers in solo mode should not call this at all.
  [ -f "$WV_PHASES_TSV" ] || { printf 'none'; return 0; }
  local last="none" code modes rest
  while IFS=$'\t' read -r code modes rest; do
    case "$code" in ''|'#'*|code) continue ;; esac
    case ",$modes," in
      *",$WV_MODE,"*) : ;;
      *) continue ;;
    esac
    [ "$(wv_state_phase_status "$code")" = "done" ] && last="$code"
  done < "$WV_PHASES_TSV"
  printf '%s' "$last"
  return 0
}

wv_next_allowed_phase() {
  # wv_next_allowed_phase -> the first `when=phase` row (file order) that is
  # allowed in this mode, not already done, whose own condition holds, and
  # whose predecessors are all settled — i.e. the phase pre-agent.sh would let
  # through right now — or "none" when every such row is already settled.
  [ -f "$WV_PHASES_TSV" ] || { printf 'none'; return 0; }
  local code modes when rest
  while IFS=$'\t' read -r code modes when rest; do
    case "$code" in ''|'#'*|code) continue ;; esac
    [ "$when" = "phase" ] || continue
    case ",$modes," in
      *",$WV_MODE,"*) : ;;
      *) continue ;;
    esac
    [ "$(wv_state_phase_status "$code")" = "done" ] && continue
    wv_up_condition_met "$code" || continue
    if wv_up_after_settled "$code"; then
      printf '%s' "$code"
      return 0
    fi
  done < "$WV_PHASES_TSV"
  printf 'none'
  return 0
}

wv_latest_checkpoint() {
  # wv_latest_checkpoint -> the project-relative path of the newest file
  # under .wave/checkpoints/ (ISO-8601 timestamp filenames sort correctly as
  # plain text), or empty when the directory has none. Never fails.
  [ -n "$WV_WAVE_DIR" ] && [ -d "$WV_WAVE_DIR/checkpoints" ] || return 1
  local f last=""
  for f in "$WV_WAVE_DIR"/checkpoints/*; do
    [ -f "$f" ] || continue
    last="$f"
  done
  [ -n "$last" ] || return 1
  printf '.wave/checkpoints/%s' "${last##*/}"
  return 0
}

wv_wave_stale_24h() {
  # wv_wave_stale_24h -> 0 (true) when state.started is more than 24h in the
  # past. Never fails loudly: an unparseable or absent `started` is "not
  # stale" (a hook must not invent a warning from a measurement it cannot
  # make).
  [ -n "$WV_STATE" ] || return 1
  local started started_epoch now_epoch
  started="$(printf '%s' "$WV_STATE" | jq -r '.started // empty' 2>/dev/null)"
  [ -n "$started" ] || return 1
  started_epoch="$(date -u -d "$started" +%s 2>/dev/null)"
  case "$started_epoch" in ''|*[!0-9]*) return 1 ;; esac
  now_epoch="$(date -u +%s)"
  [ $((now_epoch - started_epoch)) -gt 86400 ]
}
