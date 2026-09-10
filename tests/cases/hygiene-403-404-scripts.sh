#!/usr/bin/env bash
# tests/cases/hygiene-403-404-scripts.sh — AC-403 and AC-404: the shell-hygiene
# properties every script in this repository must hold, each with a planted
# positive control proving the sweep that checked it actually ran.
#
# AC-403  no gating scan uses a bare `grep`
# AC-404  no `set -e`, no `set -o pipefail` on a gating path, `set -u` present,
#         no `exit 2`, every array read initialised
#
# BOTH TREES. The ACs name `scripts/`, which is where a violation can reach a user
# — but a bare `grep` in a gating scan inside a TEST is how a sweep comes back clean
# on a tree full of violations, and this suite's own gates are as load-bearing as the
# hooks they check (one was found in tests/cases/wiring-369-matchers.sh, where
# `grep -c … || true` turned a declined scan into a clean count). So scripts/ and
# tests/ are both swept, and `tests/**` is not exempted from anything.
#
# WHY EVERY SWEEP HAS A PLANTED CONTROL. These are searches for the ABSENCE of
# something, and an absence is exactly what a broken searcher also reports. This
# repo's own `grep` may be a shell function over a bundled searcher that can DECLINE
# a file and print nothing where real grep prints 0 — the same defect AC-403 is
# about. Each sweep therefore runs twice: over the real trees, where it must find
# nothing, and over a file planted with exactly the violation it hunts, where it must
# find it. A sweep that cannot find its own planted control has measured nothing.
#
# CODE, NOT PROSE, AND NOT STRINGS. Every sweep looks at the CODE part of each line
# only: comment lines are skipped, and single- and double-quoted spans are blanked
# before matching — with the important exception that a command substitution inside a
# quoted span is code again, so `x="$(command grep …)"` is still read as an
# invocation. That is the explicit allow rule, stated once and applied uniformly to
# both trees, rather than a list of exempt directories: this very file has to
# describe `set -e`, `exit 2` and a bare `grep` in order to hunt them, and a sweep
# that could not tell a mention from an instruction would either flag itself or be
# excused by an exclusion that then hides real violations in its neighbours.
#
# WHY `exit 2` MATTERS ENOUGH TO SWEEP FOR. The platform reads exit 2 from a
# PreToolUse hook as "block and feed stderr back to the model" — a channel with none
# of the JSON contract's shape, no rule id and no remedy — so a script that ever
# exits 2 has a second, undocumented way to deny that no case covers.
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

# Every shell script in both trees, discovered rather than listed: a script added
# later must be swept too, and a hardcoded list is a list that goes stale.
declare -a SCRIPTS=()
while IFS= read -r f; do
  SCRIPTS+=("$f")
done < <(find scripts tests -type f -name '*.sh' | sort)

if [ "${#SCRIPTS[@]}" -lt 100 ]; then
  fail "found only ${#SCRIPTS[@]} script(s) under scripts/ and tests/ — that is a failed discovery, not a small tree"
  exit 1
fi
printf 'swept %s script(s) under scripts/ and tests/\n' "${#SCRIPTS[@]}"

PLANT_DIR="$WV_RUN_TMP/$name-controls"
mkdir -p "$PLANT_DIR"

# ---------------------------------------------------------------------------
# The one instrument. Every sweep goes through it, so "what counts as code" is
# decided in one place for every pattern and both trees.
# ---------------------------------------------------------------------------

SWEEP_PY="$PLANT_DIR/sweep.py"
cat > "$SWEEP_PY" <<'PY'
"""sweep.py <pattern-name> <file>...  -> one "<file>:<line>:<text>" per hit.

Only the CODE part of a line is examined. A comment line is skipped entirely;
quoted spans are blanked, because a script that HUNTS a pattern has to name it;
and a command substitution inside a quoted span is code again, so a wrapped
`"$(command grep …)"` is still read as an invocation.
"""
import re
import sys


def code_only(line):
    """Blank single- and double-quoted spans, keeping $( ) and ` ` inside them."""
    out = []
    i, n = 0, len(line)
    quote = None
    depth = 0
    while i < n:
        c = line[i]
        if c == "\\" and i + 1 < n:
            out.append("  ")
            i += 2
            continue
        if quote is None:
            if c in "\"'":
                quote = c
                out.append(" ")
                i += 1
                continue
            out.append(c)
            i += 1
            continue
        # Inside a quoted span. A substitution or expansion re-enters CODE — but
        # only inside DOUBLE quotes: `'$(…)'` and `'${…}'` are literal text, and
        # treating them as code is what made this sweep flag its own planted control
        # argument. `${NAME[@]}` has to be kept, because an array read is almost
        # always inside double quotes and blanking it made the array sweep unable to
        # match anything at all — including its own control.
        if quote == '"' and (line.startswith("$(", i) or line.startswith("${", i) or c == "`"):
            depth += 1
            out.append(line[i:i + 2] if c == "$" else c)
            i += 2 if c == "$" else 1
            continue
        if depth > 0:
            if c in ")}":
                depth -= 1
            out.append(c)
            i += 1
            continue
        if c == quote:
            quote = None
            out.append(" ")
            i += 1
            continue
        out.append(" ")
        i += 1
    return "".join(out)


def declared_arrays(text):
    """Names this file gives an array value before anything reads it."""
    names = set()
    for m in re.finditer(r"(?:declare|local|readonly)\s+-[aA][a-zA-Z]*\s+([A-Za-z_][A-Za-z0-9_]*)", text):
        names.add(m.group(1))
    for m in re.finditer(r"^\s*([A-Za-z_][A-Za-z0-9_]*)\+?=\(", text, re.M):
        names.add(m.group(1))
    # `read -ra NAME`, `read -r -a NAME`: the flags arrive as one token or several,
    # and it is the presence of `a` among them that makes NAME an array. Matching
    # only the literal `-a` missed `read -ra`, which is the form this suite uses.
    for m in re.finditer(r"read\s+(?:-[a-zA-Z]+\s+)*-[a-zA-Z]*a[a-zA-Z]*\s+([A-Za-z_][A-Za-z0-9_]*)", text):
        names.add(m.group(1))
    return names


REGEXES = {
    "set-e": r"^\s*set\s+(-[a-zA-Z]*e[a-zA-Z]*|-o\s+errexit)",
    "set-eu": r"^\s*set\s+-[a-zA-Z]*e[a-zA-Z]*u",
    "pipefail": r"set\s+-o\s+pipefail",
    "exit-2": r"(^|[^-\w])exit\s+2([^0-9]|$)",
}

STARTERS = {"", "|", "(", ";", "&", "&&", "||", "$(", "`", "!", "{", "then", "do",
            "else", "elif", "if"}


def bare_grep(code):
    """True when `code` invokes grep in command position without `command`."""
    for m in re.finditer(r"(?<![\w./-])grep(?![\w-])", code):
        before = code[:m.start()]
        tok = re.findall(r"(?:\|\||&&|\$\(|[|(;&`!{]|[\w./-]+)", before)
        prev = tok[-1] if tok else ""
        if prev in ("command", "env", "xargs", "exec"):
            continue
        if prev in STARTERS:
            return True
    return False


HEREDOC = re.compile(r"<<-?\s*(?:'([A-Za-z_][A-Za-z0-9_]*)'|\"([A-Za-z_][A-Za-z0-9_]*)\"|([A-Za-z_][A-Za-z0-9_]*))(?!<)")


pattern = sys.argv[1]
hits = []
for path in sys.argv[2:]:
    body = open(path).read()
    arrays = declared_arrays(body) if pattern == "array-init" else set()
    # A HERE-DOCUMENT BODY IS DATA, NOT CODE, and this repository embeds whole
    # python programs in `<<'PY'` blocks. Without this the sweep read that python
    # as bash and flagged a python string containing `${args[@]}` as an
    # unguarded array read. Skipping the body is a uniform rule about the shell's
    # own syntax, which is what makes it an allow rule rather than an exemption
    # for the files that happen to trip it.
    heredoc_marker = None
    for i, line in enumerate(body.split("\n"), 1):
        if heredoc_marker is not None:
            if line.strip() == heredoc_marker:
                heredoc_marker = None
            continue
        if line.lstrip().startswith("#"):
            continue
        m_hd = HEREDOC.search(line)
        if m_hd and "<<<" not in line:
            heredoc_marker = m_hd.group(1) or m_hd.group(2) or m_hd.group(3)
        code = code_only(line)
        if pattern == "bare-grep":
            if bare_grep(code):
                hits.append("%s:%d:%s" % (path, i, line.strip()[:100]))
        elif pattern == "array-init":
            for m in re.finditer(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\[[@*]\]([^}]*)\}", code):
                nm, tail = m.group(1), m.group(2)
                if nm in arrays:
                    continue
                if tail.startswith(":-") or tail.startswith("-") or tail.startswith("+"):
                    continue
                hits.append("%s:%d:%s" % (path, i, line.strip()[:90]))
        else:
            if re.search(REGEXES[pattern], code):
                hits.append("%s:%d:%s" % (path, i, line.strip()[:100]))
sys.stdout.write("\n".join(hits) + ("\n" if hits else ""))
PY

check() {
  # check <pattern> <planted line> — the sweep must find NOTHING in either tree
  # and MUST find the planted line in a file of its own.
  local pattern="$1" planted="$2"
  local hits control_file control_hits

  hits="$(python3 "$SWEEP_PY" "$pattern" "${SCRIPTS[@]}")"
  if [ -n "$hits" ]; then
    fail "$pattern: the tree carries the pattern this sweep forbids:
$hits"
  fi

  control_file="$PLANT_DIR/$pattern.sh"
  printf '#!/usr/bin/env bash\n%s\n' "$planted" > "$control_file"
  control_hits="$(python3 "$SWEEP_PY" "$pattern" "$control_file")"
  if [ -z "$control_hits" ]; then
    fail "$pattern: the sweep did not find its own planted control in $control_file — it has measured nothing about the tree"
    return 1
  fi
  printf '  %-14s clean, control found: %s\n' "$pattern" \
    "$(printf '%s' "$control_hits" | head -n1 | cut -c1-64)"
  return 0
}

# ---- AC-403 ----------------------------------------------------------------
check bare-grep 'n=$(grep -c foo bar)'

# The other half of that control, and the one a regex-based sweep failed: a
# `command grep` on the next line must NOT be flagged, or a sweep that flags
# everything would also "pass" its positive control.
wrapped="$PLANT_DIR/bare-grep-wrapped.sh"
printf '#!/usr/bin/env bash\nm=$(command grep -c foo bar)\nprintf "a mention of grep in a string\\n"\n' > "$wrapped"
if [ -n "$(python3 "$SWEEP_PY" bare-grep "$wrapped")" ]; then
  fail "bare-grep: the sweep flags 'command grep' or a mention inside a string, so its finding count says nothing"
else
  printf '  %-14s negative control: command grep and a string mention both pass\n' bare-grep
fi

# ---- AC-404 ----------------------------------------------------------------
check set-e 'set -e'
check set-eu 'set -eu'
check pipefail 'set -o pipefail'
check exit-2 'exit 2'

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
  printf '  %-14s present in all %s, control (a file without it) correctly flagged\n' \
    'set -u' "${#SCRIPTS[@]}"
fi

# ---- AC-404: every array read is initialised ------------------------------
#
# `set -u` makes an unset array's expansion fatal, which is precisely the
# fail-closed-on-our-own-bug that Global Constraint 8 forbids. Two shapes are
# accepted: the array is declared (`declare -a` / `local -a` / `NAME=(`) before it
# is read, or every read uses a default (`${NAME[@]:-}`, `${NAME[@]+"${NAME[@]}"}`).
unguarded="$(python3 "$SWEEP_PY" array-init "${SCRIPTS[@]}")"
[ -z "$unguarded" ] || fail "array read without initialisation or a default:
$unguarded"

arr_control="$PLANT_DIR/uninit-array.sh"
printf '#!/usr/bin/env bash\nset -u\nfor x in "${nope[@]}"; do echo "$x"; done\n' > "$arr_control"
control_out="$(python3 "$SWEEP_PY" array-init "$arr_control")"
if [ -z "$control_out" ]; then
  fail "the uninitialised-array detector did not flag its own planted control — it has measured nothing"
else
  printf '  %-14s clean, control found: %s\n' 'array init' "$(printf '%s' "$control_out" | head -n1 | cut -c1-64)"
fi

# ---- the wrapper-vs-real-grep discriminator -------------------------------
#
# The reason every sweep spells `command grep`: this repo's `grep` may be a shell
# FUNCTION over a bundled searcher, and a gating scan through it can print nothing
# where real grep prints 0. Which instrument is on PATH is a property of the
# operator's shell, not of this tree, so it is REPORTED rather than asserted.
printf '  %-14s %s\n' 'grep on PATH' "$(type -t grep 2>/dev/null || printf 'unknown')"

exit $rc
