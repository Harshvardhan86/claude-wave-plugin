# Part 7 — Invariant Rules

These rules are **NON-NEGOTIABLE** regardless of wave, team, or context.

1. **Lean context per unit.** Every subagent and team gets ONLY the context it needs. No pollution. No "just in case" context dumps.
   - *v2 enforcement:* `ToolSearch`-gated per-phase tool surface ([`03-wave-pipeline.md`](03-wave-pipeline.md) §3.4) and prompt-caching of the framework's own system prompt keep each dispatch lean.

2. **Strict TDD.** Tests first → RED → implement → GREEN. No exceptions. AC guides everything.

3. **Strict build order.** Build → app startup → tests. NO shortcuts.

4. **Never assume on bugs.** Present OPTIONS to user. User decides. Always.
   - *v2 enforcement:* Bug Fix Team Lead runs on Opus specifically so root-cause analysis and options-generation have the reasoning budget to present real alternatives.

5. **Save learnings.** Every bug fix → learning saved globally. No duplicates. Enhance existing.

6. **Planning docs never committed.** Analysis and planning docs stay SEPARATE from code repo.
   - *v2 enforcement:* `PreToolUse` hook on `Bash` enforces `git commit`: W-COMMIT-DOC blocks any commit whose staged diff touches paths matching `hooks/planning-paths.tsv`, and W-COMMIT-TRAILER blocks literal AI-attribution trailers.

7. **Auto-compact = STOP.** Save checkpoint. Fresh terminal. Resume from checkpoint.
   - *v2 enforcement:* `PreCompact` hook writes `.wave/checkpoints/<ts>-precompact.md` from state and the ledger itself; no agent is spawned, and the checkpoint is enforced while the stop is advised.

8. **No team self-declares success.** The team's internal reviewer must sign off before the team reports done.
   - *v2 enforcement:* The fresh-eyes SDT-seq pattern requires a separate Reviewer dispatch whose context contains only the executor's output — the Reviewer literally cannot "see" the executor's self-justification.

9. **No hanging the system.** Use as many teams and subagents as needed, but ensure none hang, deadlock, or wait indefinitely.
   - *v2 enforcement:* Long-running dispatches use `run_in_background: true` + `Monitor`; the orchestrator never sleeps in a polling loop.

10. **The orchestrator is the single throat to choke.** All decisions, all escalations, all user interactions flow through it.
