# Part 10 — Model Routing

**Principle:** *Decide with Opus, Do with Sonnet, Display with Haiku.*

Opus holds every position where bad judgement causes rework — planning, criteria writing, adversarial hardening, root-cause analysis, output alignment, reviewer sign-off on risky artifacts. Sonnet holds every position where mechanical throughput matters — writing tests, writing code, running scans, executing test suites, applying user-approved fixes, committing, cleaning up. Haiku only runs where the output is trivial and the failure mode is "display is stale" (dashboard re-render, version-number bump).

## 10.1 Role → model matrix

| Role type | Model | Why |
|-----------|-------|-----|
| Orchestrator (main session) | **Opus 4.7 (1M ctx), effort: xhigh** | Long-horizon planning + routing user decisions + holding all wave summaries. 1M ctx prevents mid-mission compaction. |
| Team Lead — reasoning-heavy (AC, ACB, OA, TEET-TC, BTEET, Bug Fix) | **Opus** | Decomposition, criteria authoring, options presentation — judgement tasks. |
| Team Lead — execution-heavy (TDD-RED, TDD-GREEN, TEET, BTEET-X, SEA, DS, Cleanup, Checkpoint, Permission) | **Sonnet** | Coordinates mechanical work; doesn't need to author novel judgement. |
| Executor — writing code / tests / fixes | **Sonnet** | Clean implementation at 1/5 Opus cost. |
| Executor — adversarial hardening (ACB, BSEA, BTEET) | **Opus** | "What could go wrong?" is the exact task where Opus beats Sonnet most. |
| Reviewer — risky artifact (AC, GREEN, BF, OA, TEET-TC, hardening phases) | **Opus** | Sign-off is a judgement call; Opus reviewing Sonnet's output is the core quality mechanism. |
| Reviewer — mechanical scan (BC Reviewer, SEA, DS) | **Sonnet** (BC Reviewer → Opus — false positives cost a full BF loop) | Cheaper review where the question is "did the scan run?" not "is the finding real judgement?" |
| Scanner (BC static/runtime, SEA, DS auditor) | **Sonnet** | Running tools and aggregating output. |
| Dashboard render | **Haiku** | ASCII redraw; failure mode is stale display. |
| Version bump | **Haiku** | Change one number. |
| Git commit | **Sonnet** | Needs to understand which files are allowed to be committed. |

## 10.2 Fresh-eyes escalation

Every hardening phase (`[ACB]`, `[BSEA]`, `[BTEET]`) runs **100% Opus** — Lead + Executor + Reviewer all Opus. This is the most adversarial phase in the framework; Sonnet has no role here. The dispatches are sequential (SDT-seq) so the Reviewer's Opus context contains only the hardening output, not the first-pass team's reasoning.

## 10.3 Cross-language binding escalation

Per [`05-language-binding-rules.md`](05-language-binding-rules.md), any wave that crosses a language boundary (N-API, FFI, WASM) escalates the `[TDE-GREEN]` Reviewer from Sonnet to **Opus**. Field-name drift and ID truncation are reasoning bugs.

## 10.4 Runtime escalation rules

The orchestrator may escalate a dispatch's model at runtime based on signals:

| Signal | Escalate to |
|--------|-------------|
| A Sonnet scan returns >10 findings in a single phase | Re-run the Reviewer on Opus — 10+ findings suggests scanner noise, Opus judges which are real |
| A Sonnet Implementer dispatch has failed ≥2 times | Retry Implementer on Opus (last resort — usually the real fix is better AC, not a bigger model) |
| `[OA]` alignment score < 95% | Re-run `[OA]` Comparator on Opus with extended thinking |
| Bug Fix Team Lead struggles to articulate distinct options | Re-invoke Lead with higher `effort` (xhigh on Opus) |

## 10.5 Cost profile (indicative)

Token distribution per wave, measured over dispatches (not wall clock):

- **Sonnet ~70%** — every `[TDE-RED]`, `[TDE-GREEN]` Implementer, `[BC]`, `[SEA]`, `[DS]`, `[TEET]`, `[BTEET-X]`, Bug Fix Executor, Permission, Checkpoint, Cleanup, Git Commit.
- **Opus ~25%** — Orchestrator, every Reviewer on critical artifacts, every hardening phase (Lead + Executor + Reviewer all Opus), `[OA]`, Bug Fix Team Lead.
- **Haiku ~5%** — Dashboard redraws (triggered by `PostToolUse` hook, so frequency is high but each dispatch is tiny), Version Bump.

Compared to an all-Opus realization this saves a large fraction of cost; compared to an all-Sonnet realization the extra Opus spend is concentrated on reviewer + hardening roles where Sonnet would miss enough to force rework.

## 10.6 Never-degrade rule

The framework's quality does not depend on frugality. If a user sets `"always use Opus"`, the framework still works — the assignments in §10.1 become the *minimum* quality tier, and every "Sonnet" slot can be upgraded to Opus without structural change. v2 explicitly rejects any "auto-downgrade" pattern that routes work to Haiku beyond the two positions listed in §10.1.
