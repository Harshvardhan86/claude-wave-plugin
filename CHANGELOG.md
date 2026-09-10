# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.0] — 2026-09-10

### Added

- Hook enforcement for active waves: tagged dispatch, explicit models and minimum
  tiers, phase order, scope, artifact markers and approval gates.
- Orchestrator-only edit/read/build restrictions, nested/fork dispatch guards,
  lean-context and return checks, and phase/role round ceilings.
- TSV rule data for phases, models, roles, budgets, writable paths, planning paths
  and reason templates with actionable remedies.
- Full and demo enforcement plus solo mode, which keeps explicit models, the
  commit guard, PreCompact checkpoint and token ledger without process gates.
- Append-only token ledger, output-budget gates and a scorecard covering model
  resolution, phase spend, rework and GREEN output per changed line.
- Automatic PreCompact checkpoints, session restart advisories, wave lifecycle
  scripts and a repo-local commit-message guard installed only when absent.
- Test gates: `bash tests/run.sh`, `bash tests/run.sh --coverage`,
  `bash tests/clean-clone-check.sh` and `bash tests/e2e.sh`, with focused
  `tests/tools/mutants-*.sh` mutation drivers and real plugin-load verification.

### Changed

- Plugin and marketplace descriptions now describe hook enforcement; version is
  `0.2.0`, with no manifest `hooks` field because hook registration is automatic.
- Orchestrator documentation now includes the enforced tag, artifacts, approvals,
  modes, accounting and recovery contract.
- `.wave/` recovery data uses `.git/info/exclude`; `/wave-checkpoint` documents
  the manual counterpart to automatic PreCompact checkpoints.
- `enforce: "warn"` provides an event-hook escape hatch with the same rule ids;
  planning-document exceptions use `.wave/approvals/commit-doc.md`.

### Fixed

- Replaced the hook reference's unsupported syntax with the real event/matcher/
  command schema, stdin fields, deny/context responses, verification and rollback.
- Clarified that PreCompact enforces checkpoint writing but cannot block compaction.
- Documented transitive predecessor checks through skipped conditional rows and
  solo's exemption from prompt caps, ordering, tiers and orchestrator-only rules.
- Clarified enforcement limits: marker checks require evidence review, Bash source
  writes are not edit-gated, and the build/test filter does not interpret shell indirection.

## [0.1.0] — 2026-05-08

Initial public release.

### Added

- **Vendored Wave Execution Framework v2** under `framework/`:
  - `SKILL.md` — 17 base phases plus conditional `[DR]` Design Review (Phase 1.5, mandatory for UI waves) and optional `[CR]` Code Review (Phase 3.5). Maximum surface per wave: 19 phases. Includes the 10 invariants (verbatim from v1).
  - 12 reference docs (`references/`) covering: architecture, standing teams, full wave pipeline, meta-orchestration, language-binding rules, team quick-reference, invariant rules, worktree strategy, platform deltas, model routing, hooks/automation, and MCP/plugins integration.
- **Six demo on-ramp skills** under `skills/`:
  - `wave-orchestrator` — mode router between full framework and `--demo` subset, hand-off gate enforcement
  - `ac-writer` — brutal acceptance criteria with visual vocabulary grounding
  - `design-reviewer` — component API audit, per-route mockup, computed-style visual ACs (matches Phase 1.5 of the framework)
  - `red-tests` — TDD RED phase with banned-assertion list
  - `green-impl` — minimum implementation with verify-before-scan (live stack + screenshot)
  - `teet-verify` — true end-to-end testing with computed-style assertions
- **Two slash commands** under `commands/`:
  - `/wave-start [--demo] <feature>` — kicks off a wave in full or demo mode
  - `/wave-checkpoint` — saves wave state to disk for auto-compact recovery
- **Parametric QR generator** (`scripts/qr.html`) for sharing the install URL.
