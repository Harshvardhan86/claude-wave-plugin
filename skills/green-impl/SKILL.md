---
name: green-impl
description: Use after RED is verified failing. Writes the minimum code to make RED tests pass, then verifies on a live stack with Playwright screenshots before any hand-off. Implements the verify-before-scan rule.
---

# GREEN Implementation

You implement **the minimum code to make the RED tests pass**, and then you do something most agents skip: you start the live stack, run the full test suite against it, and take a screenshot. Only then do you hand off.

## Why this skill exists

GREEN hand-off is **never** acceptable on `tsc passes` or `build clean` alone. That hand-off pattern produces piles of fake bugs in scanner phases. Verify-before-scan exists because real bugs hide behind builds that compile but apps that don't render.

## Inputs

- `.wave/ac.md`
- `.wave/dr.md`
- `.wave/red.md` (with RED-failing test output)

## Procedure

### 1. Implement to the contract

- Use only tokens, components, and APIs documented in DR. If you find yourself wanting a token DR didn't audit, stop and surface it. Do not silently sub in a Tailwind default.
- Trace every config field end-to-end. If you add a config option, add the dispatch that reads it *and* a test that proves the runtime behaviour changes when the config changes. Catalog without dispatch is a lie.
- Keep the change surface minimal. No drive-by refactors, no "while I'm here" cleanup.

### 2. Make tests pass

Run the test suite. Iterate until RED tests pass and *no existing tests break*. If existing tests break, treat each as a P0 bug — fix the root cause, do not delete or skip the test.

### 3. Verify on a live stack — REQUIRED, NOT OPTIONAL

Before declaring done, you MUST:

a. **Start the live stack.** Run the project's actual dev/prod command (`npm run dev`, `make run`, `docker compose up`, whatever the project uses). Wait until the app is reachable.

b. **Run the full phase test suite against the live stack.** Not just the new tests — the full suite. Capture pass/fail.

c. **Take a Playwright screenshot at every route the wave touches.** Save to `.wave/screenshots/green-<route>.png`. Open the screenshot yourself and inspect it — does the visual match the DR mockup?

d. **If a screenshot shows a visual bug,** you fix it directly, in this same skill, in one edit pass. Do not dispatch another agent for a failure mode you already observed. Re-run the suite, re-screenshot.

### 4. Document the GREEN state

Write `.wave/green.md` with:
- Files changed (list)
- Test suite output (pass count, paste any failures)
- Screenshot paths for each route
- One-paragraph "what's visually different now" for the user

### 5. Hand off to the visual approval gate

Return to orchestrator with:
- `.wave/green.md` path
- Screenshot paths inline so the orchestrator can show the user
- Confirmation: "GREEN verified — live stack up, N tests pass, M screenshots captured."

The orchestrator stops here for user approval. Do not invoke TEET yourself.

## Hard rules

- **No "tsc passes" hand-off.** If you tell the user "build is clean" without a screenshot, you have failed this skill.
- **No silent token substitution.** If DR didn't audit a color, you don't use it.
- **No "this should work" without seeing it.** If you can't run the stack (e.g. no Docker available), say so explicitly and stop. Do not proceed on assumption.
- **One implementation pass + one fix pass = your budget.** If after that the visual is still wrong, hand off to the user with the failing screenshot. They decide whether the DR was wrong, the AC was wrong, or the implementation needs more work.
- **No commit yet.** Commit happens after TEET and only at user request.

## Anti-patterns

- Reporting "GREEN done" with only test output, no screenshot
- Adding error handling, retries, or fallbacks the AC didn't ask for
- Adding a feature flag because "we might want to disable it" (wait until you do)
- Writing comments explaining what the code does ("this sets the theme") — name things instead
- Touching files unrelated to the wave to "fix something I noticed"
