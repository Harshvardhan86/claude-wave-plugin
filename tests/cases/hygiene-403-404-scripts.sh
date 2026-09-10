#!/usr/bin/env bash
# tests/cases/hygiene-403-404-scripts.sh — AC-403 and AC-404: the shell-hygiene
# properties every script under scripts/ must hold, each with a planted positive
# control proving the sweep that checked it actually ran.
#
# AC-403  no gating scan uses a bare `grep`
# AC-404  no `set -e`, no `set -o pipefail` on a gating path, `set -u` present,
#         no `exit 2`, every array read initialised
#
# WHY EVERY SWEEP HAS A PLANTED CONTROL, and why that is not ceremony here. These
# sweeps are greps for the ABSENCE of something, and an absence is exactly what a
# broken grep also reports. This repo's own harness `grep` is a shell function
# over a bundled searcher that can DECLINE a file and print nothing where real
# grep prints 0 — the same defect AC-403 is about — so a sweep written with it
# could pass against a tree full of violations and nobody would see a difference.
# Each sweep below is therefore run twice: once over scripts/, where it must find
# nothing, and once over a file planted with exactly the violation it hunts, where
# it must find it. A sweep that cannot find its own planted control has measured
# nothing and fails, whatever it said about scripts/.
#
# WHY `exit 2` MATTERS ENOUGH TO SWEEP FOR. The platform reads exit 2 from a
# PreToolUse hook as "block and feed stderr back to the model" — a channel with
# none of the JSON contract's shape, no rule id and no remedy — so a script that
# ever exits 2 has a second, undocumented way to deny that no case covers.
#
# `set -u`, never `set -e`: the sweeps must all run even after one fails.
set -u

# shellcheck source=tests/lib/assert.sh
source "$(dirname "$0")/../lib/assert.sh"

name="${WV_CASE_NAME:-$(basename "$0" .sh)}"
log="${WV_CASE_LOG:-$WV_RUN_TMP/logs/$name.log}"
rc=0
fail() { printf 'ASSERT FAIL: %s\n' "$*" >&2; rc=1; }
printf 'RAN scripts-hygiene %s decision=allow\n' "$name" >> "$log"

cd "$WV_REPO_ROOT" || exit 1

# Every shell script under scripts/, discovered rather than listed: a script added
# later must be swept too, and a hardcoded list is a list that goes stale.
declare -a SCRIPTS=()
while IFS= read -r f; do
  SCRIPTS+=("$f")
done < <(find scripts -type f -name '*.sh' | sort)

if [ "${#SCRIPTS[@]}" -lt 10 ]; then
  fail "found only ${#SCRIPTS[@]} script(s) under scripts/ — that is a failed discovery, not a small tree"
  exit 1
fi
printf 'swept %s script(s) under scripts/\n' "${#SCRIPTS[@]}"

PLANT_DIR="$WV_RUN_TMP/$name-controls"
mkdir -p "$PLANT_DIR"

sweep() {
  # sweep <extended regex> <files...> -> prints "<file>:<line>:<text>" per hit.
  # `command grep`, never the wrapper — this is itself a gating scan, and an
  # absent count from it must be a failed scan rather than a clean one, which is
  # what the caller's own planted control establishes.
  local re="$1"
  shift
  command grep -nE -- "$re" "$@" 2>/dev/null
}

check() {
  # check <label> <regex> <planted line> — the sweep must find NOTHING under
  # scripts/ and MUST find the planted line in a file of its own.
  local label="$1" re="$2" planted="$3"
  local hits control_file control_hits

  hits="$(sweep "$re" "${SCRIPTS[@]}")"
  if [ -n "$hits" ]; then
    fail "$label: scripts/ carries the pattern this sweep forbids:
$hits"
  fi

  control_file="$PLANT_DIR/$label.sh"
  printf '#!/usr/bin/env bash\n%s\n' "$planted" > "$control_file"
  control_hits="$(sweep "$re" "$control_file")"
  if [ -z "$control_hits" ]; then
    fail "$label: the sweep did not find its own planted control in $control_file — it has measured nothing about scripts/"
    return 1
  fi
  printf '  %-22s clean under scripts/, control found: %s\n' "$label" \
    "$(printf '%s' "$control_hits" | head -n1 | cut -c1-70)"
  return 0
}

# ---- AC-403: a bare `grep` in a gating scan --------------------------------
#
# NOT a regex, and the first attempt at one is why. ERE has no negative
# lookbehind, so `[[:space:]]grep` matches the space inside `command grep` and the
# sweep reported 21 violations in a tree that has none — a FALSE NO-GO whose
# printed remedy would have been to "fix" 21 correct call sites. What is wanted is
# a `grep` in COMMAND POSITION not preceded by `command`, which is a question
# about the token before it, so it is answered by looking at that token.
#
# In command position means: at the start of a line, or immediately after one of
# `| ( ; & && || $( \` ! { then do else`. A `grep` anywhere else on the line is
# prose or a string ("re-run once grep is behaving normally") and is not an
# invocation. Comment lines are skipped outright.
GREP_SCAN_PY="$PLANT_DIR/bare-grep.py"
cat > "$GREP_SCAN_PY" <<'PY'
import re
import sys

STARTERS = {"", "|", "(", ";", "&", "&&", "||", "$(", "`", "!", "{", "then", "do",
            "else", "elif", "if"}

hits = []
for path in sys.argv[1:]:
    for i, line in enumerate(open(path).read().split("\n"), 1):
        if line.lstrip().startswith("#"):
            continue
        for m in re.finditer(r"(?<![\w./-])grep(?![\w-])", line):
            before = line[:m.start()]
            # The last word-or-operator token before this `grep`.
            tok = re.findall(r"(?:\|\||&&|\$\(|[|(;&`!{]|[\w./-]+)", before)
            prev = tok[-1] if tok else ""
            if prev in ("command", "env", "xargs", "exec"):
                continue
            if prev in STARTERS:
                hits.append("%s:%d:%s" % (path, i, line.strip()[:90]))
                break
sys.stdout.write("\n".join(hits) + ("\n" if hits else ""))
PY

bare_hits="$(python3 "$GREP_SCAN_PY" "${SCRIPTS[@]}")"
[ -z "$bare_hits" ] || fail "bare-grep: a gating scan under scripts/ uses a bare grep:
$bare_hits"

bare_control="$PLANT_DIR/bare-grep-control.sh"
printf '#!/usr/bin/env bash\nset -u\nn=$(grep -c foo bar)\nm=$(command grep -c foo bar)\n' > "$bare_control"
bare_control_hits="$(python3 "$GREP_SCAN_PY" "$bare_control")"
case "$bare_control_hits" in
  *'n=$(grep -c foo bar)'*) : ;;
  *) fail "bare-grep: the sweep did not flag its own planted bare grep in $bare_control — it has measured nothing about scripts/" ;;
esac
# The other half of the control, and the one the first regex failed: `command grep`
# on the very next line must NOT be flagged, or a sweep that flags everything would
# also "pass" its positive control.
case "$bare_control_hits" in
  *'command grep'*) fail "bare-grep: the sweep flags 'command grep' too, so its finding count says nothing" ;;
  *) printf '  %-22s clean under scripts/, control found the bare one and not the wrapped one\n' bare-grep ;;
esac

# ---- AC-404: set -e --------------------------------------------------------
check set-e '^[[:space:]]*set[[:space:]]+(-[a-zA-Z]*e[a-zA-Z]*|-o[[:space:]]+errexit)' 'set -e'
check set-eu-combined '^[[:space:]]*set[[:space:]]+-[a-zA-Z]*e[a-zA-Z]*u' 'set -eu'

# ---- AC-404: pipefail ------------------------------------------------------
check pipefail '(^|[[:space:]])set[[:space:]]+-o[[:space:]]+pipefail' 'set -o pipefail'

# ---- AC-404: exit 2 --------------------------------------------------------
check exit-2 '(^|[^-[:alnum:]_])exit[[:space:]]+2([^0-9]|$)' 'exit 2'

# ---- AC-404: `set -u` is PRESENT in every script --------------------------
#
# The one property here that is not an absence, so it is checked per file and its
# control is a file that LACKS it.
missing_u=""
for f in "${SCRIPTS[@]}"; do
  if ! command grep -qE '^[[:space:]]*set[[:space:]]+-[a-zA-Z]*u' "$f" 2>/dev/null; then
    missing_u="$missing_u $f"
  fi
done
[ -z "$missing_u" ] || fail "set -u absent from:$missing_u"

no_u="$PLANT_DIR/no-set-u.sh"
printf '#!/usr/bin/env bash\necho hello\n' > "$no_u"
if command grep -qE '^[[:space:]]*set[[:space:]]+-[a-zA-Z]*u' "$no_u" 2>/dev/null; then
  fail "the set -u presence check matched a file that does not set it — the check is inverted"
else
  printf '  %-22s present in all %s, control (a file without it) correctly flagged\n' \
    'set -u' "${#SCRIPTS[@]}"
fi

# ---- AC-404: every array read is initialised ------------------------------
#
# `set -u` makes an unset array's expansion fatal, which is precisely the
# fail-closed-on-our-own-bug that Global Constraint 8 forbids. Two shapes are
# accepted: the array is declared with `declare -a NAME=()` / `local -a NAME=()`
# before it is read, or every read of it uses a default (`${NAME[@]:-}` or the
# `${NAME[@]+"${NAME[@]}"}` form). Anything else is reported with its file and
# line, so the finding is actionable rather than a count.
unguarded=""
for f in "${SCRIPTS[@]}"; do
  while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    unguarded="$unguarded
$f:$hit"
  done < <(python3 - "$f" <<'PY'
import re
import sys

path = sys.argv[1]
text = open(path).read()
lines = text.split("\n")

declared = set()
for m in re.finditer(r"(?:declare|local|readonly)\s+-[aA][a-zA-Z]*\s+([A-Za-z_][A-Za-z0-9_]*)", text):
    declared.add(m.group(1))
# `NAME=()` and `NAME+=(...)` also initialise, as does a for-loop assignment.
for m in re.finditer(r"^\s*([A-Za-z_][A-Za-z0-9_]*)\+?=\(", text, re.M):
    declared.add(m.group(1))

for i, line in enumerate(lines, 1):
    if line.lstrip().startswith("#"):
        continue
    for m in re.finditer(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\[[@*]\]([^}]*)\}", line):
        name, tail = m.group(1), m.group(2)
        if name in declared:
            continue
        # A default makes the read safe whatever the array's state is.
        if tail.startswith(":-") or tail.startswith("-") or tail.startswith("+"):
            continue
        print("%d:%s" % (i, line.strip()[:90]))
PY
  )
done
[ -z "$unguarded" ] || fail "array read without initialisation or a default:$unguarded"

# The control: the same detector over a planted file that reads an array it never
# declares. Without it, "no findings" would also be what a detector that never
# ran reports.
arr_control="$PLANT_DIR/uninit-array.sh"
printf '#!/usr/bin/env bash\nset -u\nfor x in "${nope[@]}"; do echo "$x"; done\n' > "$arr_control"
control_out="$(python3 - "$arr_control" <<'PY'
import re
import sys
text = open(sys.argv[1]).read()
declared = set()
for m in re.finditer(r"(?:declare|local|readonly)\s+-[aA][a-zA-Z]*\s+([A-Za-z_][A-Za-z0-9_]*)", text):
    declared.add(m.group(1))
for m in re.finditer(r"^\s*([A-Za-z_][A-Za-z0-9_]*)\+?=\(", text, re.M):
    declared.add(m.group(1))
for i, line in enumerate(text.split("\n"), 1):
    if line.lstrip().startswith("#"):
        continue
    for m in re.finditer(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\[[@*]\]([^}]*)\}", line):
        name, tail = m.group(1), m.group(2)
        if name in declared:
            continue
        if tail.startswith(":-") or tail.startswith("-") or tail.startswith("+"):
            continue
        print("%d:%s" % (i, line.strip()[:90]))
PY
)"
if [ -z "$control_out" ]; then
  fail "the uninitialised-array detector did not flag its own planted control — it has measured nothing"
else
  printf '  %-22s clean under scripts/, control found: %s\n' 'array init' "$control_out"
fi

# ---- the wrapper-vs-real-grep discriminator -------------------------------
#
# The reason every sweep above spells `command grep`: this repo's `grep` may be a
# shell FUNCTION over a bundled searcher, and a gating scan through it can print
# nothing where real grep prints 0. That is not a hypothetical — it is measured
# here, and the measurement is reported rather than asserted, because which
# instrument is on PATH is a property of the operator's shell, not of this tree.
printf '  %-22s %s\n' 'grep on PATH is' "$(type -t grep 2>/dev/null || printf 'unknown')"

exit $rc
