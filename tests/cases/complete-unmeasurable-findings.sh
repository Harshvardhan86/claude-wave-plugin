#!/usr/bin/env bash
# complete-unmeasurable-findings.sh — the order gate and the completeness
# check agree on a `findings:` row whose findings file cannot be measured.
#
# A findings condition has three answers, not two: measured zero (the BF-
# row is skipped), measured positive (the BF- row must run), and
# UNMEASURABLE (a file without a `FINDINGS: n` marker, an unreadable file,
# a scan that returned no count). The gate never reads unmeasurable as a
# skip: a malformed file is denied W-MARKER, a missing file of a done scan
# W-ARTIFACT, and a failed scan fails open, which means the BF- row is
# treated as required. So `wave-close.sh --if-complete` must leave every
# one of those waves active; reading unmeasurable as "condition false"
# would close a wave whose BF- row was neither done nor legitimately
# skipped, and every later gate would then go quiet.
#
# Each leg seeds the same whole-pipeline-done full wave with BF-BC absent
# and BC done, varies only .wave/findings/BC.md, asks the gate about a
# BF-BC dispatch, then asks the closer. The unreadable leg is skipped, with
# a visible SKIP line, when this runs as root (root reads a mode-000 file).
set -u
source "$(dirname "$0")/../lib/assert.sh"
name="${WV_CASE_NAME:-$(basename "$0" .sh)}"
log="${WV_CASE_LOG:-$WV_RUN_TMP/logs/$name.log}"
rc=0
fail() { printf 'ASSERT FAIL: %s\n' "$*" >&2; rc=1; }
source "$WV_TESTS_DIR/lib/stop.sh"

st="$WV_RUN_TMP/$name-state.json"
jq 'del(.phases["BF-BC"])' "$WV_TESTS_DIR/fixtures/state/full-all-done.json" > "$st" || exit 1

mkcase() {
  # mkcase <out> <BC.md content, or the word ABSENT> -> a BF-BC dispatch
  # case seeded with every scan's FINDINGS: 0 file except BC's.
  local out="$1" content="$2" files
  files="$(stop_findings_zero | jq -c '. + {".wave/approvals/bf-BC.md": "Approved by the user on 2026-09-09.\n"}')"
  if [ "$content" = "ABSENT" ]; then
    files="$(printf '%s' "$files" | jq -c 'del(.[".wave/findings/BC.md"])')"
  else
    files="$(printf '%s' "$files" | jq -c --arg c "$content" '.[".wave/findings/BC.md"] = $c')"
  fi
  jq --arg st "$st" --argjson files "$files" '.seed = {state: $st, files: $files} | del(.expect)' \
    "$WV_TESTS_DIR/cases/cond-080-bf-bc-findings-zero-deny.json" > "$out"
}

gate() {
  # gate <case> -> runs the BF-BC dispatch against the CURRENT project.
  run_hook pre-agent.sh "$1" || fail "run_hook: $WV_LAST_STDERR"
}

closer_leaves() {
  # closer_leaves <label> <want-status>
  local label="$1" want="$2" got
  run_cli scripts/wave-close.sh --if-complete
  [ "$CLI_EXIT" = "0" ] || fail "$label: wave-close.sh --if-complete exited $CLI_EXIT: $CLI_STDERR"
  [ -z "$CLI_STDOUT" ] || fail "$label: wave-close.sh --if-complete wrote stdout: $CLI_STDOUT"
  got="$(jq -r '.status' "$WV_PROJECT/.wave/state.json")"
  [ "$got" = "$want" ] || fail "$label: the closer left status '$got', want '$want' (BC done, BF-BC absent)"
  if [ "$want" = "active" ]; then
    [ "$(jq -r '.delivery // "unset"' "$WV_PROJECT/.wave/state.json")" = "unset" ] \
      || fail "$label: a wave that stayed active must not carry a delivery verdict"
  fi
}

c="$WV_RUN_TMP/$name.json"

# ---- valid zero: the gate skips BF-BC, the wave is complete ----------------
WV_PROJECT=""
mkcase "$c" "FINDINGS: 0
"
gate "$c"
assert_deny W-COND || fail "zero: a FINDINGS: 0 scan must make the gate skip BF-BC (W-COND)"
closer_leaves zero closed

# ---- positive count: the gate runs BF-BC, the wave is not complete ---------
WV_PROJECT=""
mkcase "$c" "FINDINGS: 2
"
gate "$c"
case "$WV_LAST_STDOUT" in
  *'"permissionDecision":"deny"'*) fail "positive: a FINDINGS: 2 scan must let BF-BC run, got: $WV_LAST_STDOUT" ;;
esac
closer_leaves positive active

# ---- absent file of a done scan: W-ARTIFACT, not complete ------------------
WV_PROJECT=""
mkcase "$c" ABSENT
gate "$c"
assert_deny W-ARTIFACT || fail "absent: a done scan without its findings file must be W-ARTIFACT"
closer_leaves absent active

# ---- malformed marker: W-MARKER, not complete -------------------------------
WV_PROJECT=""
mkcase "$c" "not a findings marker
"
gate "$c"
assert_deny W-MARKER || fail "malformed: a findings file without a FINDINGS: n line must be W-MARKER"
closer_leaves malformed active

# ---- unreadable file: the scan fails, the gate fails open, not complete ----
if [ "$(id -u)" = "0" ]; then
  printf 'SKIP %s: unreadable-file leg (running as root, which reads a mode-000 file)\n' "$name" | tee -a "$log"
else
  WV_PROJECT=""
  mkcase "$c" "FINDINGS: 0
"
  gate "$c"
  chmod 000 "$WV_PROJECT/.wave/findings/BC.md" || fail "unreadable: chmod failed"
  jq 'del(.seed)' "$c" > "$c.tmp" && mv "$c.tmp" "$c"
  gate "$c"
  case "$WV_LAST_STDOUT" in
    *'"permissionDecision":"deny"'*) fail "unreadable: a scan that could not run must fail open (BF-BC required), got: $WV_LAST_STDOUT" ;;
  esac
  case "$WV_LAST_STDOUT$WV_LAST_STDERR" in
    *W-STATE*) : ;;
    *) fail "unreadable: the gate must say it measured nothing (W-STATE), got: $WV_LAST_STDOUT" ;;
  esac
  closer_leaves unreadable active
  chmod 644 "$WV_PROJECT/.wave/findings/BC.md" 2>/dev/null
fi

exit $rc
