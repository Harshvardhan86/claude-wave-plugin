# claude-wave-plugin

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://github.com/Harshvardhan86/claude-wave-plugin/blob/main/LICENSE) [![Version](https://img.shields.io/badge/version-0.1.0-blue.svg)](https://github.com/Harshvardhan86/claude-wave-plugin/blob/main/CHANGELOG.md) [![Claude Code Plugin](https://img.shields.io/badge/Claude_Code-plugin-7C3AED.svg)](https://docs.claude.com/en/docs/claude-code/plugins) [![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](https://github.com/Harshvardhan86/claude-wave-plugin/blob/main/CONTRIBUTING.md)

> Run Claude Code like an engineering org. Wave-based execution with dedicated sub-agents per phase, computed-style visual verification, no "tsc passes" lies.

![A complete wave run — 17 phases, 4h 56m, 483.2k tokens, all checks green](assets/wave-run-output.png)

*A real `/wave-start` run end-to-end: 17 phases dispatched through dedicated sub-agents, TDD-RED → GREEN → visual gates → cleanup → checkpoint. Unattended.*

The defaults of "vibe-coding" optimise for *time-to-first-demo*. This plugin optimises for *time-to-shippable*.

---

## Table of contents

- [How is this different?](#how-is-this-different)
- [Why this exists](#why-this-exists)
- [Prerequisites](#prerequisites)
- [Install](#install)
- [Quickstart — your first wave](#quickstart--your-first-wave)
- [What you get](#what-you-get)
- [The 10 invariants](#the-10-invariants-verbatim-from-v1-preserved-in-v2)
- [The 5 hard-won rules](#the-5-hard-won-rules-the-demo-skills-add-on-top)
- [Repository structure](#repository-structure)
- [Community](#community)
- [Used in production by](#used-in-production-by)
- [Talks & writing](#talks--writing)
- [Status](#status)
- [Contributing](#contributing)
- [License](#license)

---

## How is this different?

|                              | claude-wave-plugin           | Superpowers              | Vanilla Claude Code |
|------------------------------|------------------------------|--------------------------|---------------------|
| Workflow philosophy          | Evidence-first verification  | Brainstorm → plan → execute | One-shot prompts |
| Phases per feature           | 17 base + 2 conditional      | 7 stages                 | None                |
| TDD enforcement              | Hook-enforced                | Recommended              | None                |
| Visual verification gates    | ✅ Computed-style assertions | ❌                       | ❌                  |
| Sub-agent isolation          | ✅ Per-phase, lean context   | ✅                       | ❌                  |
| Auto-compact recovery        | ✅ Checkpoint resume          | ❌                       | ❌                  |
| Best for                     | Production codebases where bugs cost money | Greenfield features, creative flow | Prototypes |

Both `claude-wave-plugin` and Superpowers are serious frameworks built by people shipping real code with Claude Code. They optimise for different problems. If you're brainstorming a new product feature, Superpowers' creative flow is excellent. If you're shipping into a production codebase where "the agent said it's done" is not acceptable evidence, this plugin is for you.

## Why this exists

Most Claude Code workflows are one-shot: type a prompt, get a diff, ship it. That works for prototypes. It produces piles of fake-done features in production codebases — features whose tests pass but whose pages render blank, whose configs validate but whose runtime never reads them, whose `data-theme="dark"` attribute gets set on `<html>` while the screenshot stays light.

Wave-based execution treats Claude Code as an **orchestration layer**, not an autocomplete. Every phase of shipping a feature gets its own dedicated sub-agent with lean context — and the orchestrator gates each hand-off on real evidence (live stack screenshots, computed-style assertions, true end-to-end runs), not on "build clean".

This plugin packages that workflow.

## Prerequisites

- **Claude Code** installed and authenticated. See the [official docs](https://docs.claude.com/en/docs/claude-code/overview).
- A project to run waves against (any language / stack).
- For UI waves: a browser-driving setup such as Playwright. The framework's TEET phase uses Playwright via the official MCP.
- Optional but recommended: the [CodeRabbit plugin](https://www.coderabbit.ai/) if you want the `[CR]` Code Review gate at Phase 3.5.

## Install

```bash
# Add this repo as a plugin source
/plugins marketplace add https://github.com/Harshvardhan86/claude-wave-plugin

# Then install the plugin
/plugins install claude-wave-plugin
```

After installation you should see two new slash commands available:

- `/wave-start`
- `/wave-checkpoint`

…and six skills registered: `wave-orchestrator`, `ac-writer`, `design-reviewer`, `red-tests`, `green-impl`, `teet-verify`.

### Manual install (no marketplace)

If you'd rather install directly:

```bash
git clone https://github.com/Harshvardhan86/claude-wave-plugin.git \
  ~/.claude/plugins/local/claude-wave-plugin
```

Restart Claude Code. The plugin should be picked up automatically.

## Quickstart — your first wave

In any project you want to ship a feature in:

```bash
/wave-start --demo "make the save button show a loading spinner"
```

What you'll see:

1. The orchestrator dispatches the **AC** sub-agent. `.wave/ac.md` lands with brutal, testable criteria.
2. **DR** sub-agent audits your design system's installed dist files, writes a per-route mockup, defines computed-style visual ACs. Any design-system gap becomes an OPEN item that pauses the wave.
3. **RED** writes failing tests against those ACs and prints the failure output. *That's the point.*
4. **GREEN** writes the minimum code, starts the live stack, runs the full test suite, takes a Playwright screenshot.
5. **Visual approval gate.** The orchestrator stops, shows you the screenshot, asks you to confirm before proceeding.
6. **TEET** runs cross-system computed-style assertions and produces the final verdict.

If the agent says "done" without showing you a screenshot, refuse the hand-off — that's the failure mode the plugin exists to prevent.

Once you've shipped two or three waves with `--demo` successfully, drop the flag:

```bash
/wave-start "implement the new payment flow"
```

This invokes the canonical pipeline: 17 base phases plus `[DR]` (auto-engaged for UI waves) and optional `[CR]` (opt-in via `cr_enabled`). Brutal AC, Silent Error Analysis, Brutal SEA, Dependency Audit, Output Alignment, Brutalised E2E, version bump, commit, cleanup, checkpoint, dashboard — all dispatched as separate Agents with proper Opus / Sonnet / Haiku model routing.

If context fills before completion, `/wave-checkpoint` writes resume state to `.wave/checkpoints/`. A fresh session picks up exactly where you left off.

## What you get

### The full v2 framework (`framework/`)

This plugin **vendors the complete Wave Execution Framework v2** — refined over months of production engineering work where bugs cost real money. 17 base phases plus two conditional gates: `[DR]` Design Review at Phase 1.5 (mandatory whenever the wave ships UI — web, mobile, Storybook, CLI-TUI) and `[CR]` Code Review at Phase 3.5 (optional, opt-in). Maximum surface per wave: 19 phases. Model-routed across Opus / Sonnet / Haiku, with hook-enforced invariants and worktree isolation for writing dispatches.

### Demo on-ramps (`skills/`)

For first-time users, small features, and live-demo segments, the plugin ships **five polished entry skills** plus the orchestrator:

| Skill | Phase | Owns |
| --- | --- | --- |
| `wave-orchestrator` | Router | Mode dispatch (`full` vs `demo`), hand-off gates |
| `ac-writer` | 1. Acceptance Criteria | Brutal, testable ACs grounded in real visual vocabulary |
| `design-reviewer` | UI: pre-RED gate (matches Phase 1.5) | Component API audit, per-route mockup, visual ACs |
| `red-tests` | RED | Failing tests *first*, prove they fail before any code is written |
| `green-impl` | GREEN | Minimum implementation, verify-before-scan: live stack + tests + screenshot |
| `teet-verify` | TEET | True end-to-end with computed-style assertions, not `toBeVisible()` lies |

These run as `/wave-start --demo "<feature>"`. The recommended starting point.

### Commands (`commands/`)

- `/wave-start <feature>` — runs the full v2 pipeline (17 base + conditional `[DR]` and `[CR]` gates)
- `/wave-start --demo <feature>` — runs the trimmed 5-phase entry subset
- `/wave-checkpoint` — saves wave state to disk so an auto-compact (or laptop battery dying) doesn't kill the run

## The 10 invariants (verbatim from v1, preserved in v2)

1. Lean context per unit — no "just in case" dumps.
2. Strict TDD — tests first, watch them fail, then implement.
3. Strict build order — build → app startup → tests.
4. Never assume on bugs — present **options**, user decides.
5. Save learnings globally after every bug fix (no duplicates, enhance existing).
6. Planning docs never committed to the code repo.
7. Auto-compact = STOP. Fresh terminal. Resume from checkpoint.
8. No team self-declares success — internal reviewer signs off first.
9. No hanging the system — teams must not deadlock or block indefinitely.
10. The orchestrator is the single throat to choke — all decisions and user interactions flow through it.

Invariants 6 and 7 are hook-enforced in v2; see [`framework/references/11-hooks-and-automation.md`](https://github.com/Harshvardhan86/claude-wave-plugin/blob/main/framework/references/11-hooks-and-automation.md).

## The 5 hard-won rules the demo skills add on top

These complement the invariants for UI work specifically:

1. **Verify before scan.** Never run BC/SEA/BSEA scanners on un-verified GREEN. Live stack + full test suite + screenshot first; *then* scan.
2. **Visual effect over DOM presence.** `toBeVisible()` returns true for a 0×0 element. Assert `getComputedStyle().backgroundColor`, `boundingBox` dimensions, and effective CSS bytes.
3. **Visual vocabulary grounding.** Never invent a color or token the app doesn't already render. Audit compiled CSS, not theoretical class names.
4. **Never implement without wiring.** Trace config → runner → handler end-to-end. A "catalog without dispatch" is a lie.
5. **Permissions once, upfront.** Ask for all permissions in a single consolidated request at session start. Never again.

Each rule was learned from a specific incident, not from a blog post.

## Repository structure

```
claude-wave-plugin/
├── .claude-plugin/
│   └── plugin.json                              # plugin manifest
├── README.md                                    # you are here
├── LICENSE                                      # MIT
├── CHANGELOG.md                                 # release history
├── CONTRIBUTING.md                              # PR / issue norms
├── .gitignore
│
├── framework/                                   # full Wave Execution Framework v2
│   ├── SKILL.md                                 # canonical pipeline + 10 invariants
│   └── references/                              # 12 load-on-demand reference docs
│       ├── 01-architecture.md
│       ├── 02-standing-teams.md
│       ├── 03-wave-pipeline.md
│       ├── 04-meta-orchestration.md
│       ├── 05-language-binding-rules.md
│       ├── 06-team-quick-reference.md
│       ├── 07-invariant-rules.md
│       ├── 08-worktree-strategy.md
│       ├── 09-platform-deltas.md
│       ├── 10-model-routing.md
│       ├── 11-hooks-and-automation.md
│       └── 12-mcp-and-plugins.md
│
├── skills/                                      # demo on-ramps + orchestrator
│   ├── wave-orchestrator/SKILL.md
│   ├── ac-writer/SKILL.md
│   ├── design-reviewer/SKILL.md
│   ├── red-tests/SKILL.md
│   ├── green-impl/SKILL.md
│   └── teet-verify/SKILL.md
│
├── commands/
│   ├── wave-start.md                            # /wave-start [--demo] "<feature>"
│   └── wave-checkpoint.md                       # /wave-checkpoint
│
└── scripts/
    └── qr.html                                  # parametric QR-code generator
```

## Community

- **X / Twitter:** [@Anim1986](https://x.com/Anim1986) — DM open for questions, suggestions, war stories
- **Issues & ideas:** Open an issue with the `.wave/<phase>.md` excerpt that surfaced the question
- **Discussions:** [GitHub Discussions](https://github.com/Harshvardhan86/claude-wave-plugin/discussions) for design questions and patterns

## Used in production by

This plugin is in early public release. If you're shipping with `claude-wave-plugin` in a real engineering org, [open an issue](https://github.com/Harshvardhan86/claude-wave-plugin/issues/new) or DM [@Anim1986](https://x.com/Anim1986) — I'll add your team here and would love to hear what's working, what's not, and what's missing.

## Talks & writing

- 🎤 **[Beyond Vibe Coding — Claude Builders Delhi NCR, May 2026](https://www.linkedin.com/posts/harshvardhan-chouhan_claude-delhi-event-recap-ugcPost-7459117381680881664-tJ1q)** — the talk that introduced this framework. Recap with photos and the core thesis.
- ✍️ *Coming soon:* TDD with sub-agents — the patterns from `claude-wave`. Acceptance criteria, evidence-first verification, brutal silent-error scans.

## Status

**v0.1.0** — initial public release. The framework itself is battle-tested in private production work; this is its first public packaging. Expect rough edges around platform integration as Claude Code's plugin system evolves. Issues and PRs are welcome.

## Contributing

See [CONTRIBUTING.md](https://github.com/Harshvardhan86/claude-wave-plugin/blob/main/CONTRIBUTING.md). Short version:

- Bug reports and rule clarifications: open an issue with the `.wave/<phase>.md` excerpt that surfaced the problem
- New rules to the framework: come with a real incident behind them
- Skill changes: include a before/after showing the new guidance in action

## Author

**Harshvardhan Singh Chouhan**

- X: [@Anim1986](https://x.com/Anim1986)
- LinkedIn: [harshvardhan-chouhan](https://www.linkedin.com/in/harshvardhan-chouhan)
- Email: harshvardhanc.1986@gmail.com / proharsh@gmail.com

## License

[MIT](https://github.com/Harshvardhan86/claude-wave-plugin/blob/main/LICENSE) — fork it, ship it, mutate it.
