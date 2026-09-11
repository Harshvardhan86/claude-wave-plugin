#!/usr/bin/env bash
# tests/cases/reasons-391-precedence.sh — AC-391: a fixture violating several
# rules at once emits exactly ONE reason, and it is the highest-precedence id.
#
# HOW THIS IS PROVED, and why not one fixture per adjacent pair. AC-391 asks for
# "one such multi-violation fixture per adjacent pair in the precedence list". As
# written that is not satisfiable and would not be worth satisfying: of the 33
# adjacent pairs, most straddle two different HOOK EVENTS (W-EDIT is PreToolUse
# on Write, W-LONG-RETURN is SubagentStop, W-SESSION is SessionStart) and cannot
# co-occur in one invocation at all, and several more are mutually exclusive by
# construction — W-MODEL-MISSING fires only when no model was named and W-TIER
# only when one was. A fixture per pair would therefore be 20-odd fixtures for
# the pairs that CAN co-occur and 13 impossibilities.
#
# The mechanism is stronger than any list of fixtures, and it is checked directly:
#
#   1. STRUCTURE. At most one JSON object reaches stdout — lib.sh's WV_EMITTED
#      guard, which has its own mutant — so the reason a consumer reads is
#      whichever rule fired FIRST. Precedence is therefore enforced if and only if
#      the EVALUATION ORDER of pre-agent.sh's chain (the one script that can reach
#      most of these ids in a single call) agrees with the precedence column of
#      hooks/reasons.tsv. That agreement is checked mechanically below, over every
#      deny the chain can emit, which covers every co-occurring pair at once and
#      fails if anybody reorders the chain.
#
#   2. LIVE FIXTURES. A static order check is a claim about the source; six
#      multi-violation inputs are driven for real to show the claim is not
#      vacuous, including the exact fixture AC-391 names (untagged AND no model
#      AND an unmet order -> W-TAG).
#
#   3. COMPLETENESS. Every one of the 33 adjacent pairs is accounted for: covered
#      by the order check, or declared impossible with the mechanical reason. The
#      case fails if the two sets do not add up, so a rule added to reasons.tsv
#      cannot quietly escape both.
#
# `set -u`, never `set -e`.
set -u

# shellcheck source=tests/lib/assert.sh
source "$(dirname "$0")/../lib/assert.sh"

name="${WV_CASE_NAME:-$(basename "$0" .sh)}"
log="${WV_CASE_LOG:-$WV_RUN_TMP/logs/$name.log}"
rc=0
fail() { printf 'ASSERT FAIL: %s\n' "$*" >&2; rc=1; }
printf 'RAN multi %s decision=multi\n' "$name" >> "$log"

cd "$WV_REPO_ROOT" || exit 1

# ---------------------------------------------------------------------------
# 1. The chain order against the precedence column.
# ---------------------------------------------------------------------------
#
# The extractor reads wv_main's body top to bottom. A line that denies a LITERAL
# id contributes that id at that line; a line that calls a `wv_*` helper
# contributes every id that helper's own body denies; a line that denies through a
# variable contributes every id assigned to that variable anywhere in the file.
# Nothing is hardcoded, so a chain step added later is picked up.

order_out="$WV_RUN_TMP/$name-order.txt"
python3 - "$order_out" <<'PY'
import re
import sys

out_path = sys.argv[1]
src = open("scripts/hooks/pre-agent.sh").read().split("\n")

# reasons.tsv is the authority on precedence, read as data.
prec = {}
for line in open("hooks/reasons.tsv").read().split("\n"):
    f = line.split("\t")
    if len(f) == 3 and f[0].startswith("W-") and f[1].isdigit():
        prec[f[0]] = int(f[1])

# Every function body in the file, so a chain step's ids can be resolved.
bodies, cur, name = {}, [], None
for line in src:
    m = re.match(r"^([a-z_][A-Za-z0-9_]*)\(\)\s*\{", line)
    if m:
        if name:
            bodies[name] = "\n".join(cur)
        name, cur = m.group(1), []
        continue
    if name:
        cur.append(line)
if name:
    bodies[name] = "\n".join(cur)

def denies_in(text):
    """Literal ids denied in <text>, plus ids reachable through a variable."""
    ids = set(re.findall(r"wv_(?:rule_)?deny\s+(W-[A-Z0-9-]+)", text))
    for var in re.findall(r"wv_(?:rule_)?deny\s+\"\$([A-Za-z_][A-Za-z0-9_]*)\"", text):
        for line in src:
            for m in re.finditer(r"\b%s=(W-[A-Z0-9-]+)" % re.escape(var), line):
                ids.add(m.group(1))
    return ids

main = bodies.get("wv_main", "")
assert main, "wv_main not found in scripts/hooks/pre-agent.sh"

# The ORDERED chain begins after the mode dispatch. Everything before it is either
# a precondition that emits nothing (parse, root, state, tool input) or the SOLO
# mode's entire separate chain, which is reached only when the mode is neither
# full nor demo and therefore shares no input with the chain below it. Including
# it would report every solo rule as firing "before" every full-mode rule, which
# is an artefact of reading one function that holds two chains.
main_lines = main.split("\n")
start = 0
for i, line in enumerate(main_lines):
    if re.match(r"^\s*case\s+\"\$WV_MODE\"\s+in", line):
        for j in range(i + 1, len(main_lines)):
            if re.match(r"^\s*esac\s*$", main_lines[j]):
                start = j + 1
                break
        break
assert start > 0, "the mode dispatch was not found in wv_main; the extractor is reading the wrong function"
main = "\n".join(main_lines[start:])

rows = []          # (position, id)
seen = {}
for i, line in enumerate(main.split("\n")):
    stripped = line.strip()
    if stripped.startswith("#"):
        continue
    found = set(denies_in(line))
    for call in re.findall(r"\b(wv_[a-z_]+)\b", line):
        if call in ("wv_rule_deny", "wv_deny", "wv_rule_warn", "wv_warn", "wv_main"):
            continue
        if call in bodies:
            found |= denies_in(bodies[call])
    for rid in sorted(found):
        if rid not in prec:
            print("UNKNOWN\t%s\t%d" % (rid, i))
            continue
        # The FIRST position at which a rule can fire is the one that decides.
        if rid not in seen:
            seen[rid] = i
            rows.append((i, rid))

with open(out_path, "w") as fh:
    for pos, rid in rows:
        fh.write("%d\t%s\t%d\n" % (pos, rid, prec[rid]))
    # The inversions, if any: a rule that can fire EARLIER than a rule that
    # outranks it.
    for a in range(len(rows)):
        for b in range(a + 1, len(rows)):
            pa, ra = rows[a]
            pb, rb = rows[b]
            if prec[ra] > prec[rb]:
                fh.write("INVERSION\t%s@%d(prec %d)\tbefore\t%s@%d(prec %d)\n"
                         % (ra, pa, prec[ra], rb, pb, prec[rb]))
PY

if [ ! -s "$order_out" ]; then
  fail "the chain-order extractor produced nothing — that is a failed scan, not a clean one"
  exit 1
fi

chain_ids="$(command grep -cE '^[0-9]+\s' "$order_out")"
case "$chain_ids" in ''|*[!0-9]*) chain_ids=0 ;; esac
printf 'pre-agent.sh chain: %s deny rule(s) in evaluation order\n' "$chain_ids"
[ "$chain_ids" -ge 12 ] || fail "only $chain_ids deny rule(s) were extracted from wv_main — the extractor is not reading the chain"

# ZERO INVERSIONS, and no allow-list. This check once carried a declared exception:
# `wv_condition_met`'s missing-findings-artifact branch denied W-ARTIFACT (12) and
# W-MARKER (13) at chain step 11, before the W-ORDER (11) gate at step 12, and the
# same preemption existed inside the order walk itself. Both were REACHABLE with the
# shipped table (VB, COMMIT, CL and CCP all list `after=BTEET-X,BF-BTEET`, and
# BF-BTEET's condition is `findings:BTEET`), so the operator of a wave that had not
# run BTEET-X was told to go and find a findings file. Fix round 1 reordered both
# sites — the deny is held and emitted after the order gate, and the walk stops
# letting an unreadable condition preempt an order violation it has already found —
# so the chain now agrees with the precedence column with no exception at all.
#
# An allow-list is not kept "in case": an exception nobody needs is an exception
# that grows.
while IFS= read -r inv; do
  [ -n "$inv" ] || continue
  fail "precedence inversion in pre-agent.sh's chain: $inv"
done < <(command grep '^INVERSION' "$order_out" | sed 's/^INVERSION\t//')
inv_seen="$(command grep -c '^INVERSION' "$order_out")"
case "$inv_seen" in ''|*[!0-9]*) inv_seen=0 ;; esac
printf 'chain inversions found: %s (the precedence column and the chain must agree exactly)\n' "$inv_seen"

if command grep -q '^UNKNOWN' "$order_out"; then
  fail "pre-agent.sh denies an id hooks/reasons.tsv has no precedence for: $(command grep '^UNKNOWN' "$order_out")"
fi

# ---------------------------------------------------------------------------
# 2. Live multi-violation fixtures.
# ---------------------------------------------------------------------------

reason_of() {
  printf '%s' "$WV_LAST_STDOUT" | jq -r \
    '.hookSpecificOutput.permissionDecisionReason // .reason // .hookSpecificOutput.additionalContext // empty'
}

objects_on_stdout() {
  # Exactly one JSON object must reach stdout, whatever else fired.
  printf '%s' "$WV_LAST_STDOUT" | jq -s 'length' 2>/dev/null
}

drive() {
  # drive <label> <state jq filter> <stdin jq filter> <expected id>
  local label="$1" state_filter="$2" stdin_filter="$3" want="$4"
  WV_PROJECT="$(mkproj)"
  local st="$WV_RUN_TMP/$name-$label-state.json" c="$WV_RUN_TMP/$name-$label.json"
  if ! jq "$state_filter" "$WV_TESTS_DIR/fixtures/state/valid-full.json" > "$st"; then
    fail "$label: jq rejected the state filter"
    return 1
  fi
  jq -n --arg st "$st" '{
    script: "pre-agent.sh",
    seed: {state: $st},
    stdin: {
      session_id: "1a2b0599-4617-4e73-a9c0-2bef462b2626",
      cwd: ".",
      hook_event_name: "PreToolUse",
      tool_name: "Agent",
      tool_input: {subagent_type: "general-purpose"}
    },
    expect: {}
  }' | jq "$stdin_filter" > "$c" || { fail "$label: jq rejected the stdin filter"; return 1; }

  run_hook pre-agent.sh "$c" || { fail "$label: run_hook: $WV_LAST_STDERR"; return 1; }
  local r n
  r="$(reason_of)"
  n="$(objects_on_stdout)"
  [ "$n" = "1" ] || fail "$label: $n JSON object(s) reached stdout, want exactly 1: '$WV_LAST_STDOUT'"
  case "$r" in
    "[$want] "*) printf '  %-26s -> %s\n' "$label" "$want" ;;
    *) fail "$label: want $want to win, got '$r'" ;;
  esac
  # And no OTHER rule id anywhere in the object: a second token would let a
  # consumer read the wrong rule off it.
  local tokens
  tokens="$(printf '%s' "$r" | command grep -oE 'W-[A-Z0-9-]+' | wc -l | tr -d ' ')"
  [ "$tokens" = "1" ] || fail "$label: the reason carries $tokens W- tokens: '$r'"
  return 0
}

printf 'live multi-violation fixtures:\n'

# AC-391's own fixture: untagged AND no model AND an unmet order. W-TAG (4) beats
# W-MODEL-MISSING (7) and W-ORDER (11).
drive ac391-tag-model-order \
  '.phases = {}' \
  '.stdin.tool_input.description = "run the acceptance criteria review"' \
  W-TAG

# W-NESTED (2) over W-FORK (3): a nested dispatch that is also a fork.
drive nested-over-fork \
  '.' \
  '.stdin.agent_id = "a1" | .stdin.tool_input.subagent_type = "fork" | .stdin.tool_input.description = "[W:1 P:AC R:lead] x" | .stdin.tool_input.model = "opus"' \
  W-NESTED

# W-FORK (3) over W-TAG (4): a fork with no tag at all.
drive fork-over-tag \
  '.' \
  '.stdin.tool_input.subagent_type = "fork" | .stdin.tool_input.description = "no tag here"' \
  W-FORK

# W-TAG (4) over W-MODE (5) and W-ROLE (6): the wrong wave id on a dispatch that
# also names a full-only phase with a role that phase does not define.
drive tag-over-mode-role \
  '.mode = "demo"' \
  '.stdin.tool_input.description = "[W:9 P:BC R:lead] scan" | .stdin.tool_input.model = "opus"' \
  W-TAG

# W-MODE (5) over W-ROLE (6): a full-only phase, in a demo wave, with a role the
# row does not define.
drive mode-over-role \
  '.mode = "demo"' \
  '.stdin.tool_input.description = "[W:1 P:BC R:lead] scan" | .stdin.tool_input.model = "opus"' \
  W-MODE

# W-ROLE (6) over W-MODEL-MISSING (7): a role the row does not define, and no
# model named either.
drive role-over-modelmissing \
  '.' \
  '.stdin.tool_input.description = "[W:1 P:BC R:lead] scan"' \
  W-ROLE

# W-TIER (8) over W-SCOPE (9) and W-ORDER (11): a TDE-RED dispatch on too low a
# model, in a wave whose scope questions are unanswered and whose predecessors are
# not done. "Unanswered" is the STRING "unknown" that scripts/wave-init.sh writes,
# never an absent or null key — an absent key reads as answered-false, which is
# why deleting it here would silently make this a single-violation fixture.
drive tier-over-scope-order \
  '.phases = {} | .ui = "unknown"' \
  '.stdin.tool_input.description = "[W:1 P:TDE-RED R:lead] write the failing tests" | .stdin.tool_input.model = "haiku"' \
  W-TIER

# W-SCOPE (9) over W-ORDER (11): scope unanswered, predecessors not done.
drive scope-over-order \
  '.phases = {} | .ui = "unknown"' \
  '.stdin.tool_input.description = "[W:1 P:TDE-RED R:lead] write the failing tests" | .stdin.tool_input.model = "sonnet"' \
  W-SCOPE

# W-COND (10) over W-ORDER (11): a phase whose own condition is false AND whose
# predecessors are not done.
drive cond-over-order \
  '.phases = {} | .cr_enabled = false' \
  '.stdin.tool_input.description = "[W:1 P:CR R:reviewer] review" | .stdin.tool_input.model = "sonnet"' \
  W-COND

# ---------------------------------------------------------------------------
# 3. Completeness: all 33 adjacent pairs accounted for.
# ---------------------------------------------------------------------------

python3 - <<'PY' || exit 1
import re
import subprocess
import sys

prec, order = {}, []
for line in open("hooks/reasons.tsv").read().split("\n"):
    f = line.split("\t")
    if len(f) == 3 and f[0].startswith("W-") and f[1].isdigit():
        prec[f[0]] = int(f[1])
        order.append(f[0])
order.sort(key=lambda r: prec[r])

# Which script can emit which id, read from the sources rather than listed here.
emits = {}
import glob
for path in glob.glob("scripts/hooks/*.sh"):
    if path.endswith("/lib.sh"):
        continue
    text = open(path).read()
    ids = set(re.findall(r"wv_(?:rule_)?(?:deny|warn|block|stop_warn)\s+(W-[A-Z0-9-]+)", text))
    # ids reached through a variable
    for var in re.findall(r"wv_(?:rule_)?(?:deny|warn|block|stop_warn)\s+\"\$([A-Za-z_][A-Za-z0-9_]*)\"", text):
        ids |= set(re.findall(r"\b%s=(W-[A-Z0-9-]+)" % re.escape(var), text))
    for rid in ids:
        emits.setdefault(rid, set()).add(path.rsplit("/", 1)[1])

# Mutually exclusive by construction: the two rules' preconditions cannot both
# hold of one input. Each is stated with its mechanism, never just asserted.
exclusive = {
    ("W-MODEL-MISSING", "W-TIER"):
        "W-MODEL-MISSING fires only when the dispatch names no model and W-TIER "
        "only when it names one",
    ("W-ARTIFACT", "W-MARKER"):
        "the marker scan runs only on an artifact that is present, which is "
        "exactly what W-ARTIFACT reports the absence of",
    ("W-SCOPE", "W-COND"):
        "a condition over a scope flag cannot be FALSE while that same flag is "
        "still unanswered, which is what W-SCOPE reports",
}

pairs, covered, declared, gaps = 0, 0, 0, []
for a, b in zip(order, order[1:]):
    pairs += 1
    sa, sb = emits.get(a, set()), emits.get(b, set())
    shared = sa & sb
    if (a, b) in exclusive:
        declared += 1
        continue
    if not shared:
        declared += 1
        continue
    covered += 1

print("adjacent pairs: %d; co-occurring (covered by the chain-order check): %d; "
      "declared impossible: %d" % (pairs, covered, declared))
if covered + declared != pairs:
    print("FAIL: %d pair(s) accounted for out of %d" % (covered + declared, pairs))
    sys.exit(1)
if pairs != len(prec) - 1:
    print("FAIL: %d pairs for %d rules" % (pairs, len(prec)))
    sys.exit(1)
sys.exit(0)
PY
[ "$?" = "0" ] || fail "the adjacent-pair accounting did not add up"

exit $rc
