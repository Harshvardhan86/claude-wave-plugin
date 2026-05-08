# Part 3 — The Wave Execution Engine

Each wave follows a strict phased pipeline. ALL phases are SEQUENTIAL unless explicitly marked PARALLEL.

**v2 additions** (do not change the phase order): per-phase `model` routing on every `Agent` dispatch, `isolation: "worktree"` on all writing phases, `run_in_background: true` on Dashboard and long Playwright runs, an **optional** code-review gate `[CR]` at Phase 3.5 (enabled per-wave via the orchestrator's `cr_enabled` flag — see [`04-meta-orchestration.md`](04-meta-orchestration.md)), and a **conditional** Design Review gate `[DR]` at Phase 1.5 (mandatory whenever the wave ships UI — web, mobile, Storybook, or CLI-TUI; skipped on pure backend / library / CLI waves).

## 3.1 Wave Pipeline

```
WAVE N START
│
├─ Phase 1:    [AC]        Acceptance Criteria ─────────────────────── (E)
│  Team: AC Team — Lead (Opus) + 2 Executors (Sonnet) + Reviewer (Opus)
│  Pattern: SDT-seq (Lead briefs Executors; Reviewer is a separate dispatch)
│    - Executor 1: Writes functional acceptance criteria against the plan
│    - Executor 2: Writes non-functional criteria (perf, security, edge cases)
│    - Reviewer: Challenges every criterion — "is this testable? is this complete?"
│
├─ Phase 1.2:  [ACB]       Brutal AC Review ────────────────────────── (E)
│  Team: AC Hardening Team (SEPARATE from AC Team — fresh eyes)
│  Models: Lead (Opus) + Adversarial Writer (Opus) + Reviewer (Opus)
│  Pattern: SDT-seq — Reviewer sees only the hardened AC, not the adversarial reasoning
│    - Lead identifies gaps, missing edge cases, implicit assumptions
│    - Adversarial Writer adds: what if null? concurrent? 2GB? timeout? partial failure?
│    - Reviewer confirms AC set is now "brutal" — no happy-path-only criteria survive
│
├─ Phase 1.5:  [DR]        Design Review (UI waves only) ────────────── (E)
│  CONDITIONAL GATE: runs ONLY when the wave ships UI (web, mobile, Storybook, CLI-TUI).
│  Skipped silently for pure backend / library / CLI waves.
│  Team: Design Review Team (SEPARATE from AC and ACB — different inputs, different outputs)
│  Models: Lead (Opus) + Component API Auditor (Sonnet) + Mockup Writer (Sonnet) + Reviewer (Opus)
│  Pattern: SDT-seq — Reviewer sees only the produced artifacts, not the audit reasoning
│    - Lead scopes which design-system components, routes, and visual states the wave touches
│    - Component API Auditor reads installed dist files (`node_modules/<ds>/dist/...`) directly
│      and extracts: attribute names, slot names, events, shadow-DOM constraints, default styles.
│      NEVER assumes API based on docs or training data. NEVER trusts theoretical class names —
│      audits the project's COMPILED CSS (e.g. `dist/`, `.next/static/css/`, live `<style>`).
│    - Mockup Writer produces:
│        * per-route markdown mockup (which component goes where, which attribute, which slot)
│        * concrete computed-style visual ACs (getComputedStyle background, fontFamily,
│          boundingBox dimensions; effective CSS bytes threshold)
│        * design-system gaps flagged as OPEN items with proposed fallbacks
│    - Reviewer (Opus) confirms:
│        * every component API claim is grounded in a dist-file read
│        * every visual AC uses computed-style or boundingBox (no toBeVisible-only)
│        * no token / color invented that the app doesn't already render
│        * every OPEN item carries a user-facing decision request
│    GATE: [TDE-RED] does NOT begin while any DR OPEN item is unresolved by the user.
│    Output: `.wave/dr.md` (component API audit, mockup, visual ACs, OPEN items)
│
├─ Phase 2:    [TDE-RED]   Write Tests, Verify FAIL ────────────────── (SA)
│  Team: TDD-RED Team — Lead (Sonnet) + Test Writer (Sonnet) + Verifier (Sonnet)
│  Pattern: SDT-seq. Cross-language waves escalate Reviewer to Opus — see 05-language-binding-rules.md
│    - Test Writer writes ALL tests derived from AC (unit, integration, contract)
│    - Verifier runs every test, confirms ALL fail (RED state)
│    - Lead reports RED state with test count and coverage map
│    WARNING: AC is the guiding principle — every AC maps to at least 1 test
│
├─ Phase 3:    [TDE-GREEN] Implement, Verify PASS ──────────────────── (SA)
│  Team: TDD-GREEN Team — Lead (Sonnet) + Implementer (Sonnet) + Reviewer (Opus)
│  Pattern: SDT-seq, isolation: "worktree" on the Implementer dispatch
│    - Implementer writes minimum code to make tests pass
│    - Verifier runs ALL tests, confirms ALL pass (GREEN state)
│    - Reviewer (Opus) signs off that the implementation is minimal and complete
│    WARNING: Strict sequential: build → app startup → tests (NO shortcuts)
│
├─ Phase 3.5:  [CR]        Code Review Gate — OPTIONAL ─────────────── (QG)
│  Active only when orchestrator's `cr_enabled` flag is true.
│  Team: CodeRabbit Plugin (managed by the CodeRabbit MCP)
│  Pattern: single plugin invocation; findings fed into Bug Fix Team loop
│  If cr_enabled is false, pipeline jumps straight to Phase 4.
│
│  ┌─ SEQUENTIAL QUALITY GATE PIPELINE ─────────────────────────────────┐
│  │ Each gate scans, then findings are fixed before the next gate.     │
│  │ BF sub-phases run ONLY if bugs are found. User approves each fix.  │
│  │                                                                    │
├─ Phase 4:    [BC]        Bug Capture ─────────────────────────────── (QG)
│  │  Team: Bug Capture Team (standing team — see 02-standing-teams.md §2.5)
│  │  Models: PDT scanners on Sonnet; Reviewer on Opus
│  │
├─ Phase 4.1:  [BF-BC]    Bug Fix for BC findings ─────────────────── (SA)
│  │  Team: Bug Fix Team (standing team — see 02-standing-teams.md §2.5)
│  │  Models: Lead (Opus) → user decision → Executor (Sonnet, isolation: worktree) → Reviewer (Opus)
│  │  GATE: Requires user approval for each fix strategy
│  │
├─ Phase 5:    [SEA]       Silent Error Scan ───────────────────────── (QG)
│  │  Team: Silent Error Team — Lead + Scanner + Reviewer, all Sonnet, Pattern: SDT
│  │    - Scanner checks: swallowed exceptions, empty catches, unchecked return values,
│  │      fire-and-forget promises, ignored error callbacks
│  │    - Reviewer validates each finding is a real risk
│  │
├─ Phase 5.1:  [BF-SEA]   Bug Fix for SEA findings ────────────────── (SA)
│  │  Team: Bug Fix Team (standing). GATE: user approval per fix.
│  │
├─ Phase 6:    [DS]        Dependency Validation ───────────────────── (QG)
│  │  Team: Dependency Audit Team — Lead + Auditor + Reviewer, all Sonnet, Pattern: SDT
│  │    - Auditor checks: versions, CVEs, license compatibility, lockfile integrity,
│  │      dependabot standards
│  │    - Reviewer confirms no vulnerable/outdated deps ship
│  │
├─ Phase 6.1:  [BF-DS]    Bug Fix for DS findings ─────────────────── (SA)
│  │  Team: Bug Fix Team (standing). GATE: user approval per fix.
│  │
├─ Phase 7:    [BSEA]      Brutal Silent Error Scan ────────────────── (QG)
│  │  Team: SEA Hardening Team (SEPARATE from SEA team — fresh eyes)
│  │  Models: Lead (Opus) + Adversarial Scanner (Opus) + Reviewer (Opus)
│  │  Pattern: SDT-seq — the hardening scanner dispatch never sees SEA's output
│  │    - Adversarial scanner injects fault scenarios mentally, traces error paths
│  │    - Checks: What if DB is down? API returns 500? Disk full? Network partition?
│  │    - Reviewer confirms no silent failure path remains
│  │
├─ Phase 7.1:  [BF-BSEA]  Bug Fix for BSEA findings ──────────────── (SA)
│  │  Team: Bug Fix Team (standing). GATE: user approval per fix.
│  └────────────────────────────────────────────────────────────────────┘
│
├─ Phase 8:    [OA]        Output Alignment Check ──────────────────── (E)
│  Team: Output Alignment Team — Lead (Opus) + Comparator (Opus) + Reviewer (Opus)
│  Pattern: SDT-seq
│    - Comparator diffs actual output against every AC line item
│    - Reviewer flags any AC not demonstrably met
│    - Lead reports alignment percentage and gaps
│
│  ┌─ E2E TESTING PIPELINE ─────────────────────────────────────────────┐
│  │                                                                    │
├─ Phase 9:    [TEET-TC]   E2E Test Case Design ────────────────────── (E)
│  │  Team: TEET Test Design Team — Lead (Opus) + 3 Writers (Sonnet) + Reviewer (Opus)
│  │  Pattern: PDT for writers, then Reviewer dispatch
│  │    - Lead derives E2E scenarios from AC + implementation
│  │    - Writer 1 (Sonnet): Backend/API test cases (contracts, DB state, service interactions)
│  │    - Writer 2 (Sonnet): Frontend/UI test cases (flows, screenshots, browser scenarios)
│  │      → If Storybook exists: include Storybook E2E scenarios
│  │      → If browser app: include Playwright E2E scenarios (Playwright MCP, see 12-mcp-and-plugins.md)
│  │    - Writer 3 (Sonnet): Integration test cases (cross-service, message queues, event chains)
│  │    - Reviewer (Opus) validates coverage against AC — no untested AC item survives
│  │
├─ Phase 10:   [TEET]      True End-to-End Testing ─────────────────── (SA)
│  │  Team: E2E Team — Lead + Backend Tester + Frontend Tester + Integration Tester, all Sonnet
│  │  Pattern: PDT for testers; long screenshot/recording runs use run_in_background + Monitor
│  │    - Executes test cases designed in [TEET-TC]
│  │    - Backend Tester: API contracts, DB state, service interactions
│  │    - Frontend Tester: UI flows with Playwright screenshots if UI involved
│  │    - Integration Tester: Cross-service flows, message queues, event chains
│  │    - Lead reports E2E pass/fail with evidence
│  │
├─ Phase 10.1: [BF-TEET]   Bug Fix for TEET findings ──────────────── (SA)
│  │  Team: Bug Fix Team (standing). GATE: user approval per fix.
│  │
├─ Phase 11:   [BTEET]     Brutal E2E Test Hardening ───────────────── (QG)
│  │  Team: E2E Hardening Team (SEPARATE from TEET — fresh eyes)
│  │  Models: Lead (Opus) + Adversarial Executor (Opus) + Reviewer (Opus)
│  │  Pattern: SDT-seq
│  │    - Lead identifies gaps in E2E coverage from [TEET-TC]
│  │    - Adversarial Executor adds brutal test cases:
│  │      What if 10K concurrent users? DB drops mid-transaction? Network partitions during
│  │      E2E flow? Race conditions? Data corruption? Partial failures mid-sequence?
│  │    - Reviewer confirms no happy-path-only E2E tests survive
│  │
├─ Phase 12:   [BTEET-X]   Execute Brutalized E2E Tests ────────────── (SA)
│  │  Team: E2E Execution Team — Lead + Backend Executor + Frontend Executor + Reviewer, all Sonnet
│  │  Pattern: PDT for executors; long runs use run_in_background + Monitor
│  │    - Runs the hardened test suite from [BTEET]
│  │    - Frontend with Playwright screenshots. All evidence collected.
│  │    - Reviewer validates all brutal tests executed with evidence
│  │
├─ Phase 12.1: [BF-BTEET]  Bug Fix for BTEET findings ─────────────── (SA)
│  │  Team: Bug Fix Team (standing). GATE: user approval per fix.
│  └────────────────────────────────────────────────────────────────────┘
│
│  ┌─ PARALLEL FINALIZATION ────────────────────────────────────────────┐
├─ Phase 13:   Version Bump ─────────────────── (Standalone, model: Haiku) │
├─ Phase 14:   Git Commit (specific files only, model: Sonnet) ────────── │
│                 PreToolUse hook blocks any planning-docs path in the commit
│  └────────────────────────────────────────────────────────────────────┘
│
├─ Phase 15:   [CL]        Cleanup ─────────────────────────────────── (P)
│  Team: Cleanup Team (standing team — see 02-standing-teams.md §2.6), model: Sonnet
│
├─ Phase 16:   [CCP]       Save Checkpoint ─────────────────────────── (P)
│  Team: Checkpoint Team (standing team — see 02-standing-teams.md §2.4), model: Sonnet
│
├─ Phase 17:   [AD]        Dashboard Update ────────────────────────── (P)
│  Team: Dashboard Team (standing team — see 02-standing-teams.md §2.3), model: Haiku, run_in_background
│
WAVE N COMPLETE → Orchestrator evaluates → WAVE N+1 or DONE
```

## 3.2 Execution Rules

**Teams CAN run in parallel when:**

- They are all READ-ONLY on the codebase (the pipeline uses PDT for Bug Capture scanners, TEET-TC writers, TEET/BTEET-X executors; Phase 13+14 also parallelize).
- They have no data dependencies on each other's output.
- They are explicitly marked as PARALLEL / PDT in the pipeline above.

**Teams MUST run sequentially when:**

- One team's output is another team's input (AC → TDE-RED → TDE-GREEN).
- A team writes code (only ONE writing team active at a time; `isolation: "worktree"` per dispatch enforces it at the repo level).
- A phase is a gate that blocks downstream (each QG blocks until its BF completes).

## 3.3 Team Communication Protocol

1. Teams communicate ONLY through their leads.
2. Team leads communicate ONLY with the orchestrator.
3. Cross-team data passes through the orchestrator's shared state (never direct).
4. If Team B needs Team A's output, the orchestrator passes it — teams never reach into each other's context.
5. User decisions are ALWAYS routed through the orchestrator — no team contacts the user directly.

## 3.4 Per-Phase Tool Scoping (v2)

Every dispatch receives only the deferred tools it needs, via `ToolSearch`:

| Phase | Tools loaded |
|-------|--------------|
| `[AC]`, `[ACB]`, `[OA]` | Read, Grep, WebFetch (for spec lookups) |
| `[DR]` (UI waves only) | Read (esp. `node_modules/<ds>/dist/`, compiled CSS), Grep, Bash (CSS inspection), WebFetch (DS docs) |
| `[TDE-RED]`, `[TDE-GREEN]` | Edit, Write, Bash, Read, Grep |
| `[CR]` (optional) | CodeRabbit MCP tools only |
| `[BC]`, `[SEA]`, `[BSEA]`, `[DS]` | Read, Grep, Bash (static + runtime scanners); DS also gets WebFetch for CVE lookups |
| `[TEET-TC]` | Read, Grep, WebFetch |
| `[TEET]`, `[BTEET-X]` | Bash, Playwright MCP (when UI in scope), Monitor |
| Version Bump / Git Commit | Bash only |
| `[CL]`, `[CCP]`, `[AD]` | Bash, Write |

Each Agent dispatch expresses its tool needs via a `ToolSearch` select in its prompt, so tools not relevant to the phase remain deferred and do not pollute context (Invariant 1).
