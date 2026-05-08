---
name: wave-execution-framework-v2
description: Use when executing multi-wave engineering work needing strict TDD, bug-capture/fix split, quality gates, and orchestrated teams with per-agent Opus-advisor / Sonnet-executor model routing.
effort: xhigh
---

# Wave Execution Framework v2 — Model-Routed

A multi-wave, multi-team engineering execution framework. Work is decomposed into waves; each wave runs a strict 17-phase pipeline plus two conditional gates: `[DR]` Design Review at Phase 1.5 (**mandatory** when the wave ships UI — web, mobile, Storybook, or CLI-TUI) and `[CR]` Code Review at Phase 3.5 (optional, opt-in). Maximum surface per wave: 19 phases. Enforced by specialized subagent teams (Stream-Aligned, Quality Gate, Platform, Enabling). **The orchestrator is the single point of coordination and the single throat to choke.**

v2 preserves every phase, invariant, and cardinal rule from v1 and adds three changes that realize the framework against the current (2026) Claude Code / Agent SDK primitives:

1. **Model routing.** Every dispatch specifies its model on the `Agent` tool. Opus = advisory (plan, critique, decide). Sonnet = executor (write code, run tests, scan, fix). Haiku = mechanical (dashboard render, version bump). See [`references/10-model-routing.md`](references/10-model-routing.md).
2. **Team-as-dispatch-pattern.** Nested subagents are not supported in Claude Code, so v2 re-expresses every L2 "team" as either a single Agent dispatch carrying Lead + Executor + Reviewer personas, or a sequence of dispatches the orchestrator coordinates. Fresh-eyes hardening (`[ACB]`, `[BSEA]`, `[BTEET]`) is enforced by *separate* dispatches with only the prior output in context. See [`references/01-architecture.md`](references/01-architecture.md).
3. **Native platform primitives.** `isolation: "worktree"` on writing dispatches; `run_in_background` for Dashboard and long Playwright runs; `PreCompact` / `PostToolUse` / `PreToolUse` hooks to enforce invariants; `TaskCreate` replaces `tasks/todo.md`; `ToolSearch` gates the per-phase tool surface. See [`references/09-platform-deltas.md`](references/09-platform-deltas.md), [`references/11-hooks-and-automation.md`](references/11-hooks-and-automation.md), [`references/12-mcp-and-plugins.md`](references/12-mcp-and-plugins.md).

## When to use

- Multi-wave projects (3+ discrete vertical slices of value).
- Work requiring strict TDD (RED → GREEN) and user-approved bug fixes.
- Projects where silent errors, skipped tests, or context pollution have burned you before.
- Cross-language binding work (N-API / FFI / WASM) — see [`references/05-language-binding-rules.md`](references/05-language-binding-rules.md).
- Any time quality gates (dependency audit, silent-error scan, brutal E2E) must block release.

## When NOT to use

- Single-file edits, typo fixes, renames.
- Research-only tasks with no code changes.
- Prototypes where discipline intentionally slows exploration.

## Abbreviations

`AC`=Acceptance Criteria · `ACB`=Brutal AC · `DR`=Design Review (UI waves only) · `TDE`=Test-Driven Execution · `CR`=Code Review (optional) · `BC`=Bug Capture · `BF`=Bug Fix · `SEA`=Silent Error Analysis · `BSEA`=Brutal SEA · `DS`=Dependency Scan · `OA`=Output Alignment · `TEET`=True E2E Testing · `TEET-TC`=TEET Test Case Design · `BTEET`=Brutal TEET · `BTEET-X`=Brutal TEET Execution · `CL`=Cleanup · `CCP`=Checkpoint · `AD`=Dashboard Update · `E`=Enabling · `SA`=Stream-Aligned · `QG`=Quality Gate · `P`=Platform

## Wave pipeline (17 sequential phases + 2 conditional gates)

| # | Code | Phase | Team | Topology | Lead / Executor / Reviewer model |
|---|------|-------|------|----------|----------------------------------|
| 1 | `[AC]` | Acceptance Criteria | AC Team | E | **Opus** / Sonnet / **Opus** |
| 1.2 | `[ACB]` | Brutal AC Review (fresh eyes) | AC Hardening Team | E | **Opus** / **Opus** / **Opus** |
| 1.5 | `[DR]` | Design Review (**mandatory for UI waves**, skipped otherwise) | Design Review Team | E | **Opus** / Sonnet / **Opus** |
| 2 | `[TDE-RED]` | Write tests, verify FAIL | TDD-RED Team | SA | Sonnet / Sonnet / Sonnet |
| 3 | `[TDE-GREEN]` | Implement, verify PASS (`isolation: worktree`) | TDD-GREEN Team | SA | Sonnet / Sonnet / **Opus** |
| 3.5 | `[CR]` | Code Review gate (CodeRabbit — **optional**) | CodeRabbit Plugin | QG | plugin-managed |
| 4 | `[BC]` | Bug Capture | Bug Capture Team | QG | Sonnet |
| 4.1 | `[BF-BC]` | Fix BC findings (user approves) | Bug Fix Team | SA | **Opus** / Sonnet / **Opus** |
| 5 | `[SEA]` | Silent Error Scan | Silent Error Team | QG | Sonnet |
| 5.1 | `[BF-SEA]` | Fix SEA findings | Bug Fix Team | SA | **Opus** / Sonnet / **Opus** |
| 6 | `[DS]` | Dependency Validation | Dependency Audit Team | QG | Sonnet |
| 6.1 | `[BF-DS]` | Fix DS findings | Bug Fix Team | SA | **Opus** / Sonnet / **Opus** |
| 7 | `[BSEA]` | Brutal Silent Error Scan (fresh eyes) | SEA Hardening Team | QG | **Opus** / **Opus** / **Opus** |
| 7.1 | `[BF-BSEA]` | Fix BSEA findings | Bug Fix Team | SA | **Opus** / Sonnet / **Opus** |
| 8 | `[OA]` | Output Alignment vs AC | Output Alignment Team | E | **Opus** / **Opus** / **Opus** |
| 9 | `[TEET-TC]` | E2E Test Case Design | TEET Test Design Team | E | **Opus** / Sonnet / **Opus** |
| 10 | `[TEET]` | True End-to-End Testing (Playwright MCP for UI) | E2E Team | SA | Sonnet / Sonnet / Sonnet |
| 10.1 | `[BF-TEET]` | Fix TEET findings | Bug Fix Team | SA | **Opus** / Sonnet / **Opus** |
| 11 | `[BTEET]` | Brutal E2E Hardening (fresh eyes) | E2E Hardening Team | QG | **Opus** / **Opus** / **Opus** |
| 12 | `[BTEET-X]` | Execute brutalized E2E tests | E2E Execution Team | SA | Sonnet / Sonnet / Sonnet |
| 12.1 | `[BF-BTEET]` | Fix BTEET findings | Bug Fix Team | SA | **Opus** / Sonnet / **Opus** |
| 13 | — | Version Bump (parallel with 14) | Standalone subagent | — | Haiku |
| 14 | — | Git Commit (specific files only) | Standalone subagent | — | Sonnet |
| 15 | `[CL]` | Cleanup | Cleanup Team | P | Sonnet |
| 16 | `[CCP]` | Save Checkpoint | Checkpoint Team | P | Sonnet |
| 17 | `[AD]` | Dashboard Update (`run_in_background`) | Dashboard Team | P | Haiku |

**Fresh-eyes rule — unchanged from v1:** every hardening phase (`[ACB]`, `[BSEA]`, `[BTEET]`) must be a separate dispatch from the team that did the first pass. Every `[BF-*]` runs only if its preceding scan found bugs, and every fix strategy is user-approved — never auto-resolved.

**Design Review rule (Phase 1.5):** `[DR]` is mandatory for any wave that ships UI (web, mobile, Storybook, CLI-TUI). It is a separate team from `[AC]` and `[ACB]` because its inputs (installed design-system dist files, compiled CSS, route topology) and its outputs (component API audit, per-route mockup, computed-style visual ACs, gaps as OPEN items) are categorically different from functional acceptance criteria. `[DR]` skipped silently on non-UI waves; `[TDE-RED]` does not begin while any DR OPEN item is unresolved.

## The 10 Invariant Rules (non-negotiable, verbatim from v1)

1. Lean context per unit — no "just in case" dumps.
2. Strict TDD — tests first, watch them fail, then implement.
3. Strict build order — build → app startup → tests.
4. Never assume on bugs — present **options**, user decides.
5. Save learnings globally after every bug fix (no duplicates, enhance existing).
6. Planning docs never committed to the code repo.
7. Auto-compact = STOP. Fresh terminal. Resume from checkpoint.
8. No team self-declares success — internal reviewer signs off first.
9. No hanging the system — teams must not deadlock or block indefinitely.
10. The orchestrator is the single throat to choke — all decisions and user interactions flow through it.

Invariants 6, 7 are now **hook-enforced** in v2; see [`references/11-hooks-and-automation.md`](references/11-hooks-and-automation.md).

## Reference index (load on demand)

| File | Load when |
|------|-----------|
| [`references/01-architecture.md`](references/01-architecture.md) | Starting a session; designing team composition |
| [`references/02-standing-teams.md`](references/02-standing-teams.md) | Instantiating Orchestrator, Permission, Dashboard, Checkpoint, Bug Ops, Cleanup |
| [`references/03-wave-pipeline.md`](references/03-wave-pipeline.md) | Executing any wave phase — full phase spec with team rosters and model assignments |
| [`references/04-meta-orchestration.md`](references/04-meta-orchestration.md) | Sequencing waves; acquiring session-wide permissions; toggling the CR gate |
| [`references/05-language-binding-rules.md`](references/05-language-binding-rules.md) | Any cross-language boundary work (N-API / FFI / WASM) |
| [`references/06-team-quick-reference.md`](references/06-team-quick-reference.md) | Spinning up a new team and needing membership / topology / model |
| [`references/07-invariant-rules.md`](references/07-invariant-rules.md) | Pressure to skip a step — re-read the invariants |
| [`references/08-worktree-strategy.md`](references/08-worktree-strategy.md) | Multi-wave project with 3+ waves; isolating writes |
| [`references/09-platform-deltas.md`](references/09-platform-deltas.md) | Confirming which Claude Code / Agent SDK primitives the framework assumes |
| [`references/10-model-routing.md`](references/10-model-routing.md) | Choosing Opus / Sonnet / Haiku for a dispatch; escalation rules |
| [`references/11-hooks-and-automation.md`](references/11-hooks-and-automation.md) | Wiring PreCompact / PostToolUse / PreToolUse / TaskCreated hooks into `settings.json` |
| [`references/12-mcp-and-plugins.md`](references/12-mcp-and-plugins.md) | Playwright for UI TEET; CodeRabbit as optional CR gate; ToolSearch scoping |
