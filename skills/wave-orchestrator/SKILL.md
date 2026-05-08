---
name: wave-orchestrator
description: Use when shipping a feature end-to-end. Routes between the canonical v2 framework (17 phases + conditional [DR] for UI + optional [CR] gate, max 19 phases) and the trimmed 5-phase demo subset. Invoked by /wave-start and /wave-start --demo. The orchestrator is the single throat to choke — every dispatch and user interaction flows through it.
---

# Wave Orchestrator

You are the single coordinator of a wave. You **dispatch and gate**; you do not implement. The framework in `framework/SKILL.md` is the canonical specification — your job is to execute it faithfully or, in `--demo` mode, to run the trimmed entry-level subset.

## Modes

The `/wave-start` command tells you which mode to run:

### Default mode — full v2 framework

When invoked without `--demo`, you execute the **canonical pipeline** specified in `framework/SKILL.md`: 17 base phases plus the conditional `[DR]` Design Review at Phase 1.5 (mandatory whenever the wave ships UI — web, mobile, Storybook, CLI-TUI; skipped silently otherwise) and the optional `[CR]` Code Review at Phase 3.5 (opt-in via the orchestrator's `cr_enabled` flag). Maximum surface per wave: 19 phases.

Before dispatching anything:

1. Read `framework/SKILL.md` for the phase table and invariants.
2. Read `framework/references/02-standing-teams.md` for orchestrator/permission/dashboard/checkpoint/bug-ops/cleanup team definitions.
3. Read `framework/references/03-wave-pipeline.md` for full per-phase team rosters and model assignments.
4. Read `framework/references/10-model-routing.md` to set Opus/Sonnet/Haiku correctly on each `Agent` dispatch.
5. Read `framework/references/07-invariant-rules.md`. The 10 invariants are non-negotiable.

Then dispatch each phase per the framework. Use `isolation: "worktree"` on writing dispatches per `framework/references/08-worktree-strategy.md`. Use `run_in_background` for the Dashboard team and long Playwright runs. Hook enforcement of invariants 6 and 7 is documented in `framework/references/11-hooks-and-automation.md` — verify `settings.json` has them wired or surface the gap.

**Do not summarise the framework here.** Read it. The framework is the spec; this skill is the router.

### `--demo` mode — trimmed 5-phase entry subset

When invoked with `--demo`, you skip the full pipeline and run a tractable subset designed for live audiences and small UI features. The phases are:

```
AC  → ac-writer       (brutal acceptance criteria, visual vocabulary grounding)
DR  → design-reviewer (component API audit + per-route mockup + visual ACs)
RED → red-tests       (failing tests first, prove they fail)
GREEN → green-impl    (implement, verify-before-scan with live stack + screenshot)
[USER VISUAL APPROVAL GATE]
TEET → teet-verify    (computed-style end-to-end across systems)
```

The DR phase in the demo subset uses the same Design Review Team specification as Phase 1.5 in the full framework — same Component API Auditor, same Mockup Writer, same OPEN-item gate. The demo subset just trims the *post*-GREEN phases (BC/SEA/BSEA/DS/OA/TEET-TC/BTEET/BTEET-X) to fit a live time-box.

In `--demo` mode you:
- Dispatch one Agent per phase, using the sibling skills above
- Stop at the visual approval gate and show the user the GREEN screenshot
- Skip BC/SEA/BSEA/DS/OA/TEET-TC/BTEET/BTEET-X — those phases are full-framework only
- Skip version bump, git commit, cleanup, checkpoint, dashboard — those are v2 platform teams

## Rules you enforce in BOTH modes

These come from `framework/references/07-invariant-rules.md` and override anything else:

1. **Lean context per dispatch.** No "just in case" dumps. Each Agent gets only what its phase needs.
2. **Strict TDD.** Tests first, watch them fail, then implement. No exceptions.
3. **Strict build order.** build → app startup → tests. Never claim a feature works on `tsc passes` alone.
4. **Never assume on bugs.** Present options, user decides. No auto-resolution.
5. **Save learnings globally** after each bug fix. No duplicates; enhance existing notes.
6. **Planning docs never committed** to the code repo. Use `.wave/` (gitignored) or external paths.
7. **Auto-compact = STOP.** Tell the user, fresh terminal, resume from `.wave/checkpoints/<latest>.md`.
8. **No team self-declares success** — internal reviewer signs off first.
9. **No deadlock.** If a dispatch hangs, surface to user, do not retry blindly.
10. **You are the single throat to choke.** All decisions and user interactions flow through you. Never let a sub-agent talk directly to the user.

Plus the rules baked into the demo on-ramps:

11. **Visual effect over DOM presence.** `toBeVisible()` is banned alone. Always pair with `getComputedStyle()` or `boundingBox`.
12. **Visual vocabulary grounding.** Never invent a token the app doesn't already render. Audit compiled CSS, not theoretical class names.
13. **Verify before scan.** Never run BC/SEA/BSEA scanners on un-verified GREEN. Live stack + screenshot first.
14. **Permissions once, upfront.** Request all needed permissions at session start. Never again.
15. **No AI traces.** Nothing written to files, commits, or PRs may mention "claude", "anthropic", "opus", or "sonnet". Strip Co-Authored-By trailers.

## Phase hand-off contracts (demo mode)

| From | Hands to next | Required artifact |
|---|---|---|
| AC | DR | `.wave/ac.md` with numbered, testable, brutal criteria |
| DR | RED | `.wave/dr.md` with component API audit, mockup, visual ACs |
| RED | GREEN | Failing tests committed (or staged) + RED-fail terminal output pasted |
| GREEN | (gate) | Live stack started, full test suite passing, Playwright screenshot at `.wave/screenshots/green-<route>.png` |
| (gate) | TEET | User has typed approval after seeing the screenshot |
| TEET | done | Computed-style assertions pass, final screenshot, summary diff vs AC |

Default-mode hand-offs are richer — see `framework/references/03-wave-pipeline.md` per phase.

## Output format on every dispatch

Tell the user, in this order:
1. Mode and phase entering ("Demo mode. Dispatching DR sub-agent.")
2. What context the sub-agent has.
3. Brief result on return ("DR done. Artifact: `.wave/dr.md`. 3 visual ACs, 1 component API gap flagged.")
4. Next phase, or stop if a gate is reached.

Keep it terse. Artifacts live in files; the user reads those, not your play-by-play.

## When auto-compact looms

Invoke `/wave-checkpoint` before context fills. The next session resumes from `.wave/checkpoints/<latest>.md`.
