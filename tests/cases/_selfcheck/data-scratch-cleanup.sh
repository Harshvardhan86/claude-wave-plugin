#!/usr/bin/env bash
# tests/cases/_selfcheck/data-scratch-cleanup.sh — harness scratch hygiene.
#
# The harness creates ${TMPDIR:-/tmp}/wave-plugin-tests.XXXXXX per run
# (tests/lib/assert.sh). Proves, in an isolated synthetic copy of the harness
# under a PRIVATE TMPDIR, that the run directory:
#   (a) is removed on exit when every case passed;
#   (b) is KEPT, and its path printed, when any case failed, with the failing
#       case's log still inside it;
#   (c) is kept and printed when WV_KEEP_TMP=1 even on a green run;
#   (d) is never removed when the caller supplied WV_RUN_TMP;
#   (e) is handled the same way for a case file run standalone, outside
#       run.sh (removed when it passed, kept when it failed);
#   (f) is removed by the EXIT trap when the run is interrupted;
#   (g) is handled the same way for a REAL case file that registers its own
#       EXIT cleanup (tests/cases/data-reasons.sh, which removes a mutated
#       copy of reasons.tsv it writes under TMPDIR): run standalone it removes
#       both its own file and the scratch directory when it passed, and when
#       it failed it still removes its own file but keeps the scratch
#       directory and prints its path. A case cleanup must compose with the
#       scratch cleanup, never replace it (tests/lib/assert.sh wv_on_exit).
# The synthetic copy has its own empty cases/ (the real corpus would make this
# file discoverable by the nested run, which would then run itself).
set -u

# shellcheck source=tests/lib/assert.sh
source "$(dirname "$0")/../../lib/assert.sh"

name="${WV_CASE_NAME:-$(basename "$0" .sh)}"
if [ -n "${WV_CASE_LOG:-}" ]; then
  printf 'RAN %s %s decision=silent\n' "${BASH_SOURCE[0]}" "$name" >> "$WV_CASE_LOG"
fi

rc=0
fail() { printf '%s\n' "$*" >&2; rc=1; }

REPO_ROOT="$(git rev-parse --show-toplevel)"
sandbox="$(mktemp -d "$WV_RUN_TMP/scratch-cleanup-sandbox.XXXXXX")"
wv_on_exit 'chmod -R u+rwX "$sandbox" 2>/dev/null; rm -rf "$sandbox"'

mkdir -p "$sandbox/tests/lib" "$sandbox/tests/cases" "$sandbox/hooks"
cp "$REPO_ROOT/tests/run.sh" "$sandbox/tests/run.sh"
cp "$REPO_ROOT/tests/lib/assert.sh" "$sandbox/tests/lib/assert.sh"
printf '# synthetic\nrule_id\tprecedence\tprintf_template\n' > "$sandbox/hooks/reasons.tsv"

mkcase() {
  # mkcase <file> <body-after-marker>
  cat > "$sandbox/tests/cases/$1" <<CASE
#!/usr/bin/env bash
set -u
source "\$(dirname "\$0")/../lib/assert.sh"
log="\${WV_CASE_LOG:-\$WV_RUN_TMP/logs/$1.log}"
printf 'RAN %s\n' "$1" >> "\$log"
$2
CASE
}
mkcase green-case.sh 'exit 0'
mkcase red-case.sh 'printf "ASSERT FAIL: planted\n" >&2; exit 1'
mkcase slow-case.sh 'sleep 4; exit 0'

private="$sandbox/private-tmp"
rm -rf "$private"; mkdir -p "$private"
runs() { find "$private" -maxdepth 1 -type d -name 'wave-plugin-tests.*' 2>/dev/null | sort; }
nruns() { runs | wc -l | tr -d ' '; }
clean_env() { env -u WV_RUN_TMP -u WV_KEEP_TMP -u WV_CASE_LOG -u WV_CASE_NAME TMPDIR="$private" "$@"; }

# ---- (a) green run: directory removed --------------------------------------
out="$(cd "$sandbox" && clean_env bash tests/run.sh --filter 'green-case' 2>&1)"; r=$?
[ "$r" = "0" ] || fail "(a) green run exited $r: $out"
[ "$(nruns)" = "0" ] || fail "(a) a green run left its scratch directory behind: $(runs)"

# ---- (b) red run: directory kept, path printed, case log inside ------------
out="$(cd "$sandbox" && clean_env bash tests/run.sh --filter 'red-case' 2>&1)"; r=$?
[ "$r" != "0" ] || fail "(b) the planted failing run exited 0"
[ "$(nruns)" = "1" ] || fail "(b) a failed run must keep exactly one scratch directory, found $(nruns)"
kept="$(runs)"
case "$out" in *"$kept"*) : ;; *) fail "(b) a failed run must print the kept directory path ($kept); got: $out" ;; esac
[ -f "$kept/logs/red-case.log" ] || fail "(b) the failing case's log is not inside the kept directory"
rm -rf "$kept"

# ---- (c) WV_KEEP_TMP=1: kept and printed even when green -------------------
out="$(cd "$sandbox" && clean_env env WV_KEEP_TMP=1 bash tests/run.sh --filter 'green-case' 2>&1)"; r=$?
[ "$r" = "0" ] || fail "(c) green run with WV_KEEP_TMP=1 exited $r"
[ "$(nruns)" = "1" ] || fail "(c) WV_KEEP_TMP=1 must keep the directory, found $(nruns)"
kept="$(runs)"
case "$out" in *"$kept"*) : ;; *) fail "(c) WV_KEEP_TMP=1 must print the kept path; got: $out" ;; esac
rm -rf "$kept"

# ---- (d) a caller-supplied WV_RUN_TMP is never removed ---------------------
supplied="$sandbox/supplied-run-tmp"; mkdir -p "$supplied"
out="$(cd "$sandbox" && env -u WV_KEEP_TMP TMPDIR="$private" WV_RUN_TMP="$supplied" bash tests/run.sh --filter 'green-case' 2>&1)"; r=$?
[ "$r" = "0" ] || fail "(d) green run with a supplied WV_RUN_TMP exited $r"
[ -d "$supplied" ] || fail "(d) a caller-supplied WV_RUN_TMP was removed"
[ "$(nruns)" = "0" ] || fail "(d) a supplied WV_RUN_TMP must not create a second directory"

# ---- (e) a case file run standalone ----------------------------------------
clean_env bash "$sandbox/tests/cases/green-case.sh" >/dev/null 2>&1; r=$?
[ "$r" = "0" ] || fail "(e) standalone green case exited $r"
[ "$(nruns)" = "0" ] || fail "(e) a passing standalone case left its scratch directory: $(runs)"
clean_env bash "$sandbox/tests/cases/red-case.sh" >/dev/null 2>&1; r=$?
[ "$r" != "0" ] || fail "(e) standalone red case exited 0"
[ "$(nruns)" = "1" ] || fail "(e) a failing standalone case must keep its scratch directory, found $(nruns)"
rm -rf "$(runs)"

# ---- (f) an interrupted run is cleaned by the EXIT trap --------------------
# The subshell execs the harness, so $runner IS the harness pid (an exact pid,
# never a pattern scan). The slow case sleeps 4 s and ends on its own, so
# nothing outlives this block; the harness acts on the signal when it returns.
( cd "$sandbox" && exec env -u WV_RUN_TMP -u WV_KEEP_TMP -u WV_CASE_LOG -u WV_CASE_NAME TMPDIR="$private" \
    bash tests/run.sh --filter 'slow-case' >/dev/null 2>&1 ) &
runner=$!
waited=0
while [ "$(nruns)" = "0" ] && [ "$waited" -lt 50 ]; do sleep 0.1; waited=$((waited + 1)); done
[ "$(nruns)" = "1" ] || fail "(f) the interrupted run never created its directory"
kill -TERM "$runner" 2>/dev/null
waited=0
while kill -0 "$runner" 2>/dev/null && [ "$waited" -lt 150 ]; do sleep 0.1; waited=$((waited + 1)); done
if kill -0 "$runner" 2>/dev/null; then
  kill -KILL "$runner" 2>/dev/null
  fail "(f) the interrupted run did not exit within its ceiling"
fi
wait "$runner" 2>/dev/null
[ "$(nruns)" = "0" ] || fail "(f) an interrupted run left its scratch directory behind: $(runs)"

# ---- (g) a real case with its own EXIT cleanup, standalone -----------------
mutated() { find "$private" -maxdepth 1 -name 'reasons-mutated.*' 2>/dev/null; }
out="$(clean_env bash "$REPO_ROOT/tests/cases/data-reasons.sh" 2>&1)"; r=$?
[ "$r" = "0" ] || fail "(g) the real data-reasons.sh exited $r standalone: $out"
[ -z "$(mutated)" ] || fail "(g) green: data-reasons.sh's own cleanup did not run: $(mutated)"
[ "$(nruns)" = "0" ] || fail "(g) green: a real standalone case with its own EXIT cleanup left its scratch directory: $(runs)"
rm -rf $(runs) 2>/dev/null

# Red: the same real file in a minimal copy of the tree whose reasons.tsv
# lost a remedy clause, so the case fails on its own assertions.
realred="$sandbox/real-red"
mkdir -p "$realred/tests/lib" "$realred/tests/cases" "$realred/tests/golden" "$realred/hooks"
git -C "$realred" init -q
cp "$REPO_ROOT/tests/lib/assert.sh" "$realred/tests/lib/assert.sh"
cp "$REPO_ROOT/tests/cases/data-reasons.sh" "$realred/tests/cases/data-reasons.sh"
cp "$REPO_ROOT/tests/golden/reasons-precedence.tsv" "$realred/tests/golden/reasons-precedence.tsv"
sed '0,/; remedy:/s//; fix:/' "$REPO_ROOT/hooks/reasons.tsv" > "$realred/hooks/reasons.tsv"
out="$(cd "$realred" && clean_env bash tests/cases/data-reasons.sh 2>&1)"; r=$?
[ "$r" != "0" ] || fail "(g) red: the planted reasons.tsv did not make data-reasons.sh fail"
[ -z "$(mutated)" ] || fail "(g) red: data-reasons.sh's own cleanup did not run on a failure: $(mutated)"
[ "$(nruns)" = "1" ] || fail "(g) red: a failing real standalone case must keep exactly one scratch directory, found $(nruns)"
kept="$(runs)"
case "$out" in *"tests: scratch directory kept at $kept"*) : ;; *) fail "(g) red: the kept directory ($kept) was not printed; got: $out" ;; esac
rm -rf "$kept"

# No case may install its own EXIT trap: it would replace the composed one.
# grep exits 1 for "no match" and 2 for a scan that did not run; only 1 passes.
raw_traps="$(command grep -rlE "^[[:space:]]*trap .*EXIT" "$REPO_ROOT/tests/cases")"; g=$?
case "$g" in
  1) : ;;
  0) fail "(g) case file(s) install their own EXIT trap instead of wv_on_exit: $raw_traps" ;;
  *) fail "(g) the EXIT-trap scan of tests/cases did not run (grep exit $g)" ;;
esac

exit $rc
