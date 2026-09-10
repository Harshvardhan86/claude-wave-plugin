#!/usr/bin/env bash
# tests/tools/mutants-all.sh [--keep]
#
# The release gate over the whole mutation layer: runs every
# tests/tools/mutants-*.sh in sequence and prints one table.
#
# WHY a driver rather than a documented list of commands. The per-script drivers
# are the instruments; a list in prose is not a gate, because a driver nobody ran
# is indistinguishable in every later summary from one that passed. This script
# DISCOVERS the drivers (never names them) so a driver added later cannot be
# forgotten, fails loudly when the discovery set is empty, and refuses to report
# a driver's result unless that driver actually produced its own summary line —
# a missing summary is a NON-RUN, not a pass.
#
#   bash tests/tools/mutants-all.sh
#   bash tests/tools/mutants-all.sh --keep     # pass --keep through to each driver
#
# Exit status: 0 only when every driver ran, every driver exited 0, every mutant
# was killed, and every driver reported its files restored. Any survivor, any
# failed restore, any driver whose summary could not be read, and an empty
# discovery set are all non-zero.
#
# Each driver's full log is kept for the run and its path printed, because the
# table is a summary and a summary is not evidence. The logs live OUTSIDE the
# repository: a measurement that writes into its own subject manufactures the
# defect it reports.
#
# Deliberately `set -u`, never `set -e`: one driver failing must not abort the
# sweep, or the drivers after it would be silently unmeasured.

set -u

WV_TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WV_REPO_ROOT="$(cd "$WV_TOOLS_DIR/../.." && pwd)"
WV_KEEP=0
[ "${1:-}" = "--keep" ] && WV_KEEP=1

WV_LOGS="$(mktemp -d "${TMPDIR:-/tmp}/wave-mutants-all.XXXXXX")" || exit 1

# ---- discovery -------------------------------------------------------------
#
# Every driver except this one. Sorted, so the table is stable run to run.

declare -a WV_DRIVERS=()
while IFS= read -r f; do
  case "$(basename "$f")" in
    mutants-all.sh) continue ;;
  esac
  WV_DRIVERS+=("$f")
done < <(find "$WV_TOOLS_DIR" -maxdepth 1 -type f -name 'mutants-*.sh' | sort)

if [ "${#WV_DRIVERS[@]}" -eq 0 ]; then
  printf 'mutants-all.sh: no mutants-*.sh driver found under %s — nothing was measured\n' \
    "$WV_TOOLS_DIR" >&2
  exit 1
fi

printf 'mutants-all.sh: %s driver(s) discovered, logs under %s\n\n' \
  "${#WV_DRIVERS[@]}" "$WV_LOGS"

# ---- run each driver -------------------------------------------------------

wv_failed=0
wv_total_mutants=0
wv_total_survived=0
declare -a WV_ROWS=()

for wv_driver in "${WV_DRIVERS[@]}"; do
  wv_name="$(basename "$wv_driver")"
  wv_log="$WV_LOGS/$wv_name.log"
  wv_start="$(date +%s)"
  if [ "$WV_KEEP" = "1" ]; then
    ( cd "$WV_REPO_ROOT" && bash "$wv_driver" --keep ) > "$wv_log" 2>&1
  else
    ( cd "$WV_REPO_ROOT" && bash "$wv_driver" ) > "$wv_log" 2>&1
  fi
  wv_rc=$?
  wv_secs=$(( "$(date +%s)" - wv_start ))

  # The driver's own summary line is the only thing trusted here, and its
  # ABSENCE is a failure: a driver that died before printing it has measured
  # nothing, however plausible its exit status looks.
  wv_summary="$(command grep -m1 -E '^(cells=[0-9]+ )?mutants=' "$wv_log")"
  if [ -z "$wv_summary" ]; then
    WV_ROWS+=("$wv_name|?|?|NO SUMMARY|${wv_secs}s|rc=$wv_rc")
    wv_failed=$((wv_failed + 1))
    continue
  fi

  wv_mutants=""; wv_survived=""; wv_restored=""
  for wv_field in $wv_summary; do
    case "$wv_field" in
      mutants=*)  wv_mutants="${wv_field#mutants=}" ;;
      survived=*) wv_survived="${wv_field#survived=}" ;;
      restored=*) wv_restored="${wv_field#restored=}" ;;
    esac
  done
  case "$wv_mutants" in ''|*[!0-9]*) wv_mutants="?" ;; esac
  case "$wv_survived" in ''|*[!0-9]*) wv_survived="?" ;; esac
  [ -n "$wv_restored" ] || wv_restored="?"

  if [ "$wv_mutants" != "?" ]; then
    wv_total_mutants=$((wv_total_mutants + wv_mutants))
  fi
  if [ "$wv_survived" != "?" ]; then
    wv_total_survived=$((wv_total_survived + wv_survived))
  fi

  wv_verdict=ok
  [ "$wv_rc" = "0" ] || wv_verdict="rc=$wv_rc"
  [ "$wv_survived" = "0" ] || wv_verdict="SURVIVORS"
  [ "$wv_restored" = "yes" ] || wv_verdict="RESTORE FAILED"
  [ "$wv_verdict" = "ok" ] || wv_failed=$((wv_failed + 1))

  WV_ROWS+=("$wv_name|$wv_mutants|$wv_survived|$wv_restored|${wv_secs}s|$wv_verdict")
done

# ---- one table -------------------------------------------------------------

printf '%-30s %8s %9s %9s %7s  %s\n' SCRIPT MUTANTS SURVIVED RESTORED TIME VERDICT
printf '%s\n' '-------------------------------------------------------------------------------------'
for wv_row in "${WV_ROWS[@]:-}"; do
  [ -z "$wv_row" ] && continue
  IFS='|' read -r wv_c1 wv_c2 wv_c3 wv_c4 wv_c5 wv_c6 <<<"$wv_row"
  printf '%-30s %8s %9s %9s %7s  %s\n' "$wv_c1" "$wv_c2" "$wv_c3" "$wv_c4" "$wv_c5" "$wv_c6"
done
printf '%s\n' '-------------------------------------------------------------------------------------'
printf '%-30s %8s %9s\n' TOTAL "$wv_total_mutants" "$wv_total_survived"

printf '\ndrivers=%s failed=%s mutants=%s survived=%s logs=%s\n' \
  "${#WV_DRIVERS[@]}" "$wv_failed" "$wv_total_mutants" "$wv_total_survived" "$WV_LOGS"

if [ "$wv_failed" -ne 0 ]; then
  printf 'mutants-all.sh: %s driver(s) did not pass — read the log named above before anything else\n' \
    "$wv_failed" >&2
fi

[ "$wv_failed" -eq 0 ] && [ "$wv_total_survived" -eq 0 ]
