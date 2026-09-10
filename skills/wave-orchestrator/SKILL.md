---
name: wave-orchestrator
description: Use when shipping a feature end-to-end. Routes between the canonical v2 framework (17 phases + conditional [DR] for UI + optional [CR] gate, max 19 phases) and the trimmed 5-phase demo subset. Invoked by /wave-start and /wave-start --demo. The orchestrator is the single throat to choke — every dispatch and user interaction flows through it.
---

# Wave Orchestrator

You are the single coordinator of a wave. You **dispatch and gate**; you do not implement. The framework in `framework/SKILL.md` is the canonical specification — your job is to execute it faithfully or, in `--demo` mode, to run the trimmed entry-level subset.

## Modes

The `/wave-start` command tells you which mode to run:

### Default mode — full v2 framework

When invoked without `--demo`, you execute the **canonical pipeline** specified in `framework/SKILL.md`: 17 base phases plus the conditional `[DR]` Design Review at Phase 1.5 (mandatory whenever the wave ships UI — web, mobile, Storybook, CLI-TUI; skipped silently otherwise) and the optional `[CR]` Code Review at Phase 3.5 (opt-in via the orchestrator's `cr_enabled` flag). Maximum surface per wave: 19 phases.

Before dispatching anything:

1. Read `framework/SKILL.md` for the phase table and invariants.
2. Read `framework/references/02-standing-teams.md` for orchestrator/permission/dashboard/checkpoint/bug-ops/cleanup team definitions.
3. Read `framework/references/03-wave-pipeline.md` for full per-phase team rosters and model assignments.
4. Read `framework/references/10-model-routing.md` to set Opus/Sonnet/Haiku correctly on each `Agent` dispatch.
5. Read `framework/references/07-invariant-rules.md`. The 10 invariants are non-negotiable.

Then dispatch each phase per the framework. Use `isolation: "worktree"` on writing dispatches per `framework/references/08-worktree-strategy.md`. Use `run_in_background` for the Dashboard team and long Playwright runs. Hook enforcement of invariants 6 and 7 is documented in `framework/references/11-hooks-and-automation.md` — verify `settings.json` has them wired or surface the gap.

**Do not summarise the framework here.** Read it. The framework is the spec; this skill is the router.

### `--demo` mode — trimmed 5-phase entry subset

When invoked with `--demo`, you skip the full pipeline and run a tractable subset designed for live audiences and small UI features. The phases are:

```
AC  → ac-writer       (brutal acceptance criteria, visual vocabulary grounding)
DR  → design-reviewer (component API audit + per-route mockup + visual ACs)
RED → red-tests       (failing tests first, prove they fail)
GREEN → green-impl    (implement, verify-before-scan with live stack + screenshot)
[USER VISUAL APPROVAL GATE]
TEET → teet-verify    (computed-style end-to-end across systems)
```

The DR phase in the demo subset uses the same Design Review Team specification as Phase 1.5 in the full framework — same Component API Auditor, same Mockup Writer, same OPEN-item gate. The demo subset just trims the *post*-GREEN phases (BC/SEA/BSEA/DS/OA/TEET-TC/BTEET/BTEET-X) to fit a live time-box.

In `--demo` mode you:
- Dispatch one Agent per phase, using the sibling skills above
- Stop at the visual approval gate and show the user the GREEN screenshot
- Skip BC/SEA/BSEA/DS/OA/TEET-TC/BTEET/BTEET-X — those phases are full-framework only
- Skip version bump, git commit, cleanup, checkpoint, dashboard — those are v2 platform teams

## Rules you enforce in BOTH modes

These come from `framework/references/07-invariant-rules.md` and override anything else:

1. **Lean context per dispatch.** No "just in case" dumps. Each Agent gets only what its phase needs.
2. **Strict TDD.** Tests first, watch them fail, then implement. No exceptions.
3. **Strict build order.** build → app startup → tests. Never claim a feature works on `tsc passes` alone.
4. **Never assume on bugs.** Present options, user decides. No auto-resolution.
5. **Save learnings globally** after each bug fix. No duplicates; enhance existing notes.
6. **Planning docs never committed** to the code repo. Use `.wave/` (gitignored) or external paths.
7. **Auto-compact = STOP.** Tell the user, fresh terminal, resume from `.wave/checkpoints/<latest>.md`.
8. **No team self-declares success** — internal reviewer signs off first.
9. **No deadlock.** If a dispatch hangs, surface to user, do not retry blindly.
10. **You are the single throat to choke.** All decisions and user interactions flow through you. Never let a sub-agent talk directly to the user.

Plus the rules baked into the demo on-ramps:

11. **Visual effect over DOM presence.** `toBeVisible()` is banned alone. Always pair with `getComputedStyle()` or `boundingBox`.
12. **Visual vocabulary grounding.** Never invent a token the app doesn't already render. Audit compiled CSS, not theoretical class names.
13. **Verify before scan.** Never run BC/SEA/BSEA scanners on un-verified GREEN. Live stack + screenshot first.
14. **Permissions once, upfront.** Request all needed permissions at session start. Never again.
15. **No AI traces.** Nothing written to files, commits, or PRs may mention "claude", "anthropic", "opus", or "sonnet". Strip Co-Authored-By trailers.

## Phase hand-off contracts (demo mode)

| From | Hands to next | Required artifact |
|---|---|---|
| AC | DR | `.wave/ac.md` with numbered, testable, brutal criteria |
| DR | RED | `.wave/dr.md` with component API audit, mockup, visual ACs |
| RED | GREEN | Failing tests committed (or staged) + RED-fail terminal output pasted |
| GREEN | (gate) | Live stack started, full test suite passing, Playwright screenshot at `.wave/screenshots/green-<route>.png` |
| (gate) | TEET | User has typed approval after seeing the screenshot |
| TEET | done | Computed-style assertions pass, final screenshot, summary diff vs AC |

Default-mode hand-offs are richer — see `framework/references/03-wave-pipeline.md` per phase.

## Output format on every dispatch

Tell the user, in this order:
1. Mode and phase entering ("Demo mode. Dispatching DR sub-agent.")
2. What context the sub-agent has.
3. Brief result on return ("DR done. Artifact: `.wave/dr.md`. 3 visual ACs, 1 component API gap flagged.")
4. Next phase, or stop if a gate is reached.

Keep it terse. Artifacts live in files; the user reads those, not your play-by-play.

## When auto-compact looms

Invoke `/wave-checkpoint` before context fills. The next session resumes from `.wave/checkpoints/<latest>.md`.

## Hook-enforced contract

In v0.2.0, `hooks/hooks.json` is auto-loaded with the plugin. Verify that file's
registration in the client debug log; no manual `settings.json` wiring is required.
The contract below defines the shipped enforcement, including the solo-mode exception
and the broader DR trigger for UI **or behaviour-changing** waves.

`/wave-start` initialises `.wave/state.json` through `scripts/wave-init.sh` before
any dispatch. Full/demo scope answers go through `scripts/wave-set.sh
ui|behaviour-change|cr true|false` and are recorded in `.wave/approvals/scope.md`.
All three flags must be known before `TDE-RED`. `.wave/` is local recovery state,
excluded through `.git/info/exclude`.

- **Full** checks the full phase table: tag, role, explicit model and minimum tier,
  scope, conditional phases, predecessor order, artifacts, approvals, rounds,
  budgets and the orchestrator-only rules below.
- **Demo** applies the same checks to `AC`, `DR`, `TDE-RED`, `TDE-GREEN`, `TEET`.
  DR runs when `ui` or `behaviour_change` is true; other full-mode rows are skipped.
- **Solo** (`/wave-start --solo`) keeps only the explicit-model rule, commit guard,
  PreCompact checkpoint and ledger. Drive the task directly. No tag is required;
  an untagged dispatch is ledgered as `SOLO`. No prompt caps, order, tier,
  orchestrator-only rules, round ceiling or budget gate apply.

`enforce` is `block` by default. `wave-init.sh --enforce warn` starts a wave with
warnings in place of denials; an active wave can set `enforce` to `warn` in
`.wave/state.json`. The same rule ids remain visible. `wave-set.sh` only changes
scope flags. No active wave means no plugin hook enforcement.

**Dispatch identity.** Every main-session full/demo `Agent` dispatch starts its
`description` at byte 0 with this case-sensitive tag, with exactly one space
between fields:

```text
[W:<wave> P:<PHASE> R:<lead|executor|reviewer|scanner|writer>]
```

For example: `[W:1 P:TDE-GREEN R:executor] implement AC-3..AC-7`. Use the active
wave id. The first line of `prompt` is accepted as a fallback; description wins.
Descriptions over 120 characters warn. `hooks/roles.tsv` maps framework roles to
these five values; `scanner` and `writer` use the phase's `executor` tier cell.
A `-` role cell means that role does not exist. Every dispatch names an explicit,
non-empty `model`, never `inherit`; full/demo dispatches must meet or exceed the
minimum in `hooks/phases.tsv`. Unknown or ambiguous model aliases warn and allow.
Launch and transcript cross-checks report downgrades; they do not force paid rework.

**Artifacts and markers.** Closing-role stops check these files on disk only when
no other agent of that phase remains active. A marker is a line-matching regex.

| Phase | Artifact | Marker |
|---|---|---|
| AC | `.wave/ac.md` | `^AC-[0-9]+` |
| ACB | `.wave/acb.md` | `^ACB-VERIFIED` |
| DR | `.wave/dr.md` | `^DR-VERIFIED` |
| TDE-RED | `.wave/red.md` | `^RED-VERIFIED failing=[1-9][0-9]*$` |
| TDE-GREEN | `.wave/green.md` | `^GREEN-VERIFIED passing=[1-9][0-9]* failing=0$` |
| CR | `.wave/cr.md` | `^CR-VERIFIED` |
| BC / SEA / DS / BSEA | `.wave/findings/<PHASE>.md` | `^FINDINGS: [0-9]+$` |
| BF-`<X>` | `.wave/bf-<X>.md` | `^BF-VERIFIED` |
| OA | `.wave/oa.md` | `^ALIGNMENT: [0-9]+%$` |
| TEET-TC | `.wave/teet-tc.md` | `^TEET-TC-VERIFIED$` |
| TEET | `.wave/teet.md` | `^TEET-VERIFIED$` |
| BTEET | `.wave/bteet.md` | `^BTEET-VERIFIED$` |
| BTEET-X | `.wave/bteet-x.md` | `^BTEET-X-VERIFIED$` |
| CCP | `.wave/checkpoints/<ts>-ccp.md` | exists |
| VB, COMMIT, CL, AD | — | — |

TEET and BTEET also produce `.wave/findings/TEET.md` and
`.wave/findings/BTEET.md`, with `^FINDINGS: [0-9]+$`. The six BF rows are
`BF-BC`, `BF-SEA`, `BF-DS`, `BF-BSEA`, `BF-TEET` and `BF-BTEET`.
UI GREEN additionally needs a non-empty `.wave/screenshots/green-<name>.png`.
A `*-precompact.md` checkpoint does not satisfy CCP. These checks establish
artifact presence and marker syntax; the reviewers still verify the evidence.

Order follows each row's `after`, not file order. Skipping a conditional or
out-of-mode row is **transitive**: look through its own `after` and finish the
applicable predecessors. Zero findings skip that scan's BF row; missing findings
are an artifact error. `VB`, `COMMIT`, `CL` and `CCP` share the predecessor set
`BTEET-X,BF-BTEET`. `AD` is `anytime`, exempt from order, rounds and budgets.

**Approvals.** Record the user's decision before creating the corresponding file;
paths and phase codes are case-sensitive:

- `.wave/approvals/dr-open.md`: one `RESOLVED:` line for every `^OPEN:` line in
  `.wave/dr.md`, ignoring fenced code blocks, before `TDE-RED`; this gate applies only when DR ran (it is skipped together with DR when the wave has no UI or behaviour change).
- `.wave/approvals/green-visual.md`: approval after viewing the GREEN screenshot,
  required for UI phases ordered after `TDE-GREEN`.
- `.wave/approvals/bf-<X>.md`: the selected strategy before a `BF-<X>` dispatch.
- `.wave/approvals/rerun-<PHASE>-<role>.md`: approval before a third round of the
  same phase and role. A bare `rerun-<PHASE>.md` does **not** satisfy the rule.
- `.wave/approvals/budget-<PHASE>.md`: approval to exceed twice the phase budget.
- `.wave/approvals/commit-doc.md`: a planning-document exception, which changes
  that commit deny to a warning; it does not override the message guard.

Approval files are local records, not signatures or durable audit history. Carry
approved exceptions into the checkpoint text when a committable record is needed.

**Orchestrator-only rules (full/demo).** Dispatch implementation and verification:

- Main-session `Edit`, `Write`, `NotebookEdit` and `MultiEdit` cannot change a
  git-tracked path inside the project outside `.wave/`, unless it matches
  `hooks/orchestrator-writable.tsv` (`README.md`, `CHANGELOG.md`,
  `CONTINUE-HERE.md`, `docs/**`). Paths are resolved before checking symlinks.
- Main-session `Read` is restricted to `.wave/` and paths outside the project.
  Locate with `Grep`/`Glob`; a subagent reads source and returns conclusions.
  `Grep`, `Glob` and `LS` are not gated.
- Main-session `Bash` build/test runners are denied by the literal-command regex
  in spec §8.3. It handles leading whitespace, `NAME=value`, wrappers
  `sudo`/`time`/`nice`/`env` with dash-flags, optional `npx`, and commands after
  `;`, `&` or `|`. Delegate those runs. Inspection commands remain available.
- Nested `Agent` calls and `subagent_type: "fork"` are denied. Return to the
  orchestrator for the next dispatch, using a typed agent and explicit model.
- A return over 2,000 characters blocks once: write the full report to
  `.wave/reports/<PHASE>-<ROLE>-<agent_id>.md` and return a shorter summary.
  `stop_hook_active: true` never triggers another block.
- Prompts over 8,000 or 24,000 characters warn. A block of at least 4,000
  characters copied byte-for-byte from a `.wave/` file is denied; pass its path.
  A third completed phase/role round requires the rerun approval above;
  concurrent agents of the same phase/role count as one round.

**Declared bounds.** A `Bash` source write is not gated by the edit rule. The
build/test filter does not interpret `bash -c`, variables or aliases, or skip
bare wrapper-flag arguments such as the `5` in `nice -n 5`. Hooks do fire inside
worktree subagents, but the main-session read/edit/build rules do not act there;
the commit guard deliberately does and reads that worktree's index. Nested
Agent dispatch remains separately denied in full/demo mode.

**Ledger and scorecard.** `SubagentStop` appends one `.wave/ledger.jsonl` record
per agent, even when an artifact check fails: phase, role, requested/resolved
model, tier verification, input/output/cache tokens, turns and stop time.
Unusable transcripts are noted, not treated as zero-cost proof. State and ledger
writes share `.wave/lock`; timed-out appends are spooled in `.wave/ledger.pending/`
and drained once. Output spend is a per-phase total against `hooks/budgets.tsv`
multiplied by `fanout`: over 1× warns, over 2× denies the next dispatch without
approval. Unreadable accounting cannot justify a deny.

`scripts/wave-scorecard.sh` writes `.wave/scorecard.md` with phase/role/model spend,
budget ratios and rework, plus GREEN output tokens per changed line and its
passing-test count.
The Stop hook's terminal-phase pointer is intended to appear once (`AD` full,
`TEET` demo), not on every turn. Close a wave manually with `scripts/wave-close.sh`;
solo has no terminal phase. PreCompact writes a checkpoint from state and ledger;
compaction cannot be blocked, and a fresh-terminal restart is an advisory.

**Responding to a deny.** A reason has the form `[W-RULE] <observed problem>;
remedy: <next action>`. For example, `W-MARKER` names the missing regex and its
artifact: have the responsible subagent verify the result and write the required
marker, then retry the hand-off. Do not invent passing evidence to satisfy a
marker. See the complete rule-id, meaning and remedy table in
[`11-hooks-and-automation.md`](../../framework/references/11-hooks-and-automation.md).
Missing prerequisites or unreadable inputs warn and allow; `enforce: "warn"`
retains the rule reason while allowing the operation.
