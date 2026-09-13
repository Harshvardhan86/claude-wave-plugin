set -u
# Shared case driver; c, base and fail are provided by the calling case.
make_case() {
  jq --rawfile state "$WV_TESTS_DIR/fixtures/state/bgwait-ac-reviewer.json" \
    '.seed.files[".wave/state.json"] //= $state | del(.seed.state)' "$base" > "$c.base" || exit 1
  jq "$1" "$c.base" > "$c" || exit 1
}
run_stop() { run_hook subagent-stop.sh "$c" || fail "hook run failed"; }
