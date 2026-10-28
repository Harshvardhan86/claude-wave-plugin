# Part 4 — Meta-Orchestration Specification

## 4.1 How the Orchestrator Sequences Waves

1. **PLAN:** Decompose the mission into waves (each wave = a vertical slice of value). Materialize the plan via `TaskCreate` so every phase is visible in `/tasks`.
2. **For each wave:**
   a. Announce wave start to Dashboard Team (background dispatch on Haiku).
   b. Execute the phased pipeline (see [`03-wave-pipeline.md`](03-wave-pipeline.md)).
   c. At each phase:
      - Instantiate or activate the designated team per its dispatch pattern (SDT / SDT-seq / PDT — see [`01-architecture.md`](01-architecture.md) §1.4).
      - Pass bounded context (only what the team needs — lean, non-polluted).
      - Pass the assigned `model` (Opus / Sonnet / Haiku — see [`10-model-routing.md`](10-model-routing.md)) on the `Agent` dispatch.
      - Writing phases pass `isolation: "worktree"` automatically.
      - Long-running phases pass `run_in_background: true` and track via `Monitor`.
      - Wait for team completion + reviewer sign-off.
      - Collect result and update global state (`TaskUpdate`).
   d. If any quality gate fails → STOP the wave, escalate to user.
   e. On wave success → trigger Cleanup → Checkpoint → Dashboard → next wave.
3. After ALL waves: Final dashboard, final checkpoint, summary to user.

## 4.2 How Permissions Are Acquired Once

```
SESSION START
  → Orchestrator analyzes ALL waves in the plan
  → Extracts every permission needed across the entire session
  → Permission Team acquires ALL permissions in ONE batch (Sonnet, SDT)
  → Permission Team's reviewer verifies ALL permissions are active
  → Result: permission manifest saved to checkpoint
```

**No team ever requests permissions again. Missing permission later = BUG.**

## 4.3 Scope answers and the CR gate flag

A wave answers four scope questions, and never guesses one. Each answer is `true`, `false` or `unknown`, and `unknown` is not a silent `false`: a row whose condition is unanswered is required and not yet allowed, so the dispatch is denied until someone answers it.

| Question | Asked as | Gates |
|---|---|---|
| `vocabulary` | Does this wave introduce a new kind of record, or a new value of an existing classification (a status, a category, a role), that a user will see? | `[UIA]` at 0.5, `[ES]` at 4.2 |
| `behaviour-change` | Does this wave change existing system behaviour? | `[BEN]` at 0.8, `[BEN-CLOSE]` at 12.5, and `[DR]` together with `ui` |
| `ui` | Does this wave touch anything the user looks at? | `[DR]` at 1.5, the GREEN visual approval gate |
| `cr` | Should this wave run the Code Review gate? | `[CR]` at 3.5 |

**When each answer is due.** In full mode, answering `vocabulary` and `behaviour-change` **before the wave is created and before its first dispatch** is the command's policy: `/wave-start` asks the first two before it creates the wave state and passes them to `wave-init.sh`; it asks the other two straight afterwards and records them with `wave-set.sh`. The gate enforces each answer only at the rows that read it: `[UIA]` needs only `vocabulary`, `[BEN]` needs `behaviour-change` and a settled `[UIA]`, and `[AC]` names both rows as predecessors, so the gate requires **both answers before `[AC]`** and everything after it; an unanswered flag is denied `W-SCOPE`, never skipped. `ui` and `cr` may wait until `[TDE-RED]`. Demo mode is unaffected: its full-only predecessors are skipped on mode before their condition is ever read, so a demo wave can dispatch `[AC]` with every flag still unknown. Solo mode consults no phase table and asks nothing.

### CR gate flag (v2-new)

Phase 3.5 `[CR]` (CodeRabbit code review) is **opt-in per wave**. The orchestrator holds a `cr_enabled: boolean` state per wave and decides from mission parameters:

| Signal | `cr_enabled` |
|--------|--------------|
| User explicitly asked for "AI code review" / "CodeRabbit" in the mission | `true` |
| Wave changes >500 LOC | `true` |
| Wave is library/API-surface code with external consumers | `true` |
| Wave is documentation-only or config-only | `false` |
| Wave is a hot-fix where speed > depth | `false` |
| Default | `false` |

When `cr_enabled = true`, the orchestrator invokes the CodeRabbit plugin after `[TDE-GREEN]` signs off GREEN. Findings are routed into the standing Bug Fix Team loop exactly like `[BC]` / `[SEA]` / `[DS]` findings: user approves each fix strategy, no auto-apply. See [`12-mcp-and-plugins.md`](12-mcp-and-plugins.md) for the plugin wiring.

## 4.4 Session-Wide Task State (v2-new)

v2 replaces the v1 `tasks/todo.md` with native `TaskCreate` / `TaskList` / `TaskUpdate`:

- One top-level Task per wave.
- One sub-Task per phase. 18 rows run in every full-mode wave; each conditional row that
  applies adds one. `[UIA]` and `[ES]` engage on a vocabulary wave, `[BEN]` on a
  behaviour-changing wave, `[DR]` on a UI **or** behaviour-changing wave, `[CR]` when the
  code-review gate is opted in, `[BEN-CLOSE]` when `[BEN]` ran, and each of the seven
  `[BF-*]` rows when the scan before it reported findings. Maximum 31 per wave.
- Status transitions: `pending` → `in_progress` → `completed` | `blocked` | `cancelled`.
- The `TaskCreated` hook fires the Dashboard Team to refresh the board.
- Checkpoint captures the full `TaskList` snapshot for resume.

## 4.5 Auto-Compact Handling (v2-hardened)

v1 invariant: "Auto-compact = STOP, fresh terminal." v2 adds hook enforcement:

1. `PreCompact` hook fires (see [`11-hooks-and-automation.md`](11-hooks-and-automation.md)).
2. Hook invokes Checkpoint Team (Sonnet dispatch) to save state; returns `{decision: "block"}` if save fails.
3. Orchestrator logs the pre-compact checkpoint ID to Dashboard.
4. User is notified in the terminal: "Compaction imminent — after compact, start a fresh terminal and run `/wave-start --resume <checkpoint>`."

## 4.6 Escalation Protocol

User escalations are the only path the orchestrator takes in these cases:

| Situation | Action |
|-----------|--------|
| Quality gate fails (any `[BC]`, `[ES]`, `[SEA]`, `[BSEA]`, `[DS]`, `[CR]`, `[TEET]`, `[BTEET]` with findings) | Present OPTIONS, user decides, Bug Fix Team implements |
| `[BEN-CLOSE]` writes `BENEFIT: UNDELIVERED` | Report the verdict and its reasons to the user; the wave still closes, and the next wave's scope starts from those reasons. Never edit the Benefit AC to turn the verdict green |
| Merge conflict in worktree (see [`08-worktree-strategy.md`](08-worktree-strategy.md)) | Orchestrator asks user, never auto-resolves |
| Reviewer rejects artifact 2x in a row | Escalate to user with both Executor outputs |
| `[OA]` alignment score < 100% | Escalate with gap list; user chooses which gaps to fix |
| Ambiguous AC in Phase 1 | Escalate before `[ACB]` starts — a brutal review of an ambiguous criterion is wasted Opus spend |
