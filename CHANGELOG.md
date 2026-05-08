# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
