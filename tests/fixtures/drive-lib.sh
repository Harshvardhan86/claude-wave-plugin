#!/usr/bin/env bash
# tests/fixtures/drive-lib.sh — a test-only driver for scripts/hooks/lib.sh.
#
# NOT a hook: never referenced by hooks/hooks.json, never wired into the
# plugin, and nothing in scripts/ knows it exists. It is the `script` field of
# every tests/cases/lib-*.{json,sh} case: it sources the library, runs the one
# library operation named by WV_DRIVE, and exits 0 — which is how the library
# is exercised before the eleven hook scripts that use it exist.
#
# Everything here is deliberately outside scripts/: an env-var-driven `jq`
# filter is fine in a fixture and would not be fine in production code that
# every hook sources on every tool call.
#
# WV_DRIVE actions:
#   (unset)                  parse, resolve the root, read the state, exit 0
#   deny:<rule>              wv_deny <rule>
#   warn:<rule>              wv_warn <rule>          (flushed on the way out)
#   block:<rule>             wv_block <rule>
#   update:<jq filter>       wv_state_update '<filter>'
#   ledger:<json line>       wv_ledger_append '<line>'
#   deny-twice:<ruleA>,<ruleB>   two wv_deny calls, back to back
#   block-twice:<ruleA>,<ruleB>  two wv_block calls, back to back
#   flush-then-deny:<rule>       wv_warn, wv_emit_flush, then wv_deny
#   deny-then-warn:<rule>        wv_deny, then a warning queued after it
#   nested-lock              acquire, acquire, release, hold, release
#                            (writes its own probe results to stdout, not JSON)
set -u

# Builtins only, and before the library is sourced: `dirname` is an external
# binary, and two of the cases run with a PATH that has none, where the library
# must produce exactly one line of stderr and nothing else.
case "$0" in
  */*) WV_DRIVER_DIR="$(cd "${0%/*}" && pwd)" ;;
  *)   WV_DRIVER_DIR="$PWD" ;;
esac

# shellcheck source=scripts/hooks/lib.sh
source "$WV_DRIVER_DIR/../../scripts/hooks/lib.sh"

wv_parse_stdin || exit 0
wv_project_root || exit 0
if ! wv_state_read; then
  wv_emit_flush
  exit 0
fi

wv_drive_action="${WV_DRIVE:-}"
case "$wv_drive_action" in
  '')
    :
    ;;
  deny:*)
    wv_deny "${wv_drive_action#deny:}" "a driver check of the deny path"
    ;;
  warn:*)
    wv_warn "${wv_drive_action#warn:}" "a driver check of the warn path"
    ;;
  block:*)
    wv_block "${wv_drive_action#block:}" "a driver check of the block path"
    ;;
  update:*)
    wv_state_update "${wv_drive_action#update:}"
    ;;
  ledger:*)
    wv_ledger_append "${wv_drive_action#ledger:}"
    ;;
  deny-twice:*)
    wv_drive_rules="${wv_drive_action#deny-twice:}"
    wv_deny "${wv_drive_rules%%,*}" "the first of two deny calls"
    wv_deny "${wv_drive_rules##*,}" "the second of two deny calls"
    ;;
  block-twice:*)
    wv_drive_rules="${wv_drive_action#block-twice:}"
    wv_block "${wv_drive_rules%%,*}" "the first of two block calls"
    wv_block "${wv_drive_rules##*,}" "the second of two block calls"
    ;;
  deny-then-warn:*)
    wv_deny "${wv_drive_action#deny-then-warn:}" "a deny before a late warning"
    wv_warn W-STATE "a warning queued after the object was already emitted"
    ;;
  flush-then-deny:*)
    wv_warn W-STATE "a driver check of a warning flushed before a deny"
    wv_emit_flush
    wv_deny "${wv_drive_action#flush-then-deny:}" "a deny after a flush"
    ;;
  nested-lock)
    # Proves nesting is safe from the inside: the outer lock must still be held
    # while a nested acquire/release pair has come and gone. The competing
    # process runs with fd 9 closed so it cannot inherit this shell's handle.
    wv_drive_lock="$WV_WAVE_DIR/lock"
    if ! wv_lock_acquire; then
      printf 'outer=FAILED\n'
      exit 0
    fi
    printf 'outer=held depth=%s\n' "$WV_LOCK_DEPTH"
    wv_lock_acquire || printf 'nested=FAILED\n'
    printf 'nested=held depth=%s\n' "$WV_LOCK_DEPTH"
    wv_lock_release
    printf 'nested-released depth=%s\n' "$WV_LOCK_DEPTH"
    if ( exec 9>&-; flock -w 1 "$wv_drive_lock" -c true ) 2>/dev/null; then
      printf 'competitor-while-outer-held=ACQUIRED\n'
    else
      printf 'competitor-while-outer-held=excluded\n'
    fi
    wv_lock_release
    printf 'outer-released depth=%s\n' "$WV_LOCK_DEPTH"
    if ( exec 9>&-; flock -w 1 "$wv_drive_lock" -c true ) 2>/dev/null; then
      printf 'competitor-after-release=acquired\n'
    else
      printf 'competitor-after-release=STILL-EXCLUDED\n'
    fi
    ;;
  *)
    printf 'drive-lib.sh: unrecognised WV_DRIVE action: %s\n' "$wv_drive_action" >&2
    ;;
esac

wv_emit_flush
exit 0
