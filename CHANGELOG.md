# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.3.0] — 2026-10-27

### Added

- **`[UIA]` user-intent criteria (Phase 0.5),** on waves that answer `vocabulary`
  true. One block per criterion in the user's voice — "As a *role*, when I
  *action* against *data state*, I expect *observable outcome*" — each naming one
  of three pinned data states. `[AC]` receives them and every `UIA-n` must be
  covered by at least one `AC-n`. Artifact `.wave/uia.md`, marker `^UIA-[0-9]+`.
- **`[BEN]` the benefit contract (Phase 0.8),** on waves that answer
  `behaviour-change` true. Three artifacts before any criteria are written: one
  Benefit AC that names no symbol the wave introduces and whose subject is not the
  new component, backed by a named failing test; an authority census listing every
  existing component that already decides the same outcome, read from code; and an
  integration count with the sign inverted, where 0 or 1 file changed outside the
  feature's own directory is a finding that needs a written justification.
  Artifact `.wave/ben.md`, marker `BEN-VERIFIED red=<n> authorities=<n>`, both ≥ 1.
- **`[ES]` empty-state scan (Phase 4.2) and `[BF-ES]` (Phase 4.3),** on waves that
  answer `vocabulary` true. `[ES]` reads the data-state matrix and reports any
  element whose visibility, presence or rendering depends on a count being
  non-zero, with file and line. `[BF-ES]` runs on findings and needs
  `.wave/approvals/bf-ES.md` like every other bug-fix row.
- **`[BEN-CLOSE]` the benefit verdict (Phase 12.5),** after the last hardening
  phase and before the version bump, on waves where `[BEN]` ran. A separate team
  re-runs the named benefit test, sweeps for orphan state (new classes, tables,
  flags or states with no production reader outside the feature's own directory),
  lists any statement in the wave's own notes that the existing system undoes the
  feature, and writes `BENEFIT: DELIVERED` or `BENEFIT: UNDELIVERED` with reasons.
- **The `vocabulary` scope flag,** asked as: does this wave introduce a new kind of
  record, or a new value of an existing classification (a status, a category, a
  role), that a user will see? `wave-init.sh` gains `--vocabulary` /
  `--no-vocabulary` and `--behaviour-change` / `--no-behaviour-change`;
  `wave-set.sh` gains the `vocabulary` key.
- **A delivery verdict and `W-UNDELIVERED`.** `wave-close.sh` records `delivery`
  — `delivered`, `undelivered`, `unverified` or `not-applicable` — in the same
  write that closes the wave, read from the first verdict line of
  `.wave/ben-close.md`; nothing unanswered or missing reads as a pass, and the
  verdict is `not-applicable` in solo and in any mode `BEN` does not run in
  (demo). `W-UNDELIVERED` is emitted once, at the close, for `undelivered` and
  `unverified`, always in the same call as a scorecard pointer; it never blocks
  the close. `scripts/wave-scorecard.sh` prints a `## Delivery` section under its
  title whenever a verdict was recorded, including on a wave with an empty
  ledger, and caps each quoted reason line at 200 characters.
- **A data-state matrix on acceptance criteria.** Every criterion that asserts on a
  user-visible surface carries a `**Data states:**` line and must hold in three
  pinned states: empty (no records at all), partial (only records that existed
  before the wave — what every installation looks like on deploy day) and full
  (records in every value the wave introduces). `[ACB]` rejects criteria
  conditional on data being present unless they also state the absent-data outcome.
- **A `benefit-contract` entry skill,** teaching the Benefit AC, the authority
  census, the inverted integration count and the close-time sweeps.
- **The `done:<CODE>` condition keyword** (met when that row is done) and a closed
  condition vocabulary pinned by a data test: `always`, `ui|behaviour_change`,
  `cr`, `vocabulary`, `behaviour_change`, `findings:<scanner>`, `done:<row>`.
- **`wave-close.sh --if-complete`.** `--if-terminal <PHASE>` remains an accepted
  alias with the same meaning and its argument ignored.
- **`W-STATE` on a complete wave that is not closed.** In full and demo mode a
  Stop on such a wave refreshes the leftover inventory and prints only `W-STATE`
  naming `scripts/wave-close.sh`, on every Stop until the wave is closed.
- **Test harness: several rule ids from one call.** `expect.rules` asserts the
  exact ordered list of rule ids in a stdout reason; `expect.stderr_rules` does
  the same on stderr, where the closing SubagentStop writes its close-time
  warnings. A case declares exactly one of `rule`, `rules` and `stderr_rules`
  (by key presence), and `tests/tools/reason-corpus.sh` drives every listed id.
- **Test harness: scratch hygiene.** A green run removes its scratch directory;
  a failed run, or `WV_KEEP_TMP=1`, keeps it and prints its path. Cases register
  cleanups with `wv_on_exit` instead of an EXIT trap, and the mutation drivers
  keep their scratch inside their own temporary root.

### Changed

- **A full-mode wave answers two scope questions before its first dispatch.** `AC`
  now names `UIA` and `BEN` as predecessors, and an unanswered flag on a
  predecessor denies the successor, so `vocabulary` and `behaviour-change` must be
  answered before any phase can be dispatched. `ui` and `cr` may still wait until
  `TDE-RED`. `/wave-start` asks the first two before `wave-init.sh` runs. This
  withdraws the 0.2.x statement that earlier phases stay dispatchable while scope
  is unanswered. Demo mode is unaffected; solo mode consults no phase table.
- **A wave closes when it is complete,** meaning every `when=phase` row of the
  active mode is done, or skipped by mode or by a condition answered false. An
  unanswered condition is not settled; neither is a done scan whose findings
  file is missing or cannot be measured, nor a `failed`, `artifact-missing` or
  `redo` row. `anytime` rows never count, and only a `when=phase` row's stop
  triggers the close, so an `AD` stop never closes a wave. Full mode closes when
  `VB`, `COMMIT`, `CL` and `CCP` are done; demo closes on `TEET`, as before; solo
  never closes automatically.
- **Only the closing SubagentStop closes and announces.** After it reads the
  state back as `closed` it emits, in this order, `W-LEFTOVER` (leftovers found
  and not warned before; it names the scorecard), `W-UNDELIVERED` (when the
  verdict calls for it) and `W-SCORECARD` (unless `W-LEFTOVER` already pointed
  there; forced whenever a verdict was queued). Each fires at most once per wave
  and its marker is written after it is queued. A failed close gets `W-STATE`
  alone, marks nothing, and the next closing stop retries. A Stop never closes a
  wave, and in full and demo mode no longer prints `W-LEFTOVER` or
  `W-SCORECARD`; solo keeps its ledger-based pointer through the same
  composition.
- **The leftover inventory follows the final rows.** A closing-role stop of a
  final row (full `VB`, `COMMIT`, `CL`, `CCP`; demo `TEET`, derived from
  `hooks/phases.tsv`) whose other rows are settled takes the inventory whatever
  its outcome, so a wave that ends on a failed final row still warns once.
- **`wave-close.sh` decides under the wave lock.** Both forms re-read the state
  once they hold the lock, check it is the same active wave (id and start time)
  they first saw, and decide completeness and the verdict there. A wave that
  changed or closed while they waited is not closed: `--if-complete` exits 0
  silently, and the bare form says what changed and exits 1 — check
  `.wave/state.json` and re-run. The usage text says so.
- **One attribution-trailer pattern.** The commit guard and the `commit-msg`
  hook installed by `wave-init.sh` both read `WV_TRAILER_ERE` from
  `scripts/hooks/lib.sh` and refuse the same five forms; the installed hook
  previously let a session line and a vendor-domain co-author line through, and
  the guard missed the latter. The installed hook now carries a versioned owned
  marker line, and `wave-init.sh` regenerates a hook that has it (state
  `upgraded`). The unmarked hook 0.2.x wrote is recognised by its full content
  and upgraded the same way while it is unmodified; any other hook, including
  a 0.2.x hook with a local change, is left untouched and the notice gives the
  refresh path: delete it and re-run `scripts/wave-init.sh`.
- **Generic prose.** Documentation, comments and messages no longer name a
  vendor, a model or a specific host product; protocol keys, environment names
  and the model-tier routing words are unchanged.
- **Renamed the plugin to `wave-orchestrator`:** the host validator reserves
  a name prefix. The marketplace entry is renamed too:
  remove the old marketplace entry, add it again, uninstall the old name and
  install `wave-orchestrator`. The repository URL is unchanged for now. The
  unrecognised `contributors` manifest field was removed.
- **Design Review is described as what the table has always enforced:** `[DR]` runs
  when the wave ships UI **or** changes existing behaviour. Sixteen documents still
  said "UI waves only"; all are corrected except the historical 0.1.0 entry below.
- The phase table now has 31 rows and 93 tier cells. 18 rows run in every full-mode
  wave; 7 are the `[BF-*]` rows that run only on findings; 6 depend on the wave's
  scope answers or on whether `[BEN]` ran. Maximum surface per wave: 31 phases.
- The reasons table now contains 38 rules.
- The advisory prompt reminder no longer contradicts the gate: a row whose
  condition is unanswered is reported as required and not yet allowed, never as
  skipped.
- A `findings:` or `done:` row whose source row does not run in this wave reports
  its condition unmet instead of waiting for a scan that will never happen.

### Fixed

- **Since 0.2.0, the first dashboard stop closed a full-mode wave.** The terminal
  phase was derived as the last table row of the mode, which in full mode is `AD` —
  an `anytime` row with no artifact, exempt from the order gate. The first time a
  dashboard executor stopped, the wave was closed whatever else had or had not run,
  and every hook was silent for the rest of that wave's work. Wave completion
  replaces the terminal-phase derivation, and `anytime` rows never count towards it.
- **The once-per-wave scorecard pointer could not fire in full or demo mode.** The
  Stop hook printed it when the wave was active and its terminal phase was done,
  but the call that recorded the terminal phase as done closed the wave in the same
  breath, so outside a blocked stop the two conditions were never true together.
  The fixtures that exercised the pointer seeded a state the engine could not
  durably produce. The closing `SubagentStop` now emits the pointer itself, once
  per wave, after it has confirmed the close.
- **Since 0.2.0, `wave-init.sh` in a linked worktree wrote its hook and exclude where git never reads them.** Each `git rev-parse --git-path` result is now used as is when absolute and joined onto the project root only when relative, so the `commit-msg` hook and the `.wave/` exclude land in the repository's common directory.
- **Since 0.2.0, `wave-init.sh` wrote into a project's `core.hooksPath` directory.** With `core.hooksPath` set (to any value, an empty one included) it now writes nothing there (state `skipped-hookspath`), renders the check to `.wave/hooks/commit-msg`, and prints a shell-quoted command to call it from the project's own hook manager; the in-session commit guard still applies.
- **`wave-init.sh` recorded the `commit-msg` hook as installed in a directory that is not a git repository, or in a bare one.** It now writes no hook or check there and nothing under a bare repository's git directory (no `info/exclude` line either; only the wave's own `.wave/` state is created), records `not-a-repo`, and says the guard was not installed because there is no work-tree repository; the in-session commit guard still applies.
- **`wave-init.sh` reported the `commit-msg` hook installed when writing it had failed.** It now records `installed` or `upgraded` only when the file at the hook path is byte-identical to the intended template: the hook is rendered into a temp file with every command's status checked, compared with an independently rendered reference copy and syntax-checked, then moved into place and compared once more. Otherwise the state is `install-failed`, the notice names the failed step, and the check is saved to `.wave/hooks/commit-msg` instead, verified the same way; whether that check was saved is recorded in a new additive state field `commit_msg_check` (`written`, `failed`, or `none` when no check was needed).

### Upgrade notes

- The state schema stays at 1. There is no migration and no hook goes silent.
- `wave-init.sh` writes an additive `created_by` field, the plugin version that
  created the wave; a state without it was created before 0.3.0, and
  `wave-set.sh` never changes it.
- A flag absent from an existing `state.json` reads as the empty string, which is
  neither `true` nor `unknown`, so it behaves as false — this is how the engine has
  always treated an absent field. `vocabulary` is absent in every 0.2.x state file,
  so `[UIA]` and `[ES]` are skipped on waves already in flight.
- For a wave in flight whose `AC` is not yet done: `behaviour_change` was always
  written `unknown` by 0.2.x, so `AC` is now denied `W-SCOPE` until it is answered.
  Answer it with `scripts/wave-set.sh behaviour-change true|false`. If the answer is
  `true`, `BEN` is required before `AC` and `BEN-CLOSE` before the tail.
- For a wave in flight whose `AC` is already done: `BEN` is not required (the gate,
  wave completion and the reminder share one legacy test, `wv_row_superseded`: no
  `vocabulary` key in `state.json`, no `BEN` entry in `phases`, and `AC` done),
  `BEN-CLOSE` is skipped, and the tail is unchanged. The closing stop closes the
  wave; if `behaviour_change` is `true` the verdict is `unverified`, said once.
- A 0.3.0 wave whose `behaviour_change` becomes `true` after `AC` still owes `BEN`:
  `BEN` stays dispatchable, and `BEN-CLOSE`, `COMMIT` and the rest of the tail are
  refused `W-ORDER` naming `BEN` until it has run.
- Bare `scripts/wave-close.sh` is the supported way to close any wave by hand; it
  records the honest verdict. Never change `behaviour_change` to get a wave closed.
- A wave whose dashboard has not yet been dispatched no longer closes when it is. A
  wave already closed that way stays closed.
- A wave that is complete but still open (its closing stop was blocked or its
  close failed) is reported by every Stop; close it with `scripts/wave-close.sh`.
- New waves: `/wave-start` asks four scope questions. A wave driven by hand must
  answer `vocabulary` and `behaviour-change` before `AC` (the gate reads each
  flag at the row that needs it: `UIA` needs only `vocabulary`).
- Solo mode is unchanged. Demo mode keeps the same five phases and the same gates.
- Anything that parsed "`AD` closes the wave" out of the 0.2.x specification must
  use wave completion instead.
## [Unreleased] (published main, documentation only)

### Changed

- Documentation now shows plugin commands with the plugin prefix, as the host lists them:
  `/wave-orchestrator:wave-start` and `/wave-orchestrator:wave-checkpoint`.
  Behaviour is unchanged.


## [0.2.1] — 2026-09-12

### Added

- **W-BGWAIT:** a full/demo subagent returning with recorded background Bash work
  still running is blocked once; a later latched stop records orphans and fails
  the phase. Wait with a bounded foreground command or stop the task before returning.
- **W-POLL:** full/demo Bash denies lexical `while true` / `while :` loops and
  `until` loops with sleep unless an anchored positive literal timeout wraps
  them, plus bare sleeps over 300 seconds after unit conversion; subagents cannot use Monitor. Bound the wait with a positive
  timeout, shorten the sleep, or leave monitoring to the main session.
- **W-LEFTOVER:** wave completion warns at most once per wave about remaining tasks,
  crons and watcher processes; later Stops refresh inventory without repeating
  the warning; checkpoints and scorecards include the inventory and spared pids.
  PreCompact also inventories, warning only on watcher evidence or scan failure.
  Inspect the inventory and finish or stop named work; hooks never kill processes.

### Changed

- Stop hook timeout is 20 seconds; PostToolUse Bash and PreToolUse Monitor hooks
  are registered automatically.
- The reasons table now contains 37 rules.

### Notes

- Poll detection is lexical: shell `-c` arguments are inspected through depth 3,
  other quoted spans are stripped, and variables and aliases are not resolved.
  Heredoc text can trigger a lexical match; a positive literal timeout proves
  a bound, while `timeout 0` and `timeout $N` do not.

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
- A wave id is 1–24 characters of `[A-Za-z0-9._-]`, refused at `/wave-start`: the id
  is interpolated twice into the session banner, whose rendered length is bounded, so
  the bound belongs where there is one writer and a person to read the refusal.
- A bounded settle before `SubagentStop` reads an agent transcript: up to 12 samples
  200 ms apart, waiting for the client to finish writing, paid only by a transcript
  that has not settled. A transcript still incomplete after that is used anyway, and
  its ledger line is marked `transcript_incomplete` rather than silently carrying an
  unconfirmed token sum and tier.
- Test gates: `bash tests/run.sh`, `bash tests/run.sh --coverage`,
  `bash tests/clean-clone-check.sh` and `bash tests/e2e.sh`, with focused
  `tests/tools/mutants-*.sh` mutation drivers and real plugin-load verification.
- `bash tests/tools/mutants-all.sh` as a release gate: it runs every mutation driver
  under `tests/tools/` and fails on any surviving mutant or failed restore, because a
  green suite over a rule no mutant can break has proved nothing about that rule.
- `bash tests/tools/reason-corpus.sh` as a release gate: it drives every rule id in
  `hooks/reasons.tsv` to its positive case and checks the message a user actually
  reads — one rule token, a remedy, a bounded length, no unrendered placeholder, and
  template arity matching every call site.
- `bash tests/tools/reason-corpus.sh --replay-enforce` as a release gate: the whole
  deny/block corpus replayed twice, once under `enforce: "block"` and once under
  `enforce: "warn"`, so warn mode is proved to report the same rule ids it would have
  blocked on — an inverse control for every rule, not a sample of them.
- `WV_PINNED_NOW=<instant> bash tests/run.sh --coverage` as a release gate: every case
  reads the clock through one injectable source, so moving that pin to any instant
  must leave the suite green. A case whose assertion depends on wall-clock distance
  reds there, months before the calendar would find it and with a commit to blame.

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
