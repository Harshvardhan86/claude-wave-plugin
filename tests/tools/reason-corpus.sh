#!/usr/bin/env bash
# tests/tools/reason-corpus.sh [--verbose]
#
# The release gate over the text a user actually reads. `tests/run.sh` proves a
# rule FIRES; this proves the sentence it fires with is usable: one rule id, a
# remedy, a bound length, no unrendered placeholder, no path that is only true on
# the machine that produced it, and — the one that cannot be seen by running a
# single case — a template whose placeholder count matches the number of
# arguments every call site passes it.
#
# THAT last check is the load-bearing one. `printf` REUSES its format string when
# it is given more arguments than specifiers, so a call site passing one extra
# argument does not truncate: it renders the whole reason TWICE, which puts TWO
# `W-` tokens in it, and a consumer reading the rule off `W-[A-Z0-9-]+` then reads
# the wrong one. No single case can show that unless it happens to be the case
# with the extra argument, which is why the check is static and covers all of them.
#
# Five sections:
#
#   index    every id in hooks/reasons.tsv has a positive case and a negative
#            control; every id any script emits is in reasons.tsv, and every id
#            in reasons.tsv is emitted by some script (AC-399)
#   arity    every emitter call site's argument count equals its template's
#            specifier count; call sites whose arguments are an array expansion
#            are listed as dynamic and are covered by the drive below
#   drive    each id's positive case is run for real and its reason inspected
#            (AC-388, AC-389, AC-390)
#   render   the template's literal segments appear in the rendered reason, in
#            order, with the first as its prefix and the last as its suffix —
#            "byte-identical to the template rendered with the fixture's values"
#            expressed as something that can actually fail on drift (AC-388)
#   bounds   the measured maxima, printed, so a later reader can see the headroom
#            rather than trusting a pass
#
# Exit status: 0 only when every section passes. Deliberately `set -u`, never
# `set -e`: every finding must reach the table.
#
#   bash tests/tools/reason-corpus.sh
#   bash tests/tools/reason-corpus.sh --verbose    # print every rendered reason

set -u

# Character counts must not depend on the operator's locale: `${#s}` counts BYTES
# under LC_ALL=C and CHARACTERS under a UTF-8 locale, and every reason here holds
# an em dash. The bound this gate enforces is stated in characters, so the locale
# it measures in is pinned rather than inherited.
export LC_ALL=C.utf8

WV_CORPUS_TOOLS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WV_CORPUS_ROOT="$(cd "$WV_CORPUS_TOOLS/../.." && pwd)"
WV_VERBOSE=0
[ "${1:-}" = "--verbose" ] && WV_VERBOSE=1

for tool in jq git python3; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'reason-corpus.sh: required tool not found on PATH: %s\n' "$tool" >&2
    exit 1
  fi
done

# The scratch root lives OUTSIDE the repository: a measurement that writes into
# its own subject manufactures the defect it reports.
WV_CORPUS_TMP="$(mktemp -d "${TMPDIR:-/tmp}/wave-reason-corpus.XXXXXX")" || exit 1
export WV_RUN_TMP="$WV_CORPUS_TMP/run"
mkdir -p "$WV_RUN_TMP/logs" || exit 1
trap 'rm -rf "$WV_CORPUS_TMP"' EXIT

# shellcheck source=tests/lib/assert.sh
source "$WV_CORPUS_ROOT/tests/lib/assert.sh"

WV_REASONS="$WV_CORPUS_ROOT/hooks/reasons.tsv"
[ -f "$WV_REASONS" ] || { printf 'reason-corpus.sh: %s does not exist\n' "$WV_REASONS" >&2; exit 1; }

# The declared bounds. 400 is this gate's own limit and is tighter than AC-390's
# 600; the measured maximum is printed below so the headroom is visible.
WV_MAX_REASON=400
WV_MIN_NONSPACE=20

wv_fail_count=0
declare -a WV_FINDINGS=()

wv_finding() {
  WV_FINDINGS+=("$*")
  wv_fail_count=$((wv_fail_count + 1))
}

# ---------------------------------------------------------------------------
# The id universe and the templates, read from hooks/reasons.tsv. Never from a
# prose list: the precedence comment at the top of that same file is a SECOND
# copy and a check against it is self-consistency, not verification.
# ---------------------------------------------------------------------------

declare -a WV_IDS=()
declare -A WV_TMPL=()
declare -A WV_PREC=()
while IFS=$'\t' read -r rid prec tmpl; do
  case "$rid" in ''|'#'*|rule_id) continue ;; esac
  WV_IDS+=("$rid")
  WV_TMPL["$rid"]="$tmpl"
  WV_PREC["$rid"]="$prec"
done < "$WV_REASONS"

if [ "${#WV_IDS[@]}" -lt 2 ]; then
  printf 'reason-corpus.sh: read %s rule id(s) out of %s — nothing was measured\n' \
    "${#WV_IDS[@]}" "$WV_REASONS" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Section: index. Positive case and negative control per id, from the case
# files; and the two-way comparison against the ids the scripts actually emit.
# ---------------------------------------------------------------------------

declare -A WV_POS=()      # id -> newline-separated positive case files
declare -A WV_POSN=()     # id -> how many positive cases
declare -A WV_NEG=()      # id -> how many negative controls

while IFS= read -r f; do
  [ -s "$f" ] || continue
  jq -e 'type=="object"' "$f" >/dev/null 2>&1 || continue
  rid="$(jq -r '.expect.rule // empty' "$f" 2>/dev/null)"
  dec="$(jq -r '.expect.decision // empty' "$f" 2>/dev/null)"
  nid="$(jq -r '.expect.negative_control_for // empty' "$f" 2>/dev/null)"
  if [ -n "$rid" ]; then
    case "$dec" in
      deny|block|warn)
        WV_POSN["$rid"]=$(( ${WV_POSN[$rid]:-0} + 1 ))
        WV_POS["$rid"]="${WV_POS[$rid]:-}$f
"
        ;;
    esac
  fi
  [ -n "$nid" ] && WV_NEG["$nid"]=$(( ${WV_NEG[$nid]:-0} + 1 ))
done < <(find "$WV_CORPUS_ROOT/tests/cases" -type f -name '*.json' | sort)

# The ids the scripts emit, from a static scan of the emitter call sites.
WV_SCAN_PY="$WV_CORPUS_TMP/scan.py"
cat > "$WV_SCAN_PY" <<'PY'
"""Enumerate every wave-hook reason emission and how many arguments it passes.

Emits one TSV row per call site:
    <file>\t<line>\t<rule id or ?>\t<arg count or -1 for dynamic>\t<raw>

Bash quoting is walked by hand rather than handed to shlex: an argument is
routinely a "$(command substitution "with its own quotes")", which shlex splits
in the wrong place and would make the arity check report confident nonsense.
"""
import re
import sys

EMITTERS = ("wv_rule_deny", "wv_rule_warn", "wv_deny", "wv_warn", "wv_block",
            "wv_stop_warn")
# The pass-through wrappers themselves: they forward "${args[@]}" by design and
# are the mechanism, not a call site with an arity of its own.
WRAPPER_LINES = ("wv_deny \"$rule\" \"${args[@]}\"",
                 "wv_warn \"$rule\" \"${args[@]}\"",
                 "wv_block \"$rule\" \"${args[@]}\"",
                 "wv_deny \"$rule\"", "wv_warn \"$rule\"")


def split_args(text):
    """Top-level whitespace split, honouring quotes, $( ), ${ } and backslash."""
    out, cur = [], ""
    i, n = 0, len(text)
    depth = 0
    quote = None
    while i < n:
        c = text[i]
        if quote == "'":
            cur += c
            if c == "'":
                quote = None
            i += 1
            continue
        if c == "\\" and i + 1 < n:
            cur += text[i:i + 2]
            i += 2
            continue
        if quote == '"':
            if c == '"' and depth == 0:
                quote = None
                cur += c
                i += 1
                continue
            if text.startswith("$(", i) or text.startswith("${", i):
                depth += 1
                cur += text[i:i + 2]
                i += 2
                continue
            if c in ")}" and depth > 0:
                depth -= 1
                cur += c
                i += 1
                continue
            cur += c
            i += 1
            continue
        # unquoted
        if c in "\"'":
            quote = c
            cur += c
            i += 1
            continue
        if text.startswith("$(", i) or text.startswith("${", i):
            depth += 1
            cur += text[i:i + 2]
            i += 2
            continue
        if c in ")}" and depth > 0:
            depth -= 1
            cur += c
            i += 1
            continue
        if c.isspace() and depth == 0:
            if cur:
                out.append(cur)
                cur = ""
            i += 1
            continue
        cur += c
        i += 1
    if cur:
        out.append(cur)
    return out


def unquote(tok):
    if len(tok) >= 2 and tok[0] == tok[-1] and tok[0] in "\"'":
        return tok[1:-1]
    return tok


rows = []
for path in sys.argv[1:]:
    lines = open(path).read().split("\n")
    i = 0
    while i < len(lines):
        raw = lines[i]
        lineno = i + 1
        # Join backslash continuations so a call split over lines is one call.
        joined = raw
        while joined.rstrip().endswith("\\") and i + 1 < len(lines):
            joined = joined.rstrip()[:-1] + " " + lines[i + 1]
            i += 1
        i += 1

        stripped = joined.strip()
        if stripped.startswith("#"):
            continue
        m = re.search(r"(?<![\w-])(%s)\s" % "|".join(EMITTERS), stripped)
        if not m:
            continue
        # A definition line, not a call.
        if re.match(r"^(%s)\(\)" % "|".join(EMITTERS), stripped):
            continue
        call = stripped[m.start():]
        if any(call.startswith(w) for w in WRAPPER_LINES):
            continue
        toks = split_args(call)
        if len(toks) < 2:
            continue
        rule = unquote(toks[1])
        args = toks[2:]
        if any("[@]" in a for a in args) or not re.match(r"^W-[A-Z0-9-]+$", rule):
            count = -1
        else:
            count = len(args)
        rows.append("\t".join([path, str(lineno), rule, str(count),
                               call[:120].replace("\t", " ")]))

sys.stdout.write("\n".join(rows) + ("\n" if rows else ""))
PY

WV_SITES="$WV_CORPUS_TMP/sites.tsv"
if ! python3 "$WV_SCAN_PY" "$WV_CORPUS_ROOT"/scripts/hooks/*.sh > "$WV_SITES" 2>"$WV_CORPUS_TMP/scan.err"; then
  printf 'reason-corpus.sh: the call-site scan failed: %s\n' "$(cat "$WV_CORPUS_TMP/scan.err")" >&2
  exit 1
fi

wv_sites_total="$(command grep -c . "$WV_SITES" 2>/dev/null)"
case "$wv_sites_total" in ''|*[!0-9]*) wv_sites_total=0 ;; esac
if [ "$wv_sites_total" -lt 20 ]; then
  # An absent or tiny scan is a FAILED scan, not a clean tree.
  printf 'reason-corpus.sh: the call-site scan found only %s site(s) under scripts/hooks — that is a failed scan, not a clean one\n' \
    "$wv_sites_total" >&2
  exit 1
fi

declare -A WV_EMITTED=()
while IFS=$'\t' read -r sfile sline srule scount sraw; do
  [ -n "$srule" ] || continue
  case "$srule" in W-*) WV_EMITTED["$srule"]=1 ;; esac
done < "$WV_SITES"

printf '=== index ===\n'
printf '%-20s %-4s %-9s %-9s %s\n' RULE PREC POSITIVE NEGATIVE 'FIRST POSITIVE CASE'
printf '%s\n' '-------------------------------------------------------------------------------------------'
for rid in "${WV_IDS[@]}"; do
  pos="${WV_POSN[$rid]:-0}"
  neg="${WV_NEG[$rid]:-0}"
  first="$(printf '%s' "${WV_POS[$rid]:-}" | head -n1)"
  printf '%-20s %-4s %-9s %-9s %s\n' "$rid" "${WV_PREC[$rid]}" "$pos" "$neg" "$(basename "${first:-<none>}")"
  [ "$pos" -gt 0 ] || wv_finding "index: $rid has no positive case declaring expect.rule with a deny/block/warn decision"
  [ "$neg" -gt 0 ] || wv_finding "index: $rid has no negative control (expect.negative_control_for)"
done

# "Some script emits this id" is NOT asserted statically. Three ids reach their
# emitter through a variable (`emit_rule`, `verdict_rule`, `$WV_COND_RULE`), so a
# static scan reports them as unemitted and would be answered by loosening the
# scan until it matched comments too. The DRIVE section below proves emission the
# one way that cannot be faked: it runs a real script and reads the id out of the
# reason that script produced.
#
# The OTHER direction is static, and it is the one AC-399 needs: an id a script
# names that hooks/reasons.tsv has no template for falls through to the built-in
# apology, whose remedy is "see hooks/reasons.tsv, which has no template for this
# rule yet". Literals come from every script under scripts/, comments included —
# a comment naming an id that does not exist is itself a defect worth a finding.
while IFS= read -r wv_named; do
  [ -n "$wv_named" ] || continue
  [ -n "${WV_TMPL[$wv_named]+set}" ] || wv_finding "index: scripts/ names $wv_named but hooks/reasons.tsv has no template for it"
done < <(command grep -rhoE 'W-[A-Z][A-Z0-9]*(-[A-Z0-9]+)*' "$WV_CORPUS_ROOT/scripts" 2>/dev/null | sort -u)

# ---------------------------------------------------------------------------
# Section: arity.
# ---------------------------------------------------------------------------

wv_specifiers() {
  # wv_specifiers <template> -> how many printf conversion specifiers it has.
  # `%%` is a literal percent and is not one; nothing in reasons.tsv uses it, and
  # this is written so that a template that starts to would not miscount.
  printf '%s' "$1" | python3 -c '
import re, sys
t = sys.stdin.read()
t = t.replace("%%", "")
sys.stdout.write(str(len(re.findall(r"%[-#0 +]*[0-9.]*[a-zA-Z]", t))))
'
}

declare -A WV_SPEC=()
for rid in "${WV_IDS[@]}"; do
  WV_SPEC["$rid"]="$(wv_specifiers "${WV_TMPL[$rid]}")"
done

# lib.sh counts specifiers too: its wv_render truncates surplus arguments so a
# call site cannot make printf reuse the format string and double the reason. Two
# counters that disagreed would mean the guard protects a different arity from the
# one this gate checks. They are compared on every template — and the counts are
# derived independently (a hand-written bash scanner there, a regex here), so this
# is a comparison against a second derivation, not this gate importing the
# producer's own rule and becoming unable to fail.
for rid in "${WV_IDS[@]}"; do
  wv_lib_count="$(bash -c 'source "$1" >/dev/null 2>&1; wv_specifier_count "$2"' _ \
    "$WV_CORPUS_ROOT/scripts/hooks/lib.sh" "${WV_TMPL[$rid]}")"
  if [ "$wv_lib_count" != "${WV_SPEC[$rid]}" ]; then
    wv_finding "arity: lib.sh's wv_specifier_count says '$wv_lib_count' specifier(s) for $rid, this gate says ${WV_SPEC[$rid]} — the render guard and the gate disagree about the template"
  fi
done

printf '\n=== arity ===\n'
printf '%-20s %-5s %-5s %-9s %s\n' RULE SPECS ARGS VERDICT 'CALL SITE'
printf '%s\n' '-------------------------------------------------------------------------------------------'
wv_dynamic=0
wv_sites_checked=0
while IFS=$'\t' read -r sfile sline srule scount sraw; do
  [ -n "$srule" ] || continue
  rel="${sfile#"$WV_CORPUS_ROOT"/}"
  if [ "$scount" = "-1" ]; then
    wv_dynamic=$((wv_dynamic + 1))
    printf '%-20s %-5s %-5s %-9s %s\n' "$srule" "${WV_SPEC[$srule]:-?}" '(dyn)' dynamic "$rel:$sline"
    continue
  fi
  wv_sites_checked=$((wv_sites_checked + 1))
  want="${WV_SPEC[$srule]:-}"
  if [ -z "$want" ]; then
    printf '%-20s %-5s %-5s %-9s %s\n' "$srule" '?' "$scount" MISSING "$rel:$sline"
    wv_finding "arity: $rel:$sline emits $srule, which hooks/reasons.tsv has no template for"
    continue
  fi
  if [ "$want" = "$scount" ]; then
    [ "$WV_VERBOSE" = "1" ] && printf '%-20s %-5s %-5s %-9s %s\n' "$srule" "$want" "$scount" ok "$rel:$sline"
  else
    printf '%-20s %-5s %-5s %-9s %s\n' "$srule" "$want" "$scount" MISMATCH "$rel:$sline"
    if [ "$scount" -gt "$want" ]; then
      wv_finding "arity: $rel:$sline passes $scount argument(s) to $srule's $want-specifier template — printf REUSES the format string, so the whole reason renders twice and carries two W- tokens"
    else
      wv_finding "arity: $rel:$sline passes $scount argument(s) to $srule's $want-specifier template, so a placeholder renders empty"
    fi
  fi
done < "$WV_SITES"
printf 'sites=%s checked=%s dynamic=%s\n' "$wv_sites_total" "$wv_sites_checked" "$wv_dynamic"

# ---------------------------------------------------------------------------
# Section: drive + render. Each id's first positive case, run for real.
# ---------------------------------------------------------------------------

WV_RENDER_PY="$WV_CORPUS_TMP/render.py"
cat > "$WV_RENDER_PY" <<'PY'
"""Does <reason> match <template> with every specifier standing for some text?

The template's literal segments must appear in the reason IN ORDER, the first as
its prefix and the last as its suffix. That is the strongest statement that can
be made without knowing the fixture's values, and — unlike "starts with [ID]" —
it fails on template drift, on a dropped clause, and on a reason assembled by
anything other than this template.
"""
import re
import sys

tmpl = sys.argv[1]
reason = sys.argv[2]
segs = re.split(r"%[-#0 +]*[0-9.]*[a-zA-Z]", tmpl.replace("%%", "\x00"))
segs = [s.replace("\x00", "%") for s in segs]

pos = 0
if segs and segs[0]:
    if not reason.startswith(segs[0]):
        print("prefix: reason does not start with %r" % segs[0][:60])
        sys.exit(1)
    pos = len(segs[0])
for s in segs[1:-1]:
    if not s:
        continue
    j = reason.find(s, pos)
    if j < 0:
        print("segment: %r is absent after offset %d" % (s[:60], pos))
        sys.exit(1)
    pos = j + len(s)
if len(segs) > 1 and segs[-1]:
    if not reason.endswith(segs[-1]):
        print("suffix: reason does not end with %r" % segs[-1][:60])
        sys.exit(1)
sys.exit(0)
PY

printf '\n=== drive ===\n'
printf 'EVERY positive case of every id, not one per id: a length or placeholder\n'
printf 'defect lives in a FIXTURE as often as in a template, so one case per rule\n'
printf 'would measure a sample of the corpus while reporting on all of it.\n\n'
printf '%-20s %-6s %-7s %-7s %-9s %-5s %-8s %s\n' RULE CASES MAXLEN TOKENS PLACEHLD PATH VERDICT 'LONGEST CASE'
printf '%s\n' '---------------------------------------------------------------------------------------------------------'

wv_max_len=0
wv_max_len_rule="-"
wv_max_len_case="-"
wv_driven=0
wv_runs=0
for rid in "${WV_IDS[@]}"; do
  wv_id_cases=0
  wv_id_max=0
  wv_id_max_case="-"
  wv_id_verdict=ok
  wv_id_tokens=1
  wv_id_place=no
  wv_id_path=yes
  while IFS= read -r case_file; do
  [ -n "$case_file" ] || continue
  script="$(jq -r '.script // empty' "$case_file")"
  [ -n "$script" ] || { wv_finding "drive: $(basename "$case_file") has no script field"; continue; }

  WV_PROJECT=""
  if ! run_hook "$script" "$case_file"; then
    wv_finding "drive: $rid: run_hook on $(basename "$case_file") failed: $WV_LAST_STDERR"
    wv_id_verdict=BAD
    continue
  fi
  wv_id_cases=$((wv_id_cases + 1))
  wv_runs=$((wv_runs + 1))
  reason="$(_wv_reason_text)"
  if [ -z "$reason" ]; then
    # SubagentStop and PreCompact have no stdout warn channel: their warnings
    # reach the operator on stderr and nowhere else, so that IS the reason text.
    reason="${WV_LAST_STDERR:-}"
  fi

  cn="$(basename "$case_file" .json)"
  len="${#reason}"
  tokens="$(printf '%s' "$reason" | command grep -oE 'W-[A-Z0-9-]+' | wc -l | tr -d ' ')"
  own="$(printf '%s' "$reason" | command grep -oE 'W-[A-Z0-9-]+' | head -n1)"
  nonspace="$(printf '%s' "$reason" | tr -d '[:space:]' | wc -c | tr -d ' ')"
  if [ "$len" -gt "$wv_id_max" ]; then wv_id_max="$len"; wv_id_max_case="$cn"; fi
  if [ "$len" -gt "$wv_max_len" ]; then
    wv_max_len="$len"; wv_max_len_rule="$rid"; wv_max_len_case="$cn"
  fi

  case "$reason" in
    "[$rid] "*) : ;;
    *) wv_id_verdict=BAD; wv_finding "drive: $rid ($cn): reason does not start with '[$rid] ': '$reason'" ;;
  esac
  if [ "$tokens" != "1" ]; then
    wv_id_verdict=BAD; wv_id_tokens="$tokens"
    wv_finding "drive: $rid ($cn): reason carries $tokens W- token(s), want exactly 1: '$reason'"
  elif [ "$own" != "$rid" ]; then
    wv_id_verdict=BAD; wv_id_tokens="$own"
    wv_finding "drive: $rid ($cn): the single W- token is $own, not the rule's own id"
  fi
  if [ "$len" -gt "$WV_MAX_REASON" ]; then
    wv_id_verdict=BAD
    wv_finding "drive: $rid ($cn): reason is $len characters, over the $WV_MAX_REASON limit"
  fi
  case "$reason" in
    *'remedy:'*) : ;;
    *) wv_id_verdict=BAD; wv_finding "drive: $rid ($cn): reason has no 'remedy:' clause: '$reason'" ;;
  esac
  case "$reason" in
    *'%s'*|*'%d'*)
      wv_id_place=YES; wv_id_verdict=BAD
      wv_finding "drive: $rid ($cn): reason carries an unrendered placeholder: '$reason'"
      ;;
  esac
  case "$reason" in
    *"
"*) wv_id_verdict=BAD; wv_finding "drive: $rid ($cn): reason contains a newline" ;;
  esac
  if [ "$nonspace" -lt "$WV_MIN_NONSPACE" ]; then
    wv_id_verdict=BAD
    wv_finding "drive: $rid ($cn): reason has $nonspace non-whitespace characters, under the $WV_MIN_NONSPACE minimum"
  fi
  # A reason must not name the project root. A path inside the project is named
  # relative to it, because the root is not information the reader needs and an
  # absolute one is only true on the machine that rendered it. The ONE declared
  # exception is a reason whose whole claim is that a path resolved OUTSIDE the
  # root: naming the root is then the content, and a relative rendering would be
  # a lie.
  case "$reason" in
    *"$WV_PROJECT"*)
      case "$reason" in
        *'outside the project root'*) : ;;
        *)
          wv_id_path=NO; wv_id_verdict=BAD
          wv_finding "drive: $rid ($cn): reason names the project root ($WV_PROJECT) — name paths inside the project relative to it: '$reason'"
          ;;
      esac
      ;;
  esac

  # render: the template's literal segments, in order.
  if ! render_err="$(python3 "$WV_RENDER_PY" "${WV_TMPL[$rid]}" "$reason" 2>&1)"; then
    wv_id_verdict=BAD
    wv_finding "render: $rid ($cn): $render_err"
  fi

  [ "$WV_VERBOSE" = "1" ] && printf '    %-52s %s\n' "$cn" "$reason"
  done <<<"${WV_POS[$rid]:-}"

  [ "$wv_id_cases" -gt 0 ] && wv_driven=$((wv_driven + 1))
  printf '%-20s %-6s %-7s %-7s %-9s %-5s %-8s %s\n' \
    "$rid" "$wv_id_cases" "$wv_id_max" "$wv_id_tokens" "$wv_id_place" "$wv_id_path" \
    "$wv_id_verdict" "$wv_id_max_case"
done

# ---------------------------------------------------------------------------
# The verdict.
# ---------------------------------------------------------------------------

printf '\n=== bounds ===\n'
printf 'longest reason: %s characters — %s in %s; limit %s, headroom %s\n' \
  "$wv_max_len" "$wv_max_len_rule" "$wv_max_len_case" "$WV_MAX_REASON" \
  "$((WV_MAX_REASON - wv_max_len))"

if [ "${#WV_FINDINGS[@]}" -gt 0 ]; then
  printf '\n=== findings ===\n'
  for wv_f in "${WV_FINDINGS[@]}"; do
    printf 'FAIL %s\n' "$wv_f"
  done
fi

printf '\nrules=%s driven=%s cases=%s sites=%s findings=%s\n' \
  "${#WV_IDS[@]}" "$wv_driven" "$wv_runs" "$wv_sites_total" "$wv_fail_count"

# Every id must have been driven: an id skipped for want of a positive case is
# already a finding, and a rules-vs-driven mismatch with no finding would mean
# this gate silently measured a subset.
if [ "$wv_driven" -ne "${#WV_IDS[@]}" ] && [ "$wv_fail_count" -eq 0 ]; then
  printf 'FAIL corpus: drove %s of %s rules with no finding to explain the gap\n' \
    "$wv_driven" "${#WV_IDS[@]}"
  wv_fail_count=$((wv_fail_count + 1))
fi

[ "$wv_fail_count" -eq 0 ]
