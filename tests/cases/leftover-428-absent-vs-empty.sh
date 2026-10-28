#!/usr/bin/env bash
set -u
source "$(dirname "$0")/../lib/assert.sh"
name="${WV_CASE_NAME:-$(basename "$0" .sh)}"
log="${WV_CASE_LOG:-$WV_RUN_TMP/logs/$name.log}"
rc=0
fail() { printf 'ASSERT FAIL: %s\n' "$*" >&2; rc=1; }
source "$WV_TESTS_DIR/fixtures/leftover-case.sh"

for variant in tasks crons empty missing malformed empty-ledger; do
  WV_PROJECT="$(mkproj)"
  case "$variant" in
    # An empty ledger is not a solo signal, so this variant is the full-mode
    # Stop on a complete wave that is not closed: the inventory is taken
    # anyway and the Stop says W-STATE (it never closes a wave), never W-LEFTOVER.
    empty-ledger) lo_case '.seed.state = "state/full-all-done.json" | .seed.files[".wave/ledger.jsonl"] = ""' ;;
    tasks) lo_case '.stdin.background_tasks = [{id:"task-z",type:"shell",status:"running"}]' ;;
    crons) lo_case '.stdin.background_tasks = [] | .stdin.session_crons = [{id:"cron-z"}]' ;;
    empty) lo_case '.stdin.background_tasks = [] | .seed.files[".wave/.scorecard-printed"] = ""' ;;
    missing) lo_case 'del(.stdin.background_tasks)' ;;
    malformed) lo_case '.stdin.background_tasks = [] | .stdin.session_crons = {}' ;;
  esac
  lo_run stop.sh
  case "$variant" in
    empty) assert_silent || rc=1 ;;
    empty-ledger) assert_warn W-STATE || rc=1 ;;
    *) assert_warn W-LEFTOVER || rc=1 ;;
  esac
  lo_checkpoint
  case "$variant" in
    empty-ledger) assert_reason_contains 'leftovers found' || rc=1; lo_contains b2 ;;
    tasks) assert_reason_contains task-z || rc=1; lo_contains task-z ;;
    crons) assert_reason_contains cron-z || rc=1; lo_contains cron-z ;;
    empty) lo_contains 'tasks=none; crons=none; watchers=none; unavailable=none' ;;
    missing) assert_reason_contains 'unavailable=background_tasks' || rc=1 ;;
    malformed) assert_reason_contains 'unavailable=session_crons' || rc=1 ;;
  esac
done

exit $rc
