#!/usr/bin/env bash
# tests/cases/lib-state-unknown.sh — the state file as `wave-init.sh` actually
# writes it (spec section 4): `ui`, `behaviour_change` and `cr_enabled` all
# `"unknown"`, not `false`.
#
# That is the deploy-day default and the one every later wave inherits: a
# `false` there silently switches off `[DR]` and the visual gate, which is the
# failure the framework's own rule exists to prevent. So the library has to
# carry `"unknown"` through as a first-class value — neither rejected as
# unreadable state nor flattened to a boolean — and enforcement has to keep
# working while it is set, because Task 6 denies a `TDE-RED` dispatch precisely
# ON that value.
#
# `tests/fixtures/state/valid-full.json` keeps the explicit-`false` shape; this
# case pins the `"unknown"` one.
set -u

# shellcheck source=tests/lib/assert.sh
source "$(dirname "$0")/../lib/assert.sh"

name="$(basename "$0" .sh)"
rc=0
fail() { printf 'ASSERT FAIL: %s\n' "$*" >&2; rc=1; }

fixture="$WV_TESTS_DIR/fixtures/state/unknown-scope.json"
if [ ! -f "$fixture" ]; then
  printf 'ASSERT FAIL: the documented initial-state fixture is missing: %s\n' "$fixture" >&2
  exit 1
fi

# --- it is valid state, and enforcement still fires on it ------------------
case_file="$WV_RUN_TMP/$name.json"
jq -n '{
  script: "tests/fixtures/drive-lib.sh",
  env: { WV_DRIVE: "deny:W-TAG" },
  seed: { state: "state/unknown-scope.json" },
  stdin: {
    hook_event_name: "PreToolUse",
    tool_name: "Agent",
    cwd: ".",
    tool_input: {
      description: "probe dispatch",
      prompt: "Do the thing.",
      subagent_type: "general-purpose",
      model: "sonnet"
    },
    tool_use_id: "toolu_016jDXUebmA9qCw58g1rxGuH"
  }
}' > "$case_file"

WV_PROJECT=""
if ! run_hook tests/fixtures/drive-lib.sh "$case_file"; then
  printf 'run_hook could not run the driver: %s\n' "$WV_LAST_STDERR" >&2
  exit 1
fi
assert_exit 0 || rc=1
assert_deny W-TAG || rc=1        # "unknown" is not a reason to stop enforcing
case "$WV_LAST_STDOUT" in
  *W-STATE*) fail "the documented initial state must not be reported as unreadable: '$WV_LAST_STDOUT'" ;;
esac
assert_state '.ui == "unknown" and .behaviour_change == "unknown" and .cr_enabled == "unknown"' || rc=1

# --- and the library exports the three values verbatim ---------------------
# Read directly, because the values the later waves gate on are library
# variables, not anything that reaches stdout.
# shellcheck source=scripts/hooks/lib.sh
source "$WV_REPO_ROOT/scripts/hooks/lib.sh"

WV_PARSED=1
WV_EVENT="PreToolUse"
WV_CWD="$WV_PROJECT"
wv_project_root || fail "wv_project_root did not resolve $WV_PROJECT"
if wv_state_read; then
  [ "$WV_STATE_OK" = "1" ] || fail "WV_STATE_OK: want 1, got $WV_STATE_OK"
  [ "$WV_UI" = "unknown" ] || fail "WV_UI: want unknown, got '$WV_UI'"
  [ "$WV_BC" = "unknown" ] || fail "WV_BC: want unknown, got '$WV_BC'"
  [ "$WV_CR" = "unknown" ] || fail "WV_CR: want unknown, got '$WV_CR'"
  [ "$WV_MODE" = "full" ] || fail "WV_MODE: want full, got '$WV_MODE'"
  [ "$WV_ENFORCE" = "block" ] || fail "WV_ENFORCE: want block, got '$WV_ENFORCE'"
  [ "$WV_WAVE" = "1" ] || fail "WV_WAVE: want 1, got '$WV_WAVE'"
  [ -z "$WV_WARNINGS" ] || fail "the documented initial state queued a warning: '$WV_WARNINGS'"
else
  fail "wv_state_read refused the documented initial state (warnings: '$WV_WARNINGS')"
fi

# the explicit-false shape still reads as false, not as unknown
seed_state state/valid-full.json
if wv_state_read; then
  [ "$WV_UI" = "false" ] || fail "explicit false: WV_UI: want false, got '$WV_UI'"
  [ "$WV_BC" = "false" ] || fail "explicit false: WV_BC: want false, got '$WV_BC'"
  [ "$WV_CR" = "false" ] || fail "explicit false: WV_CR: want false, got '$WV_CR'"
else
  fail "wv_state_read refused valid-full.json"
fi

exit $rc
