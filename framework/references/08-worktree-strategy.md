# Part 8 — Git Worktree Strategy for Large Projects

Use git worktrees to isolate wave execution, enable safe experimentation, and provide clean rollback points for large, multi-wave projects.

**v2 addition:** the `Agent` tool now accepts `isolation: "worktree"`, which creates a temporary worktree automatically for a single dispatch and auto-cleans it if no changes were made. v2 distinguishes two layers:

- **Wave-level worktrees** (unchanged from v1) — one long-lived worktree per wave, branch `worktree/wave-N-<descriptor>`, merged after the wave passes all phases.
- **Dispatch-level worktrees** (new in v2) — `isolation: "worktree"` on each writing dispatch (Implementer, Bug Fix Executor) gives the orchestrator a disposable scratch space *inside* the wave worktree for individual attempts. Successful dispatches have their changes pulled into the wave worktree by the orchestrator; failed dispatches auto-clean.

## 8.1 When to Use Worktrees

Activate wave-level worktree mode when ANY of these apply:

- Multi-wave project with 3+ waves.
- Waves touch independent code paths that benefit from isolation.
- Bug fixes have uncertain outcomes requiring safe experimentation.
- Multiple teams need code isolation for parallel read/write operations.

Dispatch-level isolation is used **always** for any writing dispatch, regardless of project size.

## 8.2 Worktree-Wave Mapping

- Main branch is SACRED — never write directly during wave execution.
- Each wave gets its own worktree: branch name `worktree/wave-N-<descriptor>`.
- Quality gate teams READ from the wave worktree (no separate worktree needed).
- Bug fix teams work in the wave worktree (fixes stay isolated until merged). Each Bug Fix Executor dispatch runs with `isolation: "worktree"` against the wave worktree.
- One writing team per worktree at a time — enforced by the orchestrator.

## 8.3 Merge Protocol

- Wave passes ALL phases (through Phase 12.1) → merge worktree to main.
- Wave fails a quality gate → fix in worktree, re-run the failed gate, then merge.
- Orchestrator resolves merge conflicts (never auto-resolved). *v2:* user is prompted via the orchestrator; the `PreToolUse` commit-guard hook also fires to block planning-doc paths.
- Post-merge: run quick smoke test on main before starting the next wave.
- Merge commits reference the wave number and descriptor for traceability.

## 8.4 Cleanup Protocol

- Successful merge → delete worktree and its branch immediately.
- Failed wave → preserve worktree for user diagnosis, delete only after user review.
- Session end → list all active worktrees in the final checkpoint.
- Orphaned worktrees (from crashed sessions) are flagged on next session start.
- Dispatch-level worktrees are auto-cleaned by the `Agent` tool when the dispatch makes no changes.

## 8.5 Worktree Rules (NON-NEGOTIABLE)

1. One writing team per worktree at a time — read-only teams may share.
2. Quality gates can READ any worktree without restriction.
3. Checkpoint team saves worktree state (branch name, path, status) in every checkpoint.
4. Never force-push worktree branches.
5. Worktree creation/deletion is logged in the dashboard.
6. If a worktree merge introduces conflicts, the orchestrator escalates to the user before resolving — never auto-resolve merge conflicts.
7. Dispatch-level worktrees (`isolation: "worktree"` on a single `Agent` call) MUST NOT cross wave boundaries — every dispatch that isolates must target the wave worktree as its base.
