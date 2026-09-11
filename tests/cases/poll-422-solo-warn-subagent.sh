#!/usr/bin/env bash
set -u
source "$(dirname "$0")/../lib/assert.sh"
name="${WV_CASE_NAME:-$(basename "$0" .sh)}"
log="${WV_CASE_LOG:-$WV_RUN_TMP/logs/$name.log}"
rc=0
c="$WV_RUN_TMP/$name.json"
for script in pre-bash.sh pre-monitor.sh; do
  base="$WV_TESTS_DIR/cases/poll-415-while-true-deny.json"
  [ "$script" = pre-monitor.sh ] && base="$WV_TESTS_DIR/cases/poll-419-monitor-subagent-deny.json"
  for scenario in full demo solo warn closed no-wave wrong-event wrong-tool main-malformed-input; do
    WV_PROJECT="$(mkproj)"
    seed_state state/valid-full.json
    jq '.stdin.agent_id = "a1" | del(.seed)' "$base" > "$c" || exit 1
    case "$scenario" in
      demo|solo) jq --arg mode "$scenario" '.mode = $mode' "$WV_PROJECT/.wave/state.json" > "$c.state" && mv "$c.state" "$WV_PROJECT/.wave/state.json" ;;
      warn) jq '.enforce = "warn"' "$WV_PROJECT/.wave/state.json" > "$c.state" && mv "$c.state" "$WV_PROJECT/.wave/state.json" ;;
      closed) jq '.status = "closed"' "$WV_PROJECT/.wave/state.json" > "$c.state" && mv "$c.state" "$WV_PROJECT/.wave/state.json" ;;
      no-wave) rm "$WV_PROJECT/.wave/state.json" ;;
      wrong-event) jq '.stdin.hook_event_name = "PostToolUse"' "$c" > "$c.tmp" && mv "$c.tmp" "$c" ;;
      wrong-tool) jq '.stdin.tool_name = "Read"' "$c" > "$c.tmp" && mv "$c.tmp" "$c" ;;
      main-malformed-input)
        [ "$script" = pre-monitor.sh ] || continue
        jq 'del(.stdin.agent_id) | .stdin.tool_input = "not an object"' "$c" > "$c.tmp" && mv "$c.tmp" "$c" ;;
    esac
    run_hook "$script" "$c" || rc=1
    case "$scenario" in
      full|demo) assert_deny W-POLL || rc=1 ;;
      warn) assert_warn W-POLL || rc=1 ;;
      *) assert_silent || rc=1 ;;
    esac
    printf 'RAN %s %s#%s decision=%s\n' "$script" "$name" "$scenario" "$(_wv_classify_decision)" >> "$log"
  done
done
exit $rc
