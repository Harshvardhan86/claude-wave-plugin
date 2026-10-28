#!/usr/bin/env bash
# tests/cases/scorecard-005-transcript-resolved.sh
#
# The Model column shows the ledger's resolved id. When the id came from the
# agent transcript rather than the launch's tool_response (a foreground
# dispatch: subagent-stop.sh ledgers it with resolved_from "transcript"), the
# cell says so in words; a tool_response id is shown bare. A dispatch ledgered
# with `downgraded: true` (served below the requested tier) is marked in the same
# cell with the tier it asked for, whichever hook made the comparison; a
# `downgraded: false` or absent flag adds nothing.
set -u

# shellcheck source=tests/lib/assert.sh
source "$(dirname "$0")/../lib/assert.sh"

name="$(basename "$0" .sh)"
log="${WV_CASE_LOG:-$WV_RUN_TMP/logs/$name.log}"
mkdir -p "$(dirname "$log")"

rc=0
fail() { printf 'ASSERT FAIL: %s\n' "$*" >&2; rc=1; }

WV_PROJECT="$(mkproj)"
seed_state state/valid-full.json

cat > "$WV_PROJECT/.wave/ledger.jsonl" <<'LEDGER'
{"agent":"a1","phase":"AD","role":"executor","requested":"haiku","resolved":"claude-haiku-4-5-20251001","resolved_from":"transcript","downgraded":false,"output":100}
{"agent":"a2","phase":"AC","role":"reviewer","requested":"opus","resolved":"claude-opus-5","output":200}
{"agent":"a3","phase":"DR","role":"reviewer","requested":"opus","resolved":"claude-haiku-4-5-20251001","resolved_from":"transcript","downgraded":true,"output":300}
{"agent":"a4","phase":"TDE-RED","role":"executor","requested":"sonnet","resolved":"claude-haiku-5-5","downgraded":true,"output":400}
LEDGER

run_cli scripts/wave-scorecard.sh
[ "$CLI_EXIT" = "0" ] || fail "exit: want 0, got $CLI_EXIT (stderr: $CLI_STDERR)"

printf '%s\n' "$CLI_STDOUT" | command grep -qF '| AD | executor | claude-haiku-4-5-20251001 (from the agent transcript) | 100 |' \
  || fail "the transcript-resolved row must name the id and say it came from the agent transcript: $(printf '%s\n' "$CLI_STDOUT" | command grep -F '| AD |')"
printf '%s\n' "$CLI_STDOUT" | command grep -qF '| AC | reviewer | claude-opus-5 | 200 |' \
  || fail "the tool_response row must show the bare id: $(printf '%s\n' "$CLI_STDOUT" | command grep -F '| AC |')"
printf '%s\n' "$CLI_STDOUT" | command grep -qF '| DR | reviewer | claude-haiku-4-5-20251001 (from the agent transcript; DOWNGRADED from requested opus) | 300 |' \
  || fail "a downgraded transcript row must say both: $(printf '%s\n' "$CLI_STDOUT" | command grep -F '| DR |')"
printf '%s\n' "$CLI_STDOUT" | command grep -qF '| TDE-RED | executor | claude-haiku-5-5 (DOWNGRADED from requested sonnet) | 400 |' \
  || fail "a downgraded tool_response row must be marked: $(printf '%s\n' "$CLI_STDOUT" | command grep -F '| TDE-RED |')"
n_dg="$(printf '%s\n' "$CLI_STDOUT" | command grep -cF 'DOWNGRADED')"
[ "$n_dg" = "2" ] || fail "exactly the two downgraded rows are marked, got $n_dg"
n_unknown="$(printf '%s\n' "$CLI_STDOUT" | command grep -cF '| unknown |')"
[ "$n_unknown" = "0" ] || fail "no Model cell may read unknown here, got $n_unknown"

exit $rc
