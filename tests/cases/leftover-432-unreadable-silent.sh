#!/usr/bin/env bash
# Plant one unreadable cwd; with nothing else leftover the Stop is silent of
# W-LEFTOVER (unreadable is counted, never a verdict). Clean path still prints
# W-SCORECARD.
set -u
source "$(dirname "$0")/../lib/assert.sh"
name="${WV_CASE_NAME:-$(basename "$0" .sh)}"
log="${WV_CASE_LOG:-$WV_RUN_TMP/logs/$name.log}"
rc=0
fail() { printf 'ASSERT FAIL: %s\n' "$*" >&2; rc=1; }
source "$WV_TESTS_DIR/fixtures/leftover-case.sh"

WV_PROJECT="$(mkproj)"
sleep 1000 & probe_pid=$!
trap 'kill "$probe_pid" 2>/dev/null; wait 2>/dev/null' EXIT
shim="$WV_RUN_TMP/$name-bin"
mkdir -p "$shim"
real_readlink="$(command -v readlink)"
cat > "$shim/readlink" <<EOF
#!/usr/bin/env bash
set -u
args=()
for arg in "\$@"; do [ "\$arg" = "/proc/$probe_pid/cwd" ] || args+=("\$arg"); done
exec "$real_readlink" "\${args[@]}"
EOF
chmod +x "$shim/readlink"
lo_case '.stdin.background_tasks = []'
jq --arg path "$shim:$PATH" '.env.PATH = $path' "$lo_c" > "$lo_c.tmp" && mv "$lo_c.tmp" "$lo_c"
lo_run stop.sh
assert_warn W-SCORECARD || rc=1
case "$WV_LAST_STDOUT" in
  *W-LEFTOVER*) fail 'unreadable cwd changed the leftover verdict' ;;
esac
lo_checkpoint
command grep -E '^- unreadable: [1-9][0-9]* pid' "$lo_cp" >/dev/null || fail 'unreadable count missing'
command grep -Fq "spared: $probe_pid " "$lo_cp" && fail 'unreadable cwd was described as spared'
command grep -Fq "watcher: $probe_pid " "$lo_cp" && fail 'unreadable cwd was described as a watcher'

exit $rc
