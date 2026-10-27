---
description: Start a new wave. Default runs the canonical v2 framework (31 phase rows: 18 always, 13 conditional — [UIA]/[ES] on new vocabulary, [BEN]/[BEN-CLOSE] on changed behaviour, [DR] at 1.5 on UI or changed behaviour, the optional [CR] gate at 3.5, and each [BF-*] row on findings; max 31). Pass --demo for the trimmed 5-phase subset (AC → DR → RED → GREEN → TEET) for live demos and small UI features, or --solo for a directly-driven task with only the cheap invariants enforced.
argument-hint: "[--demo|--solo] <feature description in quotes>"
allowed-tools: "Bash(git:*), Bash(npm:*), Bash(pnpm:*), Bash(yarn:*), Bash(npx:*), Bash(curl:*), Bash(${CLAUDE_PLUGIN_ROOT}/scripts/wave-init.sh:*), Bash(${CLAUDE_PLUGIN_ROOT}/scripts/wave-set.sh:*)"
---

# Start a new wave

## Context

- Working dir: !`pwd`
- Git repo: !`git rev-parse --is-inside-work-tree 2>/dev/null && echo "Yes" || echo "No"`
- Branch: !`git branch --show-current 2>/dev/null || echo "n/a"`
- Dirty tree: !`git status --porcelain 2>/dev/null | head -1 | grep -q . && echo "Yes (commit or stash before starting a wave)" || echo "Clean"`

## Instructions

The user invoked `/wave-start` with arguments: **$ARGUMENTS**

### Step 1 — parse the mode

- If `$ARGUMENTS` starts with `--demo`, set mode = `demo`. The feature description is everything after `--demo`.
- If `$ARGUMENTS` starts with `--solo`, set mode = `solo`. The feature description is everything after `--solo`.
- Otherwise, set mode = `full`. The feature description is the entire `$ARGUMENTS`.

If the feature description is empty, refuse and remind the user of the syntax:
```
/wave-start "<feature description>"           # full v2 framework (31 phase rows: 18 always + 13 conditional)
/wave-start --demo "<feature description>"    # trimmed 5-phase demo subset
/wave-start --solo "<feature description>"    # directly-driven task, cheap invariants only
```

### Step 0 — start the wave state

For `full` and `demo` mode, first ask the two early scope questions in the
conversation (never guess an answer). They must be answered BEFORE
`wave-init.sh` runs, and are passed to it as flags:

- **vocabulary** — Does this wave introduce a new kind of record, or a new value of an existing classification (a status, a category, a role), that a user will see?
- **behaviour-change** — does this wave change existing system behaviour?

Then start the wave's on-disk state so every hook enforced during this wave
can find it:

```
"${CLAUDE_PLUGIN_ROOT}"/scripts/wave-init.sh --wave <next-wave-id> \
  --mode <full|demo>        # omit and pass --solo instead, for solo mode
  --enforce block \
  --vocabulary | --no-vocabulary \
  --behaviour-change | --no-behaviour-change \
  --feature "<feature description>"
```

Pick `<next-wave-id>` as one past the highest wave id already recorded under
`.wave/archive/`, or `1` if `.wave/` does not exist yet.

If `wave-init.sh` exits non-zero, print its stderr to the user and **stop** —
do not invoke the orchestrator with no wave state behind it.

Then ask the remaining two scope questions (never guess an answer):
- **ui** — does this wave touch anything the user looks at?
- **cr** — is there a Change Request in effect for this wave?

Route the ui and cr answers through `wave-set.sh`, which records them in
state and in `.wave/approvals/scope.md`. The same command can correct a
vocabulary or behaviour-change answer after init:

```
"${CLAUDE_PLUGIN_ROOT}"/scripts/wave-set.sh ui <true|false>
"${CLAUDE_PLUGIN_ROOT}"/scripts/wave-set.sh behaviour-change <true|false>
"${CLAUDE_PLUGIN_ROOT}"/scripts/wave-set.sh cr <true|false>
"${CLAUDE_PLUGIN_ROOT}"/scripts/wave-set.sh vocabulary <true|false>
```

`solo` mode skips the four scope questions — `phases.tsv` is not consulted
in solo mode at all (spec section 6), so there is nothing for them to gate.

**Refusal:** if `.wave/state.json` is not present after this step, stop here
with one line telling the user wave-init.sh did not run successfully; do not
proceed to Step 2.

### Step 2 — invoke the wave-orchestrator skill

Invoke the `wave-orchestrator` skill, passing:
- The mode (`full`, `demo`, or `solo`)
- The feature description

The orchestrator owns everything from here. Do not implement, dispatch, or instruct further yourself. The orchestrator's `SKILL.md` defines exactly how each mode runs.

### Step 3 — observe the rules

Every mode enforces:
- Lean, dedicated context per dispatch (no combined phases)
- Strict TDD: RED before GREEN, watch tests fail before any code is written
- All bugs P0; user decides how to fix
- "tsc passes" is NEVER hand-off evidence — live stack + screenshot is
- Visual assertions use `getComputedStyle()` and `boundingBox`, never `toBeVisible()` alone
- No AI traces in files, commits, or PRs
- **The dispatch tag.** While a `full` or `demo` wave is active, every `Agent`
  dispatch made from this session must begin its `description` (or the first
  line of its `prompt`) with `[W:<wave> P:<PHASE> R:<lead|executor|reviewer|scanner|writer>]` —
  for example `[W:1 P:TDE-GREEN R:executor] implement AC-3..AC-7`. An
  untagged dispatch during an active wave is denied.

`full` mode additionally:
- Loads `framework/SKILL.md` and selected `framework/references/*.md` per phase
- Routes dispatches to Opus / Sonnet / Haiku per `framework/references/10-model-routing.md`
- Uses `isolation: "worktree"` on writing dispatches
- Runs Dashboard and long Playwright via `run_in_background`
- Engages `[DR]` at Phase 1.5 whenever the wave ships UI **or changes existing behaviour**; skips it silently otherwise
- Includes BC, SEA, BSEA, DS, OA, TEET-TC, BTEET, BTEET-X, version bump, commit, cleanup, checkpoint, dashboard

`demo` mode runs only AC → DR → RED → GREEN → TEET with the visual approval gate, and uses the sibling skills (`ac-writer`, `design-reviewer`, `red-tests`, `green-impl`, `teet-verify`) directly.

`solo` mode is for a single medium task you drive directly, with at most a
separate review dispatch. The dispatch tag, `phases.tsv` gating, the round
ceiling and the budget gate are not enforced; the commit guard, the
`.git/hooks/commit-msg` guard, and the PreCompact checkpoint still are.

Begin now.
