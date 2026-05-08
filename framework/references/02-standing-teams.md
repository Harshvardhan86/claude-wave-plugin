# Part 2 — The Standing Teams

These teams persist across ALL waves. Instantiated once at session start and remain active throughout.

**Model-routing column** (v2): each standing team names the `model` the orchestrator passes on the `Agent` dispatch. See [`10-model-routing.md`](10-model-routing.md) for the reasoning behind each assignment.

| Standing team | Topology | Pattern (see `01-architecture.md` §1.4) | Model(s) |
|---------------|----------|-----------------------------------------|----------|
| Orchestrator | — | Main session (singleton) | **Opus 4.7 (1M context)** |
| Permission Team | P | SDT | Sonnet |
| Dashboard Team | P | SDT, `run_in_background: true` | Haiku |
| Checkpoint Team | P | SDT | Sonnet |
| Bug Capture Team | QG | PDT (static + runtime scanners) then Reviewer | Sonnet / Sonnet / **Opus** |
| Bug Fix Team | SA | SDT-seq (Lead → user decision → Executor → Reviewer → Learner) | **Opus** / Sonnet / **Opus** / Sonnet |
| Cleanup Team | P | SDT | Sonnet |

## 2.1 Orchestrator (L3 — Singleton)

**Model:** Opus 4.7 with 1M context window. `effort: xhigh` for deep reasoning.

**Superpower:** Wave sequencing, conflict resolution, user decision routing.

**Responsibilities:**

1. Sequences waves and determines parallelism opportunities.
2. Routes ALL user-facing decisions (bug fix strategy, ambiguous requirements).
3. Maintains the global execution plan via `TaskCreate` (v2 replaces the v1 `tasks/todo.md`).
4. Detects cross-team conflicts before they happen.
5. Calls STOP after auto-compact events — fresh terminal required (also enforced by the `PreCompact` hook, see [`11-hooks-and-automation.md`](11-hooks-and-automation.md)).
6. Ensures analysis/planning docs are SEPARATE from code repo (also enforced by the `PreToolUse` commit-guard hook).

## 2.2 Permission Acquisition Team (P) — SDT, model: Sonnet

**Superpower:** ONE TIME, upfront, never again.

- Lead identifies ALL permissions needed across ALL waves upfront.
- Executor acquires file, network, DB, API permissions in a single batch.
- Reviewer verifies every permission is active and functional.

**Rule:** Runs ONCE at session start. Missing permission later = BUG (permission team failed its AC).

## 2.3 Dashboard Team (P) — SDT (`run_in_background: true`), model: Haiku

**Superpower:** Continuous background ASCII dashboard updates.

- Lead defines dashboard schema: waves, teams, status, blockers.
- Executor renders and updates after EVERY phase completion (triggered by the `PostToolUse` hook on writing tools).
- Reviewer ensures dashboard accurately reflects reality (no stale states).
- Runs as background service — never blocks the pipeline. `Monitor` streams status events.
- Rendered to terminal as ASCII art (not saved to file).

**Why Haiku:** the output is strictly mechanical ASCII redraw; quality failure mode is "display is stale," not "decision is wrong."

**Dashboard format:**

```
+===========================================================+
|  WAVE 2 / 5  ............##### 40%                        |
+===========================================================+
| Team              Status    Blocker          Duration      |
| AC Team           DONE      -                2m 14s        |
| TDD-RED Team      ACTIVE    -                1m 03s...     |
| Bug Scan Team     QUEUED    depends:GREEN    -             |
+===========================================================+
| Bugs: 0 captured | 0 fixed | 0 pending user decision      |
| Learnings: 3 saved this session                            |
| Checkpoint: wave-1-complete (3m ago)                       |
+===========================================================+
```

## 2.4 Checkpoint Team (P) — SDT, model: Sonnet

**Superpower:** Context preservation across auto-compact events.

- Lead determines what state must survive a compact.
- Executor saves checkpoint with schema below.
- Reviewer verifies checkpoint can reconstruct execution state from scratch.

**Triggers:** end of every wave, before any risky operation, immediately on auto-compact detection. In v2 the `PreCompact` hook forces a Checkpoint dispatch before any compaction proceeds — see [`11-hooks-and-automation.md`](11-hooks-and-automation.md).

After auto-compact → STOP. Fresh terminal required. Load checkpoint. Resume precisely.

**Checkpoint schema:**

```json
{
  "session_id": "...",
  "timestamp": "...",
  "completed_waves": [],
  "current_wave": "...",
  "current_phase": "...",
  "pending_user_decisions": [],
  "bugs_found": [],
  "bugs_fixed": [],
  "learnings_saved": [],
  "permissions_acquired": [],
  "files_modified": [],
  "test_state": { "total": 0, "passing": 0, "failing": 0 },
  "worktrees": [{ "name": "...", "branch": "...", "path": "...", "status": "..." }],
  "model_assignments": { "wave_n": { "phase": "model", ... } },
  "next_steps": "Resume at Phase X of Wave N — description"
}
```

v2 adds `model_assignments` so a resumed session knows which models are mid-phase.

## 2.5 Bug Operations Center (Two Linked Standing Teams)

**Bug CAPTURE Team (QG)** — PDT + Reviewer: Lead + Scanner-Static + Scanner-Runtime + Reviewer. Models: **Sonnet / Sonnet / Sonnet / Opus**.

- Lead classifies bugs by severity and blast radius.
- Scanner-Static runs static analysis, linting, type checking.
- Scanner-Runtime runs the app, captures runtime errors, edge cases.
- Reviewer (Opus) validates each bug is reproducible with a minimal repro case — Opus because false-positive bugs waste the whole Bug Fix loop.

**Bug FIX Team (SA)** — SDT-seq: Lead → user decision → Executor → Reviewer → Learning Recorder. Models: **Opus / (user) / Sonnet / Opus / Sonnet**.

- Lead (Opus) analyzes root cause, presents fix OPTIONS to user (never assumes).
- Executor (Sonnet) implements the user-approved fix.
- Reviewer (Opus) verifies fix does not introduce regressions.
- Learning Recorder (Sonnet) saves learnings globally — no duplicates, enhances existing entries.

**Interaction protocol:**

1. Capture team finds bug → files with severity + repro steps.
2. Bug presented to USER for fix strategy decision (never assume — Invariant Rule 4). The orchestrator NEVER auto-approves a bug fix. The Bug Fix Team Lead presents OPTIONS (not a single recommendation) so the user makes an informed choice.
3. User approves approach → Fix team implements (Sonnet) in a worktree-isolated dispatch (`isolation: "worktree"`).
4. Fix team reviewer (Opus) verifies → Learning recorder saves the pattern.
5. Dashboard team updates bug counters.

## 2.6 Cleanup Team (P) — SDT, model: Sonnet

**Superpower:** Explicit cleanup between waves.

- Lead identifies all temp files, stale state, leaked processes.
- Executor kills processes, removes temp files, resets test DBs, clears caches.
- Reviewer verifies clean slate — next wave starts with zero contamination.
