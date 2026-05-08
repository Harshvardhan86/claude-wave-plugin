---
name: teet-verify
description: Use only after the user has approved the GREEN screenshot. Performs True End-to-End Testing across backend, frontend, DB, and external services with computed-style and boundingBox assertions, producing the final wave evidence pack.
---

# TEET — True End-to-End Testing

TEET is the final phase. It is the **independent re-verification** of the wave: a fresh agent (you) runs the full app stack and asserts every AC with the strictest possible evidence — computed styles, bounding boxes, real network calls, real persistence.

## Why this is its own phase

GREEN's job is to make tests pass. TEET's job is to **distrust GREEN** and re-verify against the original AC. The same agent that wrote the implementation cannot reliably grade it. Lean, dedicated context per phase is the rule.

## Pre-condition

The orchestrator only invokes you **after the user typed approval of the GREEN screenshot.** If you're invoked without that, refuse and tell the orchestrator to gate.

## Inputs

- `.wave/ac.md`
- `.wave/dr.md`
- `.wave/green.md`
- `.wave/screenshots/green-*.png`

## Procedure

### 1. Bring up the entire stack

- Frontend, backend, DB, queues, external service emulators if used
- Use the project's documented startup procedure (do not invent one)
- Wait until every service reports healthy

### 2. Walk every route, click every interactive element

For multi-step flows (wizards, onboarding, dashboards):

- Click through the *entire* flow end-to-end with Playwright
- Take a screenshot at every step, save to `.wave/screenshots/teet-step-N-<route>.png`
- Verify the final state is fully correct, not just "mostly done"
- **Reload the page mid-flow** — does state persist correctly?
- Click every button, link, toggle and verify its observable effect

### 3. Computed-style and boundingBox assertions

For every visual AC from DR:

- Assert with `getComputedStyle()` not `toBeVisible()`
- Assert with `boundingBox()` for sizes and positions
- Compute total effective CSS bytes for the route — if below a project-set threshold, flag (the page is unstyled)
- Compare each route screenshot against a known-good reference if one exists (e.g., the previous successful wave's screenshot)

### 4. Cross-system assertions

For ACs that span systems (e.g., "toggle dark mode → persisted in DB → visible after fresh login"):

- Drive the action through the UI
- Verify the side effect via direct DB query / API call / log inspection
- Log evidence in `.wave/teet.md`

### 5. Negative cases

For each AC's "rejects" clause, attempt the failure scenario and prove it does fail:

- Disable the toggle while persistence is in flight — does the optimistic state revert correctly?
- Rapid-fire-click — no double-fire?
- Keyboard-only navigation — fully operable?

### 6. Diff vs original AC

Read `.wave/ac.md`. For each AC, mark in `.wave/teet.md`:
- ✅ verified, with evidence reference (screenshot path / log line / DB query result)
- ⚠️ partial, with what's missing
- ❌ failed, with screenshot of the failure

### 7. Output

Write `.wave/teet.md`:

```markdown
# TEET Report — <feature>

## Stack health
<services up, response times, etc.>

## AC-by-AC verification
- AC-1: ✅ — see screenshots/teet-step-1-settings.png + getComputedStyle assertion log
- AC-2: ⚠️ — persistence works but takes 800ms (AC said <500ms)
- AC-3: ❌ — keyboard navigation skips the toggle; see screenshots/teet-keyboard-fail.png

## Evidence
- Screenshots: <list>
- DB queries run: <list>
- Network requests captured: <list>

## Recommendation
- PASS / PARTIAL PASS / FAIL
```

Return to orchestrator with this verdict. The orchestrator escalates any ⚠️ or ❌ to the user as a P0 — not "minor", not "follow-up".

## Hard rules

- **All bugs are P0.** A ⚠️ is a bug. There is no "we'll get to it later".
- **No `toBeVisible()`-only assertions.** Always pair with computed-style or boundingBox.
- **No mock infrastructure for TEET.** Real services, real DB, real network.
- **Visual baselines must be user-approved before commit.** If you create a new golden screenshot, surface it for user approval — don't lock a broken state in as the reference.

## Anti-patterns

- Re-running GREEN's tests and calling that "TEET" — TEET writes new assertions
- Inferring success from log absence ("no errors logged, must be working")
- Skipping the reload-mid-flow check because "state persistence isn't part of this AC" — it always is
- Reporting PASS with any ⚠️ unaddressed
