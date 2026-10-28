#!/usr/bin/env bash
# tests/cases/init-created-by.sh — wave-init.sh records which plugin release
# created the wave: `created_by` in state.json equals the `version` of
# .claude-plugin/plugin.json (read as data). The field is additive (schema
# stays 1; a state without it was created before 0.3.0), and
# scripts/wave-set.sh never changes it, because a later release keys row
# exemptions on it.
set -u

# shellcheck source=tests/lib/assert.sh
source "$(dirname "$0")/../lib/assert.sh"

name="$(basename "$0" .sh)"
log="${WV_CASE_LOG:-$WV_RUN_TMP/logs/$name.log}"
mkdir -p "$(dirname "$log")"
rc=0
fail() { printf 'ASSERT FAIL: %s\n' "$*" >&2; rc=1; }

want="$(jq -r '.version // empty' "$WV_REPO_ROOT/.claude-plugin/plugin.json")"
[ -n "$want" ] || fail "plugin.json has no version"

WV_PROJECT="$(mkproj)"
: > "$WV_PROJECT/README.md"
git -C "$WV_PROJECT" add README.md
git -C "$WV_PROJECT" commit -q -m init
run_cli scripts/wave-init.sh --wave 1 --mode full --feature x
[ "$CLI_EXIT" = "0" ] || fail "init: exit $CLI_EXIT ($CLI_STDERR)"
st="$WV_PROJECT/.wave/state.json"
got="$(jq -r '.created_by // "ABSENT"' "$st")"
[ "$got" = "$want" ] || fail "created_by is '$got', want the manifest version '$want'"
jq -e '.schema == 1' "$st" >/dev/null || fail "schema must stay 1"

for kv in "vocabulary true" "behaviour-change false" "ui false" "cr true"; do
  # shellcheck disable=SC2086
  run_cli scripts/wave-set.sh $kv
  [ "$CLI_EXIT" = "0" ] || fail "wave-set $kv: exit $CLI_EXIT ($CLI_STDERR)"
  got="$(jq -r '.created_by // "ABSENT"' "$st")"
  [ "$got" = "$want" ] || fail "wave-set $kv changed created_by to '$got'"
done
run_cli scripts/wave-set.sh created_by 9.9.9
[ "$CLI_EXIT" != "0" ] || fail "wave-set must refuse the created_by key"
[ "$(jq -r '.created_by' "$st")" = "$want" ] || fail "a refused wave-set changed created_by"

exit $rc
