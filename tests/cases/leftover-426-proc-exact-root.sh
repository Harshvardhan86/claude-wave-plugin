#!/usr/bin/env bash
set -u
source "$(dirname "$0")/../lib/assert.sh"
name="${WV_CASE_NAME:-$(basename "$0" .sh)}"
log="${WV_CASE_LOG:-$WV_RUN_TMP/logs/$name.log}"
rc=0
fail() { printf 'ASSERT FAIL: %s\n' "$*" >&2; rc=1; }
source "$WV_TESTS_DIR/fixtures/leftover-case.sh"

WV_PROJECT="$(mkproj)"
seed_state state/full-all-done.json
sibling="$WV_PROJECT-sibling"
worktree="$WV_PROJECT/$(jq -r '.stdin.cwd' "$WV_TESTS_DIR/cases/lib-root-worktree.json")"
mkdir -p "$sibling" "$worktree"
(cd "$WV_PROJECT" && exec sleep 1000) & root_pid=$!
(cd "$sibling" && exec sleep 1000) & spared_pid=$!
(cd "$worktree" && exec sleep 1000) & worktree_pid=$!
trap 'kill "$root_pid" "$spared_pid" "$worktree_pid" 2>/dev/null; wait 2>/dev/null' EXIT
lo_case '.stdin.background_tasks = []'
lo_run stop.sh
assert_warn W-LEFTOVER || rc=1
lo_checkpoint
lo_contains "watcher: $root_pid "
lo_contains 'sleep 1000'
nwatch="$(command grep -c '^- watcher: ' "$lo_cp" || true)"
[ "$nwatch" = "1" ] || fail "expected exactly 1 watcher pid, got $nwatch"
lo_contains "spared: $worktree_pid"
command grep -Fq "watcher: $worktree_pid " "$lo_cp" && fail 'worktree was matched as root'
command grep -Fq "watcher: $spared_pid " "$lo_cp" && fail 'sibling cwd was matched as root'
command grep -E '^- spared-count: [0-9]+' "$lo_cp" >/dev/null || fail 'spared-count missing'
for pid in "$root_pid" "$spared_pid" "$worktree_pid"; do
  kill -0 "$pid" 2>/dev/null || fail "hook killed planted pid $pid"
done
run_cli scripts/wave-scorecard.sh
[ "$CLI_EXIT" = 0 ] || fail 'scorecard failed'
case "$CLI_STDOUT" in *leftovers:*"$root_pid"*) : ;; *) fail 'scorecard lacks inventory' ;; esac

# Simulate one vanished stat path followed by another unreadable cwd.
# Stable framing must keep the first process's cwd attached to its own pid.
shim="$WV_RUN_TMP/$name-bin"
mkdir -p "$shim"
real_readlink="$(command -v readlink)"
cat > "$shim/readlink" <<EOF
#!/usr/bin/env bash
set -u
args=()
for arg in "\$@"; do
  case "\$arg" in "/proc/$root_pid/stat"|"/proc/$spared_pid/cwd") continue ;; esac
  args+=("\$arg")
done
exec "$real_readlink" "\${args[@]}"
EOF
chmod +x "$shim/readlink"
lo_case '.stdin.background_tasks = []'
jq --arg path "$shim:$PATH" '.env.PATH = $path' "$lo_c" > "$lo_c.tmp" && mv "$lo_c.tmp" "$lo_c"
lo_run stop.sh
lo_checkpoint
lo_contains "watcher: $root_pid "
command grep -Fq "watcher: $spared_pid " "$lo_cp" && fail 'a vanished marker shifted cwd onto another pid'
command grep -E '^- unreadable: [1-9][0-9]* pid' "$lo_cp" >/dev/null || fail 'unreadable count missing after vanished cwd'

exit $rc
