set -u
lo_c="$WV_RUN_TMP/$name.json"
lo_base="$WV_TESTS_DIR/cases/leftover-423-terminal-warn.json"
lo_cp=""
lo_case() { jq "$1" "$lo_base" > "$lo_c" || exit 1; }
lo_run() {
  run_hook "$1" "$lo_c" || fail 'hook invocation failed'
  printf 'RAN %s %s decision=%s\n' "$1" "$name" "$(_wv_classify_decision)" >> "$log"
}
lo_checkpoint() {
  lo_cp=""
  local f
  for f in "$WV_PROJECT"/.wave/checkpoints/*.md; do
    [ -f "$f" ] || continue
    if [ -z "$lo_cp" ] || [ "$f" -nt "$lo_cp" ]; then lo_cp="$f"; fi
  done
  [ -n "$lo_cp" ] || fail 'checkpoint missing'
}
lo_contains() { command grep -Fq -- "$1" "$lo_cp" 2>/dev/null || fail "checkpoint lacks: $1"; }
