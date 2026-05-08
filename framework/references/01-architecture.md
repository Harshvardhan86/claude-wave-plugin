# Part 1 — Foundational Architecture

## 1.1 Organizational Hierarchy

| Level | Role | Responsibility | Realization in Claude Code (v2) |
|-------|------|----------------|----------------------------------|
| **L1** | Subagent | Atomic executor with ONE specific superpower. | A single `Agent` tool dispatch with an explicit `model`, optional `isolation: "worktree"`, optional `run_in_background: true`. |
| **L2** | Agent Team | 2–5 subagents with a Team Lead who owns the outcome. Lead decomposes, delegates, reviews, reports unified result upstream. | **Prompt-scoped, not spawned.** Either one dispatch whose prompt carries Lead + Executor + Reviewer personas, **or** a sequence of dispatches the orchestrator fires (with only the prior output in context for fresh-eyes review). See §1.4. |
| **L3** | Orchestrator | Singleton meta-coordinator. Sequences waves, routes decisions, manages global state. There is only ONE orchestrator per session. NEVER executes code or tests — only coordinates. | The main Claude Code session itself, running on **Opus 4.7 (1M context)**. Every `Agent` dispatch is its L1 action. |

**Key distinction:**

- Subagent **executes** a task.
- Agent team **owns** an outcome.
- Orchestrator **owns** the mission.

**v2 platform note — no nested subagents.** Claude Code blocks L4 spawns from within a subagent. A "Team Lead" therefore cannot spawn its Executors from inside an Agent dispatch. The orchestrator is the only spawner. See §1.4 and [`09-platform-deltas.md`](09-platform-deltas.md).

## 1.2 Agent Team Topologies

| Topology | Purpose | Examples |
|----------|---------|----------|
| **Stream-Aligned (SA)** | Delivers vertical slice end-to-end | TDD Team, Bug Fix Team |
| **Quality Gate (QG)** | Validates and blocks if standards unmet | Bug Scan, SEA, DS |
| **Platform (P)** | Shared services for other teams | Dashboard, Checkpoint, Cleanup |
| **Enabling (E)** | On-demand specialized expertise | AC Team, OA Team |

## 1.3 Team Composition (MANDATORY for every team)

- **Team Lead** → Owns outcome, decomposes, delegates, aggregates, reports. NEVER executes directly.
- **Executor(s)** → 1–3 subagents that do the actual work. Each has a specific superpower.
- **Reviewer** → Validates executor output against acceptance criteria BEFORE reporting up.

**Rule:** No team reports "done" without the reviewer signing off. This catches 80% of issues before they cross team boundaries.

## 1.4 Dispatch Patterns (v2-specific)

Every team in v2 is realized as one of three patterns. [`03-wave-pipeline.md`](03-wave-pipeline.md) specifies which pattern each phase uses.

### A. Single-Dispatch Team (SDT)

One `Agent` call. The prompt frames the dispatch as a Lead + Executor + Reviewer sequence inside that one context. Used when review bias from shared context is acceptable — typically **read-only scan phases** (`[BC]`, `[SEA]`, `[DS]`), Cleanup, Checkpoint, Permission acquisition.

### B. Sequential-Dispatch Team (SDT-seq)

The orchestrator fires 2–3 dispatches in order:

1. **Executor Agent** → produces the artifact (code, tests, criteria, fix).
2. **Reviewer Agent** → receives ONLY the Executor's output (not its internal reasoning) and reviews against acceptance criteria.
3. (Optional) **Learning Recorder Agent** → saves learnings globally (Bug Fix Team only).

This is the **fresh-eyes pattern** — required for every hardening phase (`[ACB]`, `[BSEA]`, `[BTEET]`), every `[TDE-GREEN]` reviewer pass, and every Bug Fix.

### C. Parallel-Dispatch Team (PDT)

Multiple independent, **read-only** dispatches fire in one message (multiple Agent tool calls in a single turn). Used for:

- Bug Capture Team's Scanner-Static + Scanner-Runtime running concurrently.
- TEET Test Design Team's Backend + Frontend + Integration writers running concurrently.
- TEET execution fanout where backend and frontend tests don't share state.

The orchestrator aggregates their outputs for the Reviewer's single review pass.

## 1.5 Why each pattern is safe

- **SDT** is safe when the phase is read-only and the Reviewer's job is "is this scan complete?" — a question where shared context doesn't bias the answer.
- **SDT-seq** is required whenever the Reviewer's job is "is this *good enough*?" — that judgement must not see the Executor's reasoning, or the review collapses into "yes, it did what it planned."
- **PDT** is safe only when each executor's context is mutually independent. The moment two executors would overwrite the same file, they must serialize through SDT-seq instead.

## 1.6 Communication (unchanged from v1)

- Teams communicate ONLY through their leads.
- Team leads communicate ONLY with the orchestrator.
- Cross-team data passes through the orchestrator's shared state (never direct).
- User decisions are ALWAYS routed through the orchestrator — no team contacts the user directly.
