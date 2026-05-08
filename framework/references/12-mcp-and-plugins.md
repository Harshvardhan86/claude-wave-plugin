# Part 12 — MCP Servers and Plugins

v2 wires two MCP servers into specific phases. Both are opt-in at the framework level — a wave works without either, but adding them raises quality and evidence density at well-defined points.

## 12.1 Playwright MCP — default for UI `[TEET]` / `[BTEET-X]`

**When the Playwright MCP is loaded**

The orchestrator loads the Playwright MCP for:

- `[TEET]` — Frontend Tester dispatch (Sonnet, PDT), whenever the wave ships UI.
- `[BTEET-X]` — Frontend Executor dispatch (Sonnet, PDT), whenever the wave ships UI.

For all other phases, Playwright stays deferred — `ToolSearch` is used to surface Playwright tools only in the two dispatches above. This matches Invariant 1 (lean context per unit).

**What the Frontend Tester produces**

| Artifact | Tool | Saved to |
|----------|------|----------|
| Route-level screenshots | `browser_take_screenshot` | `evidence/wave-N/teet/screenshots/` (or `bteet-x/screenshots/` in Phase 12) |
| Console + network logs | `browser_console_messages`, `browser_network_requests` | `evidence/wave-N/teet/logs/` |
| Interaction proofs (click, type, drag sequences captured as a test script) | `browser_run_code` | inline in the test file |

All evidence is referenced from the Reviewer's sign-off: "Phase 10 complete — backend 42/42, frontend 38/38 w/ screenshots at `evidence/wave-N/teet/screenshots/`."

**Long-running screenshot sessions**

Use `run_in_background: true` on the Frontend Tester dispatch when a full run exceeds a few minutes, then `Monitor` the stdout for progress. The orchestrator does not sleep-poll.

## 12.2 CodeRabbit plugin — optional `[CR]` gate

**Activation**

Set per-wave via the orchestrator's `cr_enabled` flag (see [`04-meta-orchestration.md`](04-meta-orchestration.md) §4.3). When true, Phase 3.5 `[CR]` runs after `[TDE-GREEN]` signs off GREEN and before `[BC]` starts.

**Invocation**

The CodeRabbit plugin exposes a single review action per wave. The orchestrator invokes it as a single plugin call — this is a Quality Gate topology (QG), not a team topology. Findings are returned to the orchestrator and routed into the standing Bug Fix Team loop (Lead presents OPTIONS, user decides, Executor applies, Reviewer verifies, Learner records).

**Fallback**

When `cr_enabled = false`, the pipeline skips Phase 3.5 entirely — quality coverage falls back to `[BC]` + `[SEA]` + `[BSEA]` + `[OA]` + `[TEET]` + `[BTEET]`, which together are already very strong.

**Evidence**

CodeRabbit's review output is saved alongside the wave checkpoint under `evidence/wave-N/cr/review.md` for traceability.

## 12.3 Per-phase MCP scoping via `ToolSearch`

The orchestrator passes a `ToolSearch` select string to each dispatch's prompt so the dispatch can load only the tools it needs. Example scoping:

| Phase | `ToolSearch` select string |
|-------|---------------------------|
| `[AC]`, `[ACB]`, `[OA]` | `select:Read,Grep,WebFetch,WebSearch` |
| `[TDE-RED]`, `[TDE-GREEN]` | `select:Edit,Write,Bash,Read,Grep,TaskUpdate` |
| `[CR]` | `select:mcp__coderabbit__*` (plugin-provided) |
| `[BC]`, `[SEA]`, `[BSEA]` | `select:Read,Grep,Bash,NotebookRead` |
| `[DS]` | `select:Read,Grep,Bash,WebFetch` (CVE lookups) |
| `[TEET]`, `[BTEET-X]` (UI in scope) | `select:Bash,mcp__plugin_playwright_playwright__*,Monitor` |
| `[TEET]`, `[BTEET-X]` (no UI) | `select:Bash,Monitor` |
| `[TEET-TC]` | `select:Read,Grep,WebFetch` |
| Version Bump | `select:Bash` |
| Git Commit | `select:Bash` |
| `[CL]`, `[CCP]`, `[AD]` | `select:Bash,Write,TaskUpdate` |

This keeps each Agent dispatch's surface area small — Playwright does not leak into `[AC]`, CodeRabbit does not leak into `[TEET]`, and so on.

## 12.4 MCP server startup budget

Subagent MCP servers now connect **in parallel** at dispatch startup. Framework impact: loading Playwright + CodeRabbit in two different dispatches costs roughly the same wall-clock time as loading one, so per-phase scoping does not materially inflate the wave duration.

## 12.5 Trust boundaries

- **Playwright MCP** runs in a sandboxed browser context in the local environment; no network exfiltration risk beyond the URLs the test script visits.
- **CodeRabbit plugin** sends the diff (only — not the full repo) to CodeRabbit's cloud for review. If the wave touches proprietary code under a no-external-review policy, set `cr_enabled = false` or disable the plugin at the MCP level. The orchestrator will not toggle `cr_enabled` to `true` without explicit mission parameters indicating approval.
