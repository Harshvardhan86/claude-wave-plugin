#!/usr/bin/env bash
# scripts/wave-set.sh — records a scope answer while a wave is active.
#
# Usage: wave-set.sh ui|behaviour-change|cr true|false
#
# Sets the matching state.json field and appends one dated line to
# .wave/approvals/scope.md. An unknown key or a non-boolean value exits
# non-zero before anything is touched (state byte-identical, AC-362).
#
# Reuses scripts/hooks/lib.sh's wv_project_root / wv_state_read /
# wv_state_update rather than re-implementing root resolution or the locked
# read-modify-write.
set -u

WV_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/hooks/lib.sh
source "$WV_SCRIPT_DIR/hooks/lib.sh"

wv_die() {
  printf 'wave-set.sh: %s\n' "$*" >&2
  exit 1
}

key="${1:-}"
val="${2:-}"

field=""
case "$key" in
  ui) field="ui" ;;
  behaviour-change) field="behaviour_change" ;;
  cr) field="cr_enabled" ;;
  *) wv_die "unknown key: '$key' (want ui, behaviour-change, or cr)" ;;
esac

case "$val" in
  true|false) : ;;
  *) wv_die "value must be true or false, got '$val'" ;;
esac

wv_project_root || wv_die "no project found from $PWD (no active wave)"

if ! wv_state_read; then
  case "$WV_STATUS" in
    closed) wv_die "the wave at $WV_ROOT/.wave/state.json is closed; nothing to set" ;;
    *) wv_die "no active wave found at $WV_ROOT/.wave/state.json; run scripts/wave-init.sh first" ;;
  esac
fi

if ! wv_state_update ".${field} = ${val}"; then
  wv_die "could not write $WV_STATE_FILE"
fi

ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$WV_WAVE_DIR/approvals"
printf '%s %s=%s\n' "$ts" "$key" "$val" >> "$WV_WAVE_DIR/approvals/scope.md"

printf 'wave-set.sh: %s set to %s\n' "$key" "$val"
exit 0
