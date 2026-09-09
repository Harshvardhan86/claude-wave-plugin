#!/usr/bin/env bash
# scripts/hooks/pre-edit.sh — the PreToolUse hook on `Edit`, `Write`,
# `NotebookEdit` and `MultiEdit`.
#
# Spec section 8.1: a main-session edit is denied (W-EDIT) when its target,
# after `realpath`, is inside the project root AND tracked by git AND not
# under `.wave/`, unless its repo-relative path matches a row of
# `hooks/orchestrator-writable.tsv`. A path outside the project root is
# untouched (the orchestrator's own analysis and handoff documents live
# there by the framework's own instruction), and an absent or
# newline-bearing path is never a violation — see lib.sh's
# wv_resolve_input_path, shared with pre-read.sh.
#
# Solo mode (spec section 6, "Solo mode") and any call made INSIDE a
# subagent (stdin carries `agent_id`) are both silent no-ops: subagents
# implement, and only the main session is gated.
#
# Measured (Task 9 probe against a live 2.1.266 session, 2026-09-10; see
# tests/fixtures/measured-keys.txt): Edit/Write carry `tool_input.file_path`,
# always sent as an absolute path — but `NotebookEdit` carries
# `tool_input.notebook_path` instead, NOT `file_path`. The plan brief's
# assumption of one shared field name across all four tools does not hold on
# the client of record. `MultiEdit` was never probed — it is not a tool this
# client sends at all (AC-270 records this as a declared bound; the matcher
# entry is forward-compatibility only) — so it is read the same way as
# `Edit`/`Write`, which is the only shape available to guess from.

set -u

WV_HOOK_DIR="$(cd "${BASH_SOURCE[0]%/*}" 2>/dev/null && pwd)"
# shellcheck source=scripts/hooks/lib.sh
source "$WV_HOOK_DIR/lib.sh"

WV_WRITABLE_TSV="$WV_PLUGIN_DIR/hooks/orchestrator-writable.tsv"

wv_edit_target_field() {
  # wv_edit_target_field <tool-name> -> the tool_input key that carries the
  # path for that tool (see the header's measured-field note).
  case "$1" in
    NotebookEdit) printf 'notebook_path' ;;
    *) printf 'file_path' ;;
  esac
}

wv_writable_allowed() {
  # wv_writable_allowed <repo-relative-path> — true when a row of
  # hooks/orchestrator-writable.tsv glob-matches it (bash `case` glob, so a
  # bare `*` already matches `/`; the file's own `**` spelling reads no
  # differently here, it is just the file's documented convention). Blank
  # lines and `#`-comments are skipped, matching every other *.tsv reader in
  # this plugin.
  local rel="$1" pat
  [ -f "$WV_WRITABLE_TSV" ] || return 1
  while IFS= read -r pat || [ -n "$pat" ]; do
    case "$pat" in ''|'#'*) continue ;; esac
    # shellcheck disable=SC2254
    case "$rel" in $pat) return 0 ;; esac
  done < "$WV_WRITABLE_TSV"
  return 1
}

wv_main() {
  wv_parse_stdin || return 0
  [ "$WV_EVENT" = "PreToolUse" ] || return 0
  case "$WV_TOOL" in
    Edit|Write|NotebookEdit|MultiEdit) : ;;
    *) return 0 ;;
  esac

  # Subagents implement; only the main session is gated (spec section 8).
  [ -z "$WV_AGENT_ID" ] || return 0

  wv_project_root || return 0
  wv_state_read || return 0
  # Solo keeps none of section 8's rules (spec section 6); any mode this
  # version does not recognise is treated the same way.
  case "$WV_MODE" in
    full|demo) : ;;
    *) return 0 ;;
  esac

  local field raw resolved
  field="$(wv_edit_target_field "$WV_TOOL")"
  raw="$(wv_json ".tool_input.$field // empty")"
  resolved="$(wv_resolve_input_path "$raw")" || return 0

  # Outside the project root entirely: silent no-op. The orchestrator does
  # not implement anywhere, so this is about not false-NO-GOing its own
  # analysis and handoff files, which live outside the project by design.
  wv_inside_root "$resolved" || return 0

  local rel="${resolved#"$WV_ROOT"/}"

  # The `.wave/` exemption is a DIRECTORY prefix, decided AFTER realpath —
  # never a string prefix (`.wavefile.ts` does not qualify) and never
  # launderable through a symlink under `.wave/` that resolves outside it.
  case "$rel" in
    .wave|.wave/*) return 0 ;;
  esac

  # Untracked: a scratch file is never a false NO-GO.
  git -C "$WV_ROOT" ls-files --error-unmatch -- "$rel" >/dev/null 2>&1 || return 0

  # The allow-list: deliverables the framework assigns to the orchestrator
  # itself (README.md, CHANGELOG.md, CONTINUE-HERE.md, docs/**).
  wv_writable_allowed "$rel" && return 0

  wv_rule_deny W-EDIT "$resolved"
  return 0
}

wv_main
wv_emit_flush
exit 0
