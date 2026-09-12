#!/usr/bin/env bash
set -u
source "$(dirname "$0")/../lib/assert.sh"
name="${WV_CASE_NAME:-$(basename "$0" .sh)}"
log="${WV_CASE_LOG:-$WV_RUN_TMP/logs/$name.log}"
rc=0
fail() { printf 'ASSERT FAIL: %s\n' "$*" >&2; rc=1; }
c="$WV_RUN_TMP/$name.json"
base="$WV_TESTS_DIR/cases/bgwait-405-running-block.json"
printf 'RAN subagent-stop.sh %s decision=multi\n' "$name" >> "$log"
source "$WV_TESTS_DIR/fixtures/bgwait-case.sh"

make_case '.seed.files[".wave/state.json"] |= (fromjson | .mode = "solo" | tojson)'
run_stop
assert_silent || rc=1
assert_state '.bg_blocked == null and .bg_orphaned == null' || rc=1
WV_PROJECT="$(mkproj)"
make_case '.seed.files[".wave/state.json"] |= (fromjson | .enforce = "warn" | tojson)'
run_stop
assert_allow || rc=1
assert_state '.bg_blocked == null and .phases.AC.status == "done" and .bg_orphaned.a1.ids == ["b2emx28v6"]' || rc=1
assert_ledger_lines 1 || rc=1
assert_ledger_line '.bg_orphaned == ["b2emx28v6"] and any(.warn[]; contains("[W-BGWAIT]"))' || rc=1
# No map, missing array and malformed arrays are unmeasured, not a block.
for filter in 'del(.stdin.background_tasks)' '.stdin.background_tasks = {}' '.seed.files[".wave/state.json"] |= (fromjson | del(.bg_tasks) | tojson)'; do
  WV_PROJECT="$(mkproj)"
  make_case "$filter"
  run_stop
  assert_allow || rc=1
  assert_state '.bg_blocked == null and .bg_orphaned == null' || rc=1
done

# Corrupt optional maps must be diagnosed, never guessed into a new block.
for field in bg_blocked bg_orphaned; do
  for value in '[]' 'false' '"bad"' '{"a1":"bad"}'; do
    WV_PROJECT="$(mkproj)"
    make_case ".seed.files[\".wave/state.json\"] |= (fromjson | .$field = $value | tojson)"
    run_stop
    assert_allow || rc=1
    assert_stderr_contains W-STATE || rc=1
  done
done

# Fail only the orphan state update, leaving the ledger writable.
WV_PROJECT="$(mkproj)"
shim="$WV_RUN_TMP/$name-bin"
mkdir -p "$shim"
real_jq="$(command -v jq)"
cat > "$shim/jq" <<EOF
#!/usr/bin/env bash
set -u
case "\${1:-}" in '.bg_orphaned['*) exit 1 ;; esac
exec "$real_jq" "\$@"
EOF
chmod +x "$shim/jq"
make_case '.seed.files[".wave/state.json"] |= (fromjson | .enforce = "warn" | tojson)'
jq --arg path "$shim:$PATH" '.env.PATH = $path' "$c" > "$c.tmp" && mv "$c.tmp" "$c"
run_stop
assert_allow || rc=1
assert_stderr_contains W-STATE || rc=1
assert_ledger_lines 1 || rc=1
assert_ledger_line 'any(.warn[]; contains("[W-BGWAIT]"))' || rc=1
assert_state '.bg_blocked == null and .bg_orphaned == null' || rc=1

exit $rc
