#!/usr/bin/env bash
# scripts/hooks/lib.sh — the shared library every wave hook script sources.
#
# Responsibilities: parse the hook's stdin, resolve the project root, read and
# update `.wave/state.json` under a lock, map a model string to a tier, and
# emit the deny / warn / block shapes the client understands.
#
# Non-negotiable properties, all of them load-bearing:
#
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
#     longer the state file. Proved by counting in tests/cases/lib-concurrency.sh.
#   * Every gating scan goes through `command grep` (a wrapped searcher can
#     decline a file and print nothing where real grep prints `0`), and an
#     absent count is a FAILED scan, never a clean zero.
#
# Rule reasons are rendered from `hooks/reasons.tsv` (one printf template per
# rule id). Until that file exists, a built-in fallback renders
# `[<id>] <detail>; remedy: …` so the shape (`[<id>] ` prefix, exactly one
# `W-` token, a remedy clause) is right from the start; byte-equality against
# the real templates is asserted separately.

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

WV_WARNINGS=""      # rendered warnings, newline separated, flushed once
WV_PHASE="${WV_PHASE:-}"   # set by the calling hook when it knows the phase
WV_SCHEMA_MAX=1

# ---------------------------------------------------------------------------
# 3. Reason rendering.
# ---------------------------------------------------------------------------

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
    # shellcheck disable=SC2059  # the template IS the format string (data over code)
    out="$(printf "$tmpl" "$@" 2>/dev/null)"
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
    wv_warn W-STATE "$resolved_state is not valid JSON, so the wave state could not be read; re-run scripts/wave-init.sh to rewrite it"
    return 1
  fi

  local schema status mode enforce wave ui bc cr
  IFS=$'\x1f' read -r schema status mode enforce wave ui bc cr <<<"$blob"

  WV_STATUS="$status"
  # A closed or unrecognised status enforces nothing, and says nothing.
  [ "$status" = "active" ] || return 1

  if [ "$schema" != "$WV_SCHEMA_MAX" ]; then
    wv_warn W-STATE "$resolved_state declares schema ${schema:-none}, and the highest supported schema is $WV_SCHEMA_MAX; upgrade the plugin or re-run scripts/wave-init.sh"
    return 1
  fi

  if [ -z "$mode" ]; then
    wv_warn W-STATE "$resolved_state has no mode key, so it is half-written; re-run scripts/wave-init.sh"
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
      wv_warn W-STATE "$resolved_state has enforce \"$enforce\", which is neither block nor warn, so block is used; fix the value with scripts/wave-set.sh"
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

wv_lock_acquire() {
  # Returns 0 with the lock held on fd 9. Returns 1 without warning; the
  # caller warns with the message that fits what it was trying to do.
  [ -n "$WV_WAVE_DIR" ] || return 1
  local lock="$WV_WAVE_DIR/lock"
  if [ ! -e "$lock" ]; then
    { : > "$lock"; } 2>/dev/null || return 1
  fi
  { exec 9>>"$lock"; } 2>/dev/null || return 1
  if flock -w 10 9; then
    printf '%s\n' "$$" > "$lock" 2>/dev/null
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
          return 0
        fi
      fi
      ;;
  esac
  wv_lock_release
  return 1
}

wv_lock_release() {
  exec 9>&-
}

wv_ledger_drain_locked() {
  # Drains .wave/ledger.pending/*.json into the ledger exactly once. Must be
  # called with the lock held.
  local spool="$WV_WAVE_DIR/ledger.pending"
  [ -d "$spool" ] || return 0
  local f
  for f in "$spool"/*.json; do
    [ -f "$f" ] || continue
    if cat "$f" >> "$WV_WAVE_DIR/ledger.jsonl" 2>/dev/null; then
      rm -f "$f"
    fi
  done
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
    wv_warn W-STATE "could not take the wave state lock $WV_WAVE_DIR/lock within 10s, so nothing was recorded; re-run the step once the other hook has finished"
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
    wv_warn W-STATE "could not write $WV_STATE_FILE (is $WV_WAVE_DIR writable?), so nothing was recorded and the state was left untouched"
  else
    WV_STATE="$(cat "$WV_STATE_FILE" 2>/dev/null)"
  fi
  return $rc
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
    printf '%s\n' "$line" >> "$WV_WAVE_DIR/ledger.jsonl" 2>/dev/null || rc=1
    wv_lock_release
    if [ "$rc" != "0" ]; then
      wv_warn W-STATE "could not append to $WV_WAVE_DIR/ledger.jsonl, so this step is missing from the token ledger"
    fi
    return $rc
  fi

  local spool="$WV_WAVE_DIR/ledger.pending"
  local id="${WV_AGENT_ID:-unknown}"
  # Appended, not overwritten: the spool file is per agent, so a second timeout
  # for the same agent would otherwise drop the first line. The drain cats the
  # whole file and removes it, so appending is still drained exactly once.
  if mkdir -p "$spool" 2>/dev/null && printf '%s\n' "$line" >> "$spool/$id.json" 2>/dev/null; then
    wv_warn W-STATE "the wave state lock was busy, so this ledger line was spooled to $spool/$id.json and will be merged by the next hook that takes the lock"
  else
    wv_warn W-STATE "the wave state lock was busy and $spool/$id.json could not be written, so this step is missing from the token ledger"
  fi
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
# 8. Gating scans (Global Constraint 7).
# ---------------------------------------------------------------------------

wv_scan_count() {
  # wv_scan_count <file> <extended-regex> -> the match count on stdout.
  # A real zero prints `0` and returns 0. An ABSENT count means the scan did
  # not run (a wrapped searcher declining the file, an unreadable path): it
  # warns W-STATE, prints nothing and returns 1. Never reports 0 for that.
  local file="$1" regex="$2" count
  count="$(command grep -cE -- "$regex" "$file" 2>/dev/null)"
  case "$count" in
    ''|*[!0-9]*)
      wv_warn W-STATE "the gating scan of $file returned no count, so it did not run and nothing was measured; re-run once the file is readable"
      return 1
      ;;
  esac
  printf '%s' "$count"
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
  [ -n "$WV_WARNINGS" ] || return 0
  local text="$WV_WARNINGS"
  WV_WARNINGS=""
  if wv_warn_channel_is_stdout; then
    jq -nc --arg event "$WV_EVENT" --arg context "$text" \
      '{hookSpecificOutput: {hookEventName: $event, additionalContext: $context}}'
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
    return 0
  fi

  WV_WARNINGS=""
  jq -nc --arg reason "$text" '{decision: "block", reason: $reason}'
  return 0
}

# ---------------------------------------------------------------------------
# 10. Self-drive entry point.
#
# Sourced by a hook script, this file only defines functions. Executed
# directly, it drives one library operation named by WV_DRIVE and exits 0 —
# which is how tests/cases/lib-*.{json,sh} exercise the library before the
# hook scripts that use it exist. With no WV_DRIVE it parses, resolves and
# reads, then exits 0 silently.
# ---------------------------------------------------------------------------

wv_lib_driver() {
  wv_parse_stdin || exit 0
  wv_project_root || exit 0
  if ! wv_state_read; then
    wv_emit_flush
    exit 0
  fi

  local action="${WV_DRIVE:-}"
  case "$action" in
    '') : ;;
    deny:*) wv_deny "${action#deny:}" "a self-drive check of the deny path" ;;
    warn:*) wv_warn "${action#warn:}" "a self-drive check of the warn path" ;;
    block:*) wv_block "${action#block:}" "a self-drive check of the block path" ;;
    update:*) wv_state_update "${action#update:}" ;;
    ledger:*) wv_ledger_append "${action#ledger:}" ;;
    *) wv_stderr "unrecognised WV_DRIVE action: $action" ;;
  esac

  wv_emit_flush
  exit 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  wv_lib_driver "$@"
fi
