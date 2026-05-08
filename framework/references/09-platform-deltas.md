# Part 9 — Platform Deltas (Oct 2025 → Apr 2026)

v2 is a realization of v1's methodology against Claude Code / Agent SDK primitives that shipped after v1 was written. This file names each primitive the framework assumes. If a primitive is unavailable in your environment (older Claude Code build, SDK-only, API-only), the framework still works — substitute the v1 manual pattern noted in each row.

## 9.1 Subagents (`Agent` tool)

| Primitive | Used for | v1 fallback if unavailable |
|-----------|----------|----------------------------|
| Per-dispatch `model: "opus" \| "sonnet" \| "haiku"` | Foundation of model routing — every dispatch names its model. | Run all phases on whatever the session model is; ignore [`10-model-routing.md`](10-model-routing.md). |
| `isolation: "worktree"` | Auto-worktree per writing dispatch. Auto-clean when no changes. | Manual `git worktree add / remove` per Part 8 (v1). |
| `run_in_background: true` | Dashboard Team, long Playwright runs, long test suites. | Dispatch synchronously; orchestrator blocks until done. |
| `Monitor` tool | Streams events from background dispatches/shells. | Poll via repeated tool calls (slower, uses more tokens). |
| Forked subagents (`CLAUDE_CODE_FORK_SUBAGENT=1`) | Parallel isolation of concurrent read-only scans. | Run scans serially. |
| Subagent MCP servers via agent frontmatter | Load Playwright only in TEET dispatches; load CodeRabbit only in CR dispatch. | Every session loads every MCP server — higher startup cost, context pollution. |
| **Nested subagents blocked** | Forces the prompt-scoped team pattern in [`01-architecture.md`](01-architecture.md) §1.4. | Not a fallback — architectural constraint; the framework's team pattern is designed around it. |

## 9.2 Hooks (settings.json)

| Primitive | Used for | v1 fallback if unavailable |
|-----------|----------|----------------------------|
| `PreCompact` hook | Force Checkpoint Team save before any compaction — enforces Invariant 7. | Orchestrator watches context budget; explicitly invokes Checkpoint before risky ops. |
| Conditional hooks with `if` clause | Run Dashboard refresh only on writing tools; run commit-guard only on `git commit`. | Unconditional hooks; larger blast radius. |
| `PreToolUse` hook with `updatedInput` | Rewrite commits to drop planning-doc paths. | Hook refuses the commit; user re-runs manually. |
| `PostToolUse` hook | Dashboard refresh after Edit/Write/Bash(git)/TaskUpdate. | Manual Dashboard invocation after each phase. |
| `TaskCreated` hook | Auto-announce new tasks to Dashboard. | Dashboard team polls `TaskList`. |
| `type: "mcp_tool"` in hooks | Call MCP tools directly from hook handlers (e.g., call Playwright screenshot on build complete). | Shell out to CLI if the MCP exposes one. |

## 9.3 Scheduling & background work

| Primitive | Used for | v1 fallback if unavailable |
|-----------|----------|----------------------------|
| `TaskCreate` / `TaskList` / `TaskUpdate` | Native replacement for v1's `tasks/todo.md`. Visible in `/tasks`; survives compaction. | `tasks/todo.md` file in the analysis directory. |
| `ScheduleWakeup` (dynamic `/loop`) | Self-paced polling of long-running ops — no shell `sleep` loops. | Shell `sleep` + re-check (wastes cache). |
| `CronCreate` | Scheduled recurring work (e.g., nightly regression wave). | External `cron` / systemd timer. |

## 9.4 Context & caching

| Primitive | Used for | v1 fallback if unavailable |
|-----------|----------|----------------------------|
| 1M context window on Opus 4.7 | Orchestrator holds full plan + summaries of every prior wave without compacting. | Compact early, lose plan fidelity. |
| Prompt caching 1-hour TTL (`ENABLE_PROMPT_CACHING_1H`) | Framework's own system prompt + reference files cache across phases — each phase pays cache-read, not cache-write. | 5-minute default TTL; more cache misses. |
| `ToolSearch` + deferred tools | Per-phase tool surface (Playwright only in TEET, etc.). | All tools loaded every dispatch; context bloat. |
| Workspace-level prompt-cache isolation (Feb 2026) | Cache bleeds don't cross sessions. | Monitor cache hit rate manually. |

## 9.5 Verification primitives

| Primitive | Used for | v1 fallback if unavailable |
|-----------|----------|----------------------------|
| Playwright MCP server | Default evidence path for `[TEET]` and `[BTEET-X]` when the wave ships UI. Screenshots + network capture. | Manual screenshot via OS tooling; flaky. |
| CodeRabbit plugin | Optional Phase 3.5 `[CR]` gate. | Skip CR gate; rely on `[BC]` + `[SEA]` + `[BSEA]`. |
| Skill frontmatter `effort: xhigh` | Orchestrator skill invocation runs at max reasoning. | Session-default effort. |
| Agent frontmatter `initialPrompt` | Auto-submit first turn for standing-team agents (e.g., Dashboard). | User types the prompt manually. |

## 9.6 Known gaps (as of Apr 2026)

- **No native subagent memory store.** Learnings live in this session's memory system (see `~/.claude/projects/.../memory/`).
- **No built-in Opus-escalation logic.** The framework's orchestrator implements it (see [`10-model-routing.md`](10-model-routing.md) §10.4).
- **Nested subagents blocked.** Architectural constraint the framework respects; do not attempt workarounds that spawn from inside a dispatch.
