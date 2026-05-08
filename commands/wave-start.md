---
description: Start a new wave. Default runs the canonical v2 framework (17 phases + conditional [DR] for UI waves at 1.5 + optional [CR] gate at 3.5, max 19). Pass --demo to run the trimmed 5-phase subset (AC → DR → RED → GREEN → TEET) for live demos and small UI features.
argument-hint: "[--demo] <feature description in quotes>"
allowed-tools: "Bash(git:*), Bash(npm:*), Bash(pnpm:*), Bash(yarn:*), Bash(npx:*), Bash(curl:*)"
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
- Otherwise, set mode = `full`. The feature description is the entire `$ARGUMENTS`.

If the feature description is empty, refuse and remind the user of the syntax:
```
/wave-start "<feature description>"           # full v2 framework (17 base phases + conditional [DR]/[CR] gates)
/wave-start --demo "<feature description>"    # trimmed 5-phase demo subset
```

### Step 2 — invoke the wave-orchestrator skill

Invoke the `wave-orchestrator` skill, passing:
- The mode (`full` or `demo`)
- The feature description

The orchestrator owns everything from here. Do not implement, dispatch, or instruct further yourself. The orchestrator's `SKILL.md` defines exactly how each mode runs.

### Step 3 — observe the rules

Both modes enforce:
- Lean, dedicated context per dispatch (no combined phases)
- Strict TDD: RED before GREEN, watch tests fail before any code is written
- All bugs P0; user decides how to fix
- "tsc passes" is NEVER hand-off evidence — live stack + screenshot is
- Visual assertions use `getComputedStyle()` and `boundingBox`, never `toBeVisible()` alone
- No AI traces in files, commits, or PRs

`full` mode additionally:
- Loads `framework/SKILL.md` and selected `framework/references/*.md` per phase
- Routes dispatches to Opus / Sonnet / Haiku per `framework/references/10-model-routing.md`
- Uses `isolation: "worktree"` on writing dispatches
- Runs Dashboard and long Playwright via `run_in_background`
- Engages `[DR]` at Phase 1.5 whenever the wave ships UI; skips it silently otherwise
- Includes BC, SEA, BSEA, DS, OA, TEET-TC, BTEET, BTEET-X, version bump, commit, cleanup, checkpoint, dashboard

`demo` mode runs only AC → DR → RED → GREEN → TEET with the visual approval gate, and uses the sibling skills (`ac-writer`, `design-reviewer`, `red-tests`, `green-impl`, `teet-verify`) directly.

Begin now.
