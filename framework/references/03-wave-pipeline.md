# Part 3 — The Wave Execution Engine

Each wave follows a strict phased pipeline. ALL phases are SEQUENTIAL unless explicitly marked PARALLEL.

**v2 additions** (do not change the phase order): per-phase `model` routing on every `Agent` dispatch, `isolation: "worktree"` on all writing phases, `run_in_background: true` on Dashboard and long Playwright runs, an **optional** code-review gate `[CR]` at Phase 3.5 (enabled per-wave via the orchestrator's `cr_enabled` flag — see [`04-meta-orchestration.md`](04-meta-orchestration.md)), and a **conditional** Design Review gate `[DR]` at Phase 1.5 (mandatory whenever the wave ships UI — web, mobile, Storybook, or CLI-TUI — **or changes existing behaviour**; skipped only when it does neither).

**v0.3.0 additions** (five conditional rows, no change to the order of the rows that were already here): `[UIA]` at Phase 0.5 and `[ES]` at Phase 4.2 run when the wave introduces new vocabulary; `[BEN]` at Phase 0.8 runs when the wave changes existing behaviour; `[BF-ES]` at Phase 4.3 runs when `[ES]` reported findings; `[BEN-CLOSE]` at Phase 12.5 runs when `[BEN]` ran.
The table is 31 rows: 18 run in every full-mode wave, 7 are the `[BF-*]` rows that run only on findings, and 6 depend on the wave's scope answers or on whether `[BEN]` ran.
Because `[AC]` now names `[UIA]` and `[BEN]` as predecessors, a full-mode wave must answer `vocabulary` and `behaviour-change` before its first dispatch; `ui` and `cr` may still be answered any time before `[TDE-RED]`.
Demo mode is unchanged — the same five phases, the same gates.

## 3.1 Wave Pipeline

```
WAVE N START
│
├─ Phase 0.5:  [UIA]       User-Intent Criteria ─────────────────────── (E)
│  CONDITIONAL: runs ONLY when `vocabulary` is true — the wave introduces a new kind
│  of record, or a new value of an existing classification (a status, a category, a
│  role), that a user will see. No predecessors; this is the wave's first row.
│  Team: User-Intent Team — Lead (Opus) + Executor (Sonnet) + Reviewer (Opus)
│  Pattern: SDT-seq (Reviewer is a separate dispatch)
│    - Lead states, in the user's words, what the new vocabulary is for
│    - Executor writes one block per criterion in the user's voice, never the builder's:
│        "As a <role>, when I <action> against <data state>, I expect <observable outcome>."
│      Each criterion names one of the three pinned data states (empty / partial / full,
│      see Phase 1). A criterion naming a symbol the wave introduces is not a user-intent
│      criterion and is sent back.
│    - Reviewer confirms every criterion is in the user's voice and names a data state
│    GATE: `[AC]` receives `uia.md`, and every `UIA-n` must be covered by at least one
│    `AC-n`. `[OA]` maps both sets to evidence; either failing is a gap in the
│    alignment percentage.
│    Output: `.wave/uia.md`, one block per criterion, each heading matching `^UIA-[0-9]+`
│
├─ Phase 0.8:  [BEN]       Benefit Contract ─────────────────────────── (E)
│  CONDITIONAL: runs ONLY when `behaviour_change` is true. After `[UIA]`.
│  Team: Benefit Contract Team — Lead (Opus) + 2 Executors (Sonnet) + Reviewer (Opus)
│  Pattern: SDT-seq. Exists because a wave that verifies its module has not verified
│  its feature: the build can be correct and the outcome still not happen.
│    - Lead names the decision the feature influences
│    - Executor 1 writes the three artifacts of `.wave/ben.md`:
│        * The Benefit AC — exactly one sentence, whose grammatical subject is NOT the
│          new component and whose verb is what the user or the surrounding system does
│          differently once the feature exists. It may not name any symbol the wave
│          introduces; the reviewer checks that mechanically by searching the sentence
│          for the new identifiers.
│        * The authority census — every existing component that already decides the same
│          outcome, read from code: location, how it decides, its input, what happens
│          when it and the new feature disagree, and how that disagreement resolves. It
│          must include the authority that produces the outcome the Benefit AC names.
│        * The integration count, sign inverted — the number of files the wave expects to
│          change outside the feature's own directory. A count of 0 or 1 on a
│          behaviour-changing wave means the feature has been hosted, not integrated: a
│          finding that needs a written justification naming the existing mechanism that
│          will carry the behaviour. "Untouched" is not a score; every row of the
│          blast-radius table answers "must this change, and why not?".
│    - Executor 2 writes and runs the named test that backs the Benefit AC, and proves
│      it fails for the right reason
│    - Reviewer signs off that the Benefit AC names no new symbol, that the census
│      covers the Benefit AC's own authority, and that the red test is the right test
│    GATE: `[AC]`, `[ACB]` and `[DR]` receive `ben.md`. If the benefit can only be
│    observed end to end, `ben.md` says so and names the command; `[TEET]` runs it.
│    Output: `.wave/ben.md` with `BEN-VERIFIED red=<n> authorities=<n>`, both ≥ 1
│
├─ Phase 1:    [AC]        Acceptance Criteria ─────────────────────── (E)
│  Team: AC Team — Lead (Opus) + 2 Executors (Sonnet) + Reviewer (Opus)
│  Pattern: SDT-seq (Lead briefs Executors; Reviewer is a separate dispatch)
│  Inputs: `.wave/uia.md` and `.wave/ben.md` when those phases ran
│    - Executor 1: Writes functional acceptance criteria against the plan
│    - Executor 2: Writes non-functional criteria (perf, security, edge cases)
│    - Reviewer: Challenges every criterion — "is this testable? is this complete?"
│    DATA-STATE MATRIX: every criterion that asserts on a user-visible surface carries a
│    `**Data states:**` line and must hold in all three pinned states —
│      * empty:   no records at all
│      * partial: only records that existed before the wave, none of the new kind.
│                 This is what every installation looks like on the day of the deploy.
│      * full:    records in every value the wave introduces
│
├─ Phase 1.2:  [ACB]       Brutal AC Review ────────────────────────── (E)
│  Team: AC Hardening Team (SEPARATE from AC Team — fresh eyes)
│  Models: Lead (Opus) + Adversarial Writer (Opus) + Reviewer (Opus)
│  Pattern: SDT-seq — Reviewer sees only the hardened AC, not the adversarial reasoning
│    - Lead identifies gaps, missing edge cases, implicit assumptions
│    - Adversarial Writer adds: what if null? concurrent? 2GB? timeout? partial failure?
│    - Adversarial Writer hunts absent-data gaps explicitly: for every user-visible
│      surface in scope, what does the partial state and the empty state look like?
│    - Reviewer confirms AC set is now "brutal" — no happy-path-only criteria survive
│    REJECT: a criterion conditional on data being present ("when a hold exists, …") is
│    rejected unless the same criterion also states the absent-data outcome.
│
├─ Phase 1.5:  [DR]        Design Review (UI or behaviour-changing waves) ─ (E)
│  CONDITIONAL GATE: runs when the wave ships UI (web, mobile, Storybook, CLI-TUI)
│  OR changes existing behaviour. Skipped silently only when it does neither.
│  On a behaviour-changing wave with no UI, the review is of the changed behaviour's
│  surface and topology rather than its pixels.
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
├─ Phase 4.2:  [ES]        Empty-State Scan ────────────────────────── (QG)
│  │  CONDITIONAL: runs ONLY when `vocabulary` is true. After `[BF-BC]`.
│  │  Team: Empty-State Team — Scanner (Sonnet) only; no lead, no reviewer, like `[SEA]`
│  │    - Reads the data-state matrix in `.wave/ac.md`
│  │    - For each user-visible surface in scope, simulates the partial state (no records
│  │      of the new kind) and the empty state (no records at all)
│  │    - Reports any element whose visibility, presence or rendering depends on a count
│  │      being non-zero, with file and line, unless a criterion explicitly accepts
│  │      hiding it
│  │  Output: `.wave/findings/ES.md`, first matching line `FINDINGS: <n>`
│  │
├─ Phase 4.3:  [BF-ES]    Bug Fix for ES findings ─────────────────── (SA)
│  │  Team: Bug Fix Team (standing). Runs only when `[ES]` reported `n >= 1`.
│  │  GATE: user approval per fix, recorded in `.wave/approvals/bf-ES.md`.
│  │  When `[ES]` does not run at all there is nothing for `[BF-ES]` to fix and it is
│  │  skipped too; `[SEA]` follows `[BF-ES]` and is reached either way.
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
├─ Phase 12.5: [BEN-CLOSE] Benefit Verdict ──────────────────────────── (E)
│  CONDITIONAL: runs when `[BEN]` ran. After `[BTEET-X]` and `[BF-BTEET]`, before the
│  version bump and the commit.
│  Team: Benefit Verdict Team (SEPARATE from the Benefit Contract Team — fresh eyes)
│  Models: Lead (Opus) + Executor (Sonnet) + Reviewer (Opus)
│  Pattern: SDT-seq
│    - Executor runs the named benefit test and records the command, the exit status and
│      the tail of the output. Where that test is part of the unit run it has been green
│      since `[TDE-GREEN]` and this is a regression check; where it is end to end, this
│      is its decisive run.
│    - Executor runs the ORPHAN-STATE SWEEP: for every new class, table, flag or state
│      the wave introduced, searches for production readers outside the feature's own
│      directory. Zero external readers means the rest of the system cannot see it —
│      name the reader that should exist, or justify its absence.
│    - Executor writes the DEFEAT LIST: any statement in the wave's own new comments and
│      documents saying the existing system undoes, ignores or overrides the feature.
│      Each is a requirement unless a named test guards it.
│    - Reviewer signs off the verdict line
│    VERDICT: `BENEFIT: DELIVERED` only if the benefit test passed AND neither list holds
│    an unjustified item; otherwise `BENEFIT: UNDELIVERED`, followed by the reasons.
│    Both verdicts satisfy the marker, so an undelivered wave still commits and closes —
│    a hard block here would only invite weakening the Benefit AC to get out. What is
│    guaranteed is that the verdict cannot be silent: it is recorded in wave state, the
│    scorecard prints it, and `W-UNDELIVERED` announces it at the close.
│    Output: `.wave/ben-close.md` with `BENEFIT: DELIVERED` or `BENEFIT: UNDELIVERED`
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
WAVE N COMPLETE (every `when=phase` row of the mode settled — done, or skipped by mode or a false
           condition; `[AD]` is `anytime` and never counts — closed by the closing stop that completes it)
           → Orchestrator evaluates → WAVE N+1 or DONE
```

## 3.2 Execution Rules

**Teams CAN run in parallel when:**

- They are all READ-ONLY on the codebase (the pipeline uses PDT for Bug Capture scanners, TEET-TC writers, TEET/BTEET-X executors; Phase 13+14 also parallelize).
- They have no data dependencies on each other's output.
- They are explicitly marked as PARALLEL / PDT in the pipeline above.

**Teams MUST run sequentially when:**

- One team's output is another team's input (UIA → BEN → AC → TDE-RED → TDE-GREEN).
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
| `[UIA]` | Read, Grep |
| `[BEN]` | Read, Grep, Edit, Write, Bash (the benefit test is written and run here) |
| `[AC]`, `[ACB]`, `[OA]` | Read, Grep, WebFetch (for spec lookups) |
| `[DR]` (UI or behaviour-changing waves) | Read (esp. `node_modules/<ds>/dist/`, compiled CSS), Grep, Bash (CSS inspection), WebFetch (DS docs) |
| `[TDE-RED]`, `[TDE-GREEN]` | Edit, Write, Bash, Read, Grep |
| `[CR]` (optional) | CodeRabbit MCP tools only |
| `[BC]`, `[SEA]`, `[BSEA]`, `[DS]`, `[ES]` | Read, Grep, Bash (static + runtime scanners); DS also gets WebFetch for CVE lookups |
| `[BEN-CLOSE]` | Read, Grep, Bash (runs the benefit test and the orphan-state sweep) |
| `[TEET-TC]` | Read, Grep, WebFetch |
| `[TEET]`, `[BTEET-X]` | Bash, Playwright MCP (when UI in scope), Monitor |
| Version Bump / Git Commit | Bash only |
| `[CL]`, `[CCP]`, `[AD]` | Bash, Write |

Each Agent dispatch expresses its tool needs via a `ToolSearch` select in its prompt, so tools not relevant to the phase remain deferred and do not pollute context (Invariant 1).
