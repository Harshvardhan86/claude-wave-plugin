#!/usr/bin/env bash
# scripts/hooks/pre-monitor.sh — the PreToolUse hook on `Monitor`.
# Task 2 installs a silent entry point; Task 4 adds the session identity gate.
set -u

WV_HOOK_DIR="$(cd "${BASH_SOURCE[0]%/*}" 2>/dev/null && pwd)"
# shellcheck source=scripts/hooks/lib.sh
source "$WV_HOOK_DIR/lib.sh"

# Do not parse stdin yet: even malformed input must leave this stub silent.
wv_emit_flush
exit 0
