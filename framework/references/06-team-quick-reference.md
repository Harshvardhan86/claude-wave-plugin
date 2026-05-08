# Part 6 — Team Instantiation Quick Reference

Every team names its **dispatch pattern** (SDT / SDT-seq / PDT from [`01-architecture.md`](01-architecture.md) §1.4), its **model(s)**, and any special `Agent` tool flags.

## Standing Teams (persist entire session)

| Team | Topology | Members | Pattern | Models | Agent flags | Activated |
|------|----------|---------|---------|--------|-------------|-----------|
| Orchestrator | — | 1 (singleton) | main session | Opus 4.7 (1M ctx) | `effort: xhigh` | Session start |
| Permission Team | P | 3 (Lead + Executor + Reviewer) | SDT | Sonnet | — | Session start, ONCE |
| Dashboard Team | P | 3 (Lead + Executor + Reviewer) | SDT | Haiku | `run_in_background: true` | Continuous background |
| Checkpoint Team | P | 3 (Lead + Executor + Reviewer) | SDT | Sonnet | — | Each wave end + `PreCompact` hook |
| Bug Capture Team | QG | 4 (Lead + 2 Scanners + Reviewer) | PDT (scanners) → SDT (Reviewer) | Scanners: Sonnet · Reviewer: Opus | — | Quality gate phases |
| Bug Fix Team | SA | 4 (Lead + Executor + Reviewer + Learner) | SDT-seq | Lead: Opus · Executor: Sonnet · Reviewer: Opus · Learner: Sonnet | Executor: `isolation: "worktree"` | On-demand when bugs found |
| Cleanup Team | P | 3 (Lead + Executor + Reviewer) | SDT | Sonnet | — | Between every wave |

## Per-Wave Teams (instantiated fresh each wave, lean context)

| Team | Topology | Members | Pattern | Models | Agent flags | Phase |
|------|----------|---------|---------|--------|-------------|-------|
| AC Team | E | 4 (Lead + 2 Writers + Reviewer) | SDT-seq | Lead: Opus · Writers: Sonnet · Reviewer: Opus | — | 1 `[AC]` |
| AC Hardening Team | E | 3 (Lead + Adversarial Writer + Reviewer) | SDT-seq (fresh eyes) | All Opus | — | 1.2 `[ACB]` |
| Design Review Team | E | 4 (Lead + Component API Auditor + Mockup Writer + Reviewer) | SDT-seq | Lead: Opus · Auditor: Sonnet · Writer: Sonnet · Reviewer: Opus | — | 1.5 `[DR]` (UI waves only — skipped on backend/library/CLI) |
| TDD-RED Team | SA | 3 (Lead + Test Writer + Verifier) | SDT-seq | All Sonnet (Reviewer → Opus for cross-language) | Test Writer: `isolation: "worktree"` when tests live with code | 2 `[TDE-RED]` |
| TDD-GREEN Team | SA | 3 (Lead + Implementer + Verifier) → Reviewer | SDT-seq | Lead / Implementer / Verifier: Sonnet · Reviewer: Opus | Implementer: `isolation: "worktree"` | 3 `[TDE-GREEN]` |
| CodeRabbit plugin | QG | 1 (plugin) | single plugin call | plugin-managed | — | 3.5 `[CR]` (opt-in) |
| Silent Error Team | QG | 3 (Lead + Scanner + Reviewer) | SDT | All Sonnet | — | 5 `[SEA]` |
| Dependency Audit Team | QG | 3 (Lead + Auditor + Reviewer) | SDT | All Sonnet | — | 6 `[DS]` |
| SEA Hardening Team | QG | 3 (Lead + Adversarial Scanner + Reviewer) | SDT-seq (fresh eyes) | All Opus | — | 7 `[BSEA]` |
| Output Alignment Team | E | 3 (Lead + Comparator + Reviewer) | SDT-seq | All Opus | — | 8 `[OA]` |
| TEET Test Design Team | E | 5 (Lead + 3 Writers + Reviewer) | PDT (writers) → SDT (Reviewer) | Lead: Opus · Writers: Sonnet · Reviewer: Opus | — | 9 `[TEET-TC]` |
| E2E Team | SA | 4 (Lead + Backend + Frontend + Integration) | PDT | All Sonnet | Frontend: Playwright MCP, `run_in_background: true` for long runs | 10 `[TEET]` |
| E2E Hardening Team | QG | 3 (Lead + Adversarial Executor + Reviewer) | SDT-seq (fresh eyes) | All Opus | — | 11 `[BTEET]` |
| E2E Execution Team | SA | 4 (Lead + Backend + Frontend + Reviewer) | PDT | All Sonnet | Playwright MCP, `run_in_background: true` | 12 `[BTEET-X]` |

## Standalone Subagents (no team needed — atomic tasks)

| Subagent | Model | Phase |
|----------|-------|-------|
| Version Bump | Haiku | 13 |
| Git Commit | Sonnet | 14 — PreToolUse hook blocks planning-doc paths |
