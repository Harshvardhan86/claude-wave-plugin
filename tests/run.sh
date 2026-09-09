#!/usr/bin/env bash
# tests/run.sh [--filter <glob>]... [--list] [--coverage]
#
# Discovers every tests/cases/**/*.{json,sh} case, runs each, prints one
# PASS/FAIL line per case plus a total, and exits non-zero on any failure.
# By default, rule-id coverage gaps are printed but do not fail; pass --coverage
# to enforce coverage at release time (exit non-zero if any rule lacks positive
# case and negative control). See tests/cases/README.md for the case-file schema
# and the self-check semantics (harness_fails / the rule-id coverage check / the
# fixture-key sweep) this script implements.
#
# Deliberately `set -u`, never `set -e` — one bad case must not abort the
# whole run, and a hook under test exiting non-zero is often exactly what is
# being asserted.
set -u

WV_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WV_TESTS_DIR="$WV_REPO_ROOT/tests"
WV_MEASURED_KEYS_FILE="$WV_TESTS_DIR/fixtures/measured-keys.txt"
WV_REASONS_TSV="$WV_REPO_ROOT/hooks/reasons.tsv"

for tool in jq git; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'tests/run.sh: required tool not found on PATH: %s\n' "$tool" >&2
    exit 1
  fi
done

# shellcheck source=tests/lib/assert.sh
source "$WV_TESTS_DIR/lib/assert.sh"

# ---- args -----------------------------------------------------------------

wv_list_only=0
wv_enforce_coverage=0
declare -a wv_filters=()
while [ $# -gt 0 ]; do
  case "$1" in
    --list) wv_list_only=1; shift ;;
    --coverage) wv_enforce_coverage=1; shift ;;
    --filter)
      [ $# -ge 2 ] || { echo "tests/run.sh: --filter needs an argument" >&2; exit 1; }
      wv_filters+=("$2"); shift 2 ;;
    *) printf 'tests/run.sh: unknown argument: %s\n' "$1" >&2; exit 1 ;;
  esac
done

wv_matches_filter() {
  local name="$1"
  [ ${#wv_filters[@]} -eq 0 ] && return 0
  local f
  for f in "${wv_filters[@]}"; do
    # shellcheck disable=SC2053
    [[ "$name" == $f ]] && return 0
  done
  return 1
}

# ---- discovery --------------------------------------------------------

declare -a wv_all_files=()
while IFS= read -r f; do
  wv_all_files+=("$f")
done < <(find "$WV_TESTS_DIR/cases" -type f \( -name '*.json' -o -name '*.sh' \) ! -name 'README.md' | sort)

declare -a wv_case_files=()
declare -a wv_case_names=()
for f in "${wv_all_files[@]}"; do
  name="$(basename "$f" | sed -E 's/\.(json|sh)$//')"
  if wv_matches_filter "$name"; then
    wv_case_files+=("$f")
    wv_case_names+=("$name")
  fi
done

if [ "$wv_list_only" = "1" ]; then
  for name in "${wv_case_names[@]}"; do
    printf '%s\n' "$name"
  done
  exit 0
fi

wv_discovered=${#wv_case_files[@]}

# ---- rule-id coverage universe (pre-pass over every .json case) -----------

declare -A wv_positive=()   # rule id -> space-separated case names declaring it
declare -A wv_negative=()   # rule id -> 1 if a negative control exists
declare -A wv_universe=()   # rule id -> 1
declare -A wv_case_violation=()  # case name -> extra failure text
declare -a wv_suite_violations=()

if [ -f "$WV_REASONS_TSV" ]; then
  while IFS=$'\t' read -r rid _rest; do
    [ -z "$rid" ] && continue
    case "$rid" in rule_id|'#'*) continue ;; esac
    wv_universe["$rid"]=1
  done < "$WV_REASONS_TSV"
fi

for i in "${!wv_case_files[@]}"; do
  f="${wv_case_files[$i]}"
  case "$f" in *.json) ;; *) continue ;; esac
  [ -s "$f" ] || continue
  jq -e 'type=="object"' "$f" >/dev/null 2>&1 || continue
  name="${wv_case_names[$i]}"
  rid="$(jq -r '.expect.rule // empty' "$f" 2>/dev/null)"
  nid="$(jq -r '.expect.negative_control_for // empty' "$f" 2>/dev/null)"
  if [ -n "$rid" ]; then
    wv_universe["$rid"]=1
    wv_positive["$rid"]="${wv_positive[$rid]:-} $name"
  fi
  if [ -n "$nid" ]; then
    wv_universe["$nid"]=1
    wv_negative["$nid"]=1
  fi
done

for rid in "${!wv_universe[@]}"; do
  pos="${wv_positive[$rid]:-}"
  neg="${wv_negative[$rid]:-}"
  if [ -z "$pos" ] || [ -z "$neg" ]; then
    declare -a missing=()
    [ -z "$pos" ] && missing+=("no positive case")
    [ -z "$neg" ] && missing+=("no negative control")
    msg="rule $rid: $(IFS=', '; echo "${missing[*]}")"
    if [ -n "$pos" ]; then
      for cn in $pos; do
        wv_case_violation["$cn"]="${wv_case_violation[$cn]:+${wv_case_violation[$cn]}; }$msg"
      done
    else
      wv_suite_violations+=("$msg")
    fi
  fi
done

# ---- fixture-key sweep ------------------------------------------------

_wv_key_known() {
  command grep -qxF "$1" "$WV_MEASURED_KEYS_FILE"
}

_wv_sweep_keys() {
  # prints space-separated invented keys for a case file, empty if none
  local path="$1"
  local -a bad=()
  local k
  while IFS= read -r k; do
    [ -z "$k" ] && continue
    _wv_key_known "$k" || bad+=("$k")
  done < <(jq -r '.stdin // {} | keys[]' "$path" 2>/dev/null)
  while IFS= read -r k; do
    [ -z "$k" ] && continue
    _wv_key_known "tool_input.$k" || bad+=("tool_input.$k")
  done < <(jq -r '.stdin.tool_input // {} | keys[]' "$path" 2>/dev/null)
  [ ${#bad[@]} -gt 0 ] && printf '%s' "${bad[*]}"
}

# ---- expect comparison --------------------------------------------------

_wv_compare_expect() {
  # _wv_compare_expect <case-json-path> — uses the WV_LAST_* state left by
  # the run_hook call that already happened. Returns 0 if every declared
  # expect.* field (other than the meta fields) is satisfied.
  local path="$1"
  local ok=1
  local -a diffs=()

  local want_exit
  want_exit="$(jq -r '.expect.exit // empty' "$path")"
  if [ -n "$want_exit" ]; then
    assert_exit "$want_exit" || { ok=0; diffs+=("$WV_ASSERT_DIFF"); }
  fi

  local want_decision
  want_decision="$(jq -r '.expect.decision // empty' "$path")"
  case "$want_decision" in
    silent) assert_silent || { ok=0; diffs+=("$WV_ASSERT_DIFF"); } ;;
    allow)  assert_allow  || { ok=0; diffs+=("$WV_ASSERT_DIFF"); } ;;
    deny)   assert_deny "$(jq -r '.expect.rule // ""' "$path")" || { ok=0; diffs+=("$WV_ASSERT_DIFF"); } ;;
    block)  assert_block "$(jq -r '.expect.rule // ""' "$path")" || { ok=0; diffs+=("$WV_ASSERT_DIFF"); } ;;
    warn)   assert_warn "$(jq -r '.expect.rule // ""' "$path")" || { ok=0; diffs+=("$WV_ASSERT_DIFF"); } ;;
    "") : ;;
    *) ok=0; diffs+=("unknown expect.decision: $want_decision") ;;
  esac

  local want_rule
  want_rule="$(jq -r '.expect.rule // empty' "$path")"
  case "$want_decision" in
    deny|block|warn)
      if [ -n "$want_rule" ]; then
        assert_single_rule_token || { ok=0; diffs+=("$WV_ASSERT_DIFF"); }
      fi
      ;;
  esac

  local want_template
  want_template="$(jq -r '.expect.reason_template // empty' "$path")"
  if [ -n "$want_template" ]; then
    assert_reason_matches_template "$want_template" || { ok=0; diffs+=("$WV_ASSERT_DIFF"); }
  fi

  local -a needles=()
  while IFS= read -r s; do
    [ -z "$s" ] && continue
    needles+=("$s")
  done < <(jq -r '.expect.reason_contains // [] | .[]' "$path" 2>/dev/null)
  for s in "${needles[@]:-}"; do
    [ -z "$s" ] && continue
    assert_reason_contains "$s" || { ok=0; diffs+=("$WV_ASSERT_DIFF"); }
  done

  local -a absent_needles=()
  while IFS= read -r s; do
    [ -z "$s" ] && continue
    absent_needles+=("$s")
  done < <(jq -r '.expect.stdout_absent // [] | .[]' "$path" 2>/dev/null)
  for s in "${absent_needles[@]:-}"; do
    [ -z "$s" ] && continue
    assert_stdout_absent "$s" || { ok=0; diffs+=("$WV_ASSERT_DIFF"); }
  done

  local want_state
  want_state="$(jq -r '.expect.state_assert // empty' "$path")"
  if [ -n "$want_state" ]; then
    assert_state "$want_state" || { ok=0; diffs+=("$WV_ASSERT_DIFF"); }
  fi

  local want_ledger
  want_ledger="$(jq -r '.expect.ledger_lines // empty' "$path")"
  if [ -n "$want_ledger" ]; then
    assert_ledger_lines "$want_ledger" || { ok=0; diffs+=("$WV_ASSERT_DIFF"); }
  fi

  local want_ledger_line
  want_ledger_line="$(jq -r '.expect.ledger_assert // empty' "$path")"
  if [ -n "$want_ledger_line" ]; then
    assert_ledger_line "$want_ledger_line" || { ok=0; diffs+=("$WV_ASSERT_DIFF"); }
  fi

  local want_ledger_prefix
  want_ledger_prefix="$(jq -r '.expect.ledger_prefix_unchanged // empty' "$path")"
  if [ -n "$want_ledger_prefix" ]; then
    assert_ledger_prefix "$path" "$want_ledger_prefix" || { ok=0; diffs+=("$WV_ASSERT_DIFF"); }
  fi

  local -a absent_paths=()
  while IFS= read -r p; do
    [ -z "$p" ] && continue
    absent_paths+=("$p")
  done < <(jq -r '.expect.files_absent // [] | .[]' "$path" 2>/dev/null)
  for p in "${absent_paths[@]:-}"; do
    [ -z "$p" ] && continue
    if [ -e "$WV_PROJECT/$p" ]; then
      ok=0
      diffs+=("files_absent: $p exists")
    fi
  done

  WV_COMPARE_DIFF="$(IFS='; '; echo "${diffs[*]:-}")"
  [ "$ok" = "1" ]
}

# ---- per-case processing ------------------------------------------------

declare -A wv_ran_case=()   # name -> 1 if run_hook was actually invoked for it

_wv_process_json_case() {
  local path="$1" name="$2"
  local -a reasons=()
  local raw_fail=0

  if [ ! -s "$path" ]; then
    case "$path" in
      */_selfcheck/*) _wv_record_selfcheck_zero_byte "$name"; return ;;
      *) _wv_record "$name" FAIL "case file is 0 bytes"; return ;;
    esac
  fi

  if ! jq -e 'type=="object"' "$path" >/dev/null 2>&1; then
    _wv_record "$name" FAIL "case file is not a parseable JSON object"
    return
  fi

  local bad_keys
  bad_keys="$(_wv_sweep_keys "$path")"
  if [ -n "$bad_keys" ]; then
    raw_fail=1
    reasons+=("invented stdin key(s): $bad_keys")
  fi

  if [ -n "${wv_case_violation[$name]:-}" ]; then
    raw_fail=1
    reasons+=("${wv_case_violation[$name]}")
  fi

  local script
  script="$(jq -r '.script // empty' "$path")"
  if [ -z "$script" ]; then
    raw_fail=1
    reasons+=("case is missing required 'script' field")
  else
    WV_PROJECT=""
    if ! run_hook "$script" "$path"; then
      raw_fail=1
      reasons+=("$WV_LAST_STDERR")
    else
      wv_ran_case["$name"]=1
      if ! _wv_compare_expect "$path"; then
        raw_fail=1
        reasons+=("$WV_COMPARE_DIFF")
      fi
    fi
  fi

  local harness_fails
  harness_fails="$(jq -r '.expect.harness_fails // false' "$path" 2>/dev/null)"
  if [ "$harness_fails" = "true" ]; then
    if [ "$raw_fail" = "1" ]; then
      _wv_record "$name" PASS ""
    else
      _wv_record "$name" FAIL "expected the harness to reject this case, but it did not"
    fi
  else
    if [ "$raw_fail" = "1" ]; then
      _wv_record "$name" FAIL "$(IFS='; '; echo "${reasons[*]:-}")"
    else
      _wv_record "$name" PASS ""
    fi
  fi
}

_wv_record_selfcheck_zero_byte() {
  # A 0-byte file under _selfcheck/ is the deliberate self-check of the
  # "0 bytes" detector: PASS once the detector (the [ ! -s "$path" ] check
  # above) correctly identifies it. Before that inversion existed, this
  # was reported as a plain FAIL — see tests/cases/README.md.
  local name="$1"
  _wv_record "$name" PASS ""
}

wv_total=0
wv_failed=0

_wv_record() {
  local name="$1" status="$2" reason="${3:-}"
  wv_total=$((wv_total + 1))
  if [ "$status" = "PASS" ]; then
    printf 'PASS %s\n' "$name"
  else
    wv_failed=$((wv_failed + 1))
    if [ -n "$reason" ]; then
      printf 'FAIL %s: %s\n' "$name" "$reason"
    else
      printf 'FAIL %s\n' "$name"
    fi
  fi
}

_wv_process_sh_case() {
  local path="$1" name="$2"
  local log="$WV_RUN_TMP/logs/$name.log"
  : > "$log"
  local out err rc
  err="$(mktemp "$WV_RUN_TMP/sh-stderr.XXXXXX")"
  out="$(WV_CASE_NAME="$name" WV_CASE_LOG="$log" bash "$path" 2>"$err")"
  rc=$?
  local errtext
  errtext="$(cat "$err")"
  rm -f "$err"
  if [ "$rc" = "0" ]; then
    if command grep -q '^RAN ' "$log" 2>/dev/null; then
      _wv_record "$name" PASS ""
    else
      _wv_record "$name" FAIL "case log missing its run marker"
    fi
  else
    _wv_record "$name" FAIL "$(printf '%s %s' "$out" "$errtext" | head -c 300)"
  fi
}

wv_executed=0
for i in "${!wv_case_files[@]}"; do
  f="${wv_case_files[$i]}"
  n="${wv_case_names[$i]}"
  case "$f" in
    *.json) _wv_process_json_case "$f" "$n" ;;
    *.sh)   _wv_process_sh_case "$f" "$n" ;;
  esac
  wv_executed=$((wv_executed + 1))
done

# run-marker check for every json case that reached run_hook
for name in "${!wv_ran_case[@]}"; do
  log="$WV_RUN_TMP/logs/$name.log"
  if ! command grep -q '^RAN ' "$log" 2>/dev/null; then
    printf 'FAIL %s: case log missing its run marker\n' "$name"
    wv_total=$((wv_total + 1))
    wv_failed=$((wv_failed + 1))
  fi
done

# Coverage check: always print, but only count toward failed if --coverage is set
if [ ${#wv_suite_violations[@]} -gt 0 ]; then
  if [ "$wv_enforce_coverage" = "1" ]; then
    for msg in "${wv_suite_violations[@]:-}"; do
      [ -z "$msg" ] && continue
      printf 'FAIL coverage: %s\n' "$msg"
      wv_total=$((wv_total + 1))
      wv_failed=$((wv_failed + 1))
    done
  else
    # Print coverage messages without counting as failures
    for msg in "${wv_suite_violations[@]:-}"; do
      [ -z "$msg" ] && continue
      printf 'coverage: %s\n' "$msg"
    done
    # Print summary line
    coverage_count=${#wv_suite_violations[@]}
    printf 'coverage: %s rule(s) without cases (run with --coverage to enforce)\n' "$coverage_count"
  fi
fi

if [ "$wv_executed" -lt "$wv_discovered" ]; then
  printf 'FAIL suite: executed %s of %s discovered cases\n' "$wv_executed" "$wv_discovered"
  wv_total=$((wv_total + 1))
  wv_failed=$((wv_failed + 1))
fi

printf 'total=%s failed=%s\n' "$wv_total" "$wv_failed"

[ "$wv_failed" -eq 0 ]
