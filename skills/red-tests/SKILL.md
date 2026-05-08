---
name: red-tests
description: Use after DR and before any production code is written. Writes failing tests that encode the AC and DR visual assertions, then proves they fail by running them. RED phase of TDD — strict, no exceptions.
---

# RED Tests

You write **tests first, watch them fail, then hand off**. No production code. No exceptions. The point of RED is to prove the test will catch the failure before any implementation rationalises around it.

## Why this skill exists

When implementation and tests are written together, the agent silently shapes the test to match what was easy to build. The feature ends with passing tests and broken behaviour. RED breaks that loop: you commit to the failure mode *before* knowing the implementation.

## Inputs

- `.wave/ac.md`
- `.wave/dr.md` (especially the visual ACs section)

## Procedure

### 1. Map ACs to tests

For each AC, write at least one test. For visual ACs from DR, the test must use:

- **`getComputedStyle()`** for color, font, spacing, border, transform values
- **`boundingBox()`** for size and position assertions
- **Real browser** (Playwright preferred) — not jsdom, not happy-dom — for any visual claim
- **Effective CSS bytes** comparison if the AC includes "the page is styled"

### 2. Banned assertion patterns (when used alone)

These pass on broken UIs and are forbidden as the *only* assertion in a visual test:

- `toBeVisible()` — passes on 0×0 elements
- `customElements.get(X) !== undefined` — registration ≠ rendering
- `not.toBeEmpty()` — passes with whitespace
- `getAttribute('data-theme') === 'dark'` — attribute set ≠ visible dark UI
- `toHaveCount(n)` on children without asserting their styles

Each must be paired with a computed-style or bounding-box check.

### 3. Write the tests

Place tests where the project conventions dictate (`tests/`, `e2e/`, `__tests__/`, `*.spec.ts`). If there is no test infra, set it up minimally — Playwright + a single config — and document the choice in `.wave/red.md`.

For non-UI ACs (API responses, persistence), use the project's existing test runner. Same rule: assertion must encode the AC, not the implementation.

### 4. Prove they fail

Run the test suite. The new tests **must fail**. Capture the failure output.

If a new test passes accidentally:
- The implementation already exists somewhere (great — strengthen the test until it fails meaningfully)
- Or the test is asserting a tautology (rewrite — your test is broken)

### 5. Document the RED state

Write `.wave/red.md` with:
- List of new test files
- For each test: AC reference, assertion type, **terminal output of the failure** (paste it)
- Test runner command for GREEN to use later

### 6. Hand off

Return to orchestrator with:
- Path to `.wave/red.md`
- Count of new tests
- Confirmation: "RED verified — N tests failing as expected."

If any new test passes at this stage, you do not hand off until you understand why and either delete the test or rewrite it.

## Anti-patterns

- Writing tests that assert what the code *does* (tautology) instead of what the AC *demands*
- Using mocks at the boundary the AC cares about. If the AC is about a real DB write, the test hits a real DB.
- Skipping RED because "I can see the code passes". You can't. Run the tests.
- Treating type errors or compile errors as "the test failed". Tests fail when they execute and the assertion is rejected — not when the runner can't start.
- Asserting on framework internals that may change (e.g. specific React reconciler messages).
