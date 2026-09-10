# Hook enforcement layer — design (v0.2.0)

Status: approved for implementation 2026-09-09; revised the same day after design
review. Scope: add a hooks layer that enforces what v0.1.0 only described in
prose. Existing skills, commands and reference docs keep their semantics; the
only behavioural change for a user is that a wave which breaks the rules is now
stopped by the harness instead of by good intentions.

Sections 1–13 are the design. §14 lists every design-review finding and what it
changed. §15 lists the handful of decisions where a reasonable person could
choose differently.

## 1. Problem

v0.1.0 ships zero hooks. `plugin.json` has no `hooks` entry and there is no
`hooks/` directory. Four things the README and the framework claim are
"enforced" are in fact only requested in prompts:

1. Phase order and hand-off artifacts (the 17-phase pipeline, the demo subset).
2. Model routing per phase and role (the Opus / Sonnet / Haiku table).
3. Model fit for the work at hand: the orchestrator must dispatch, never
   implement, and every dispatch must name its model explicitly.
4. Token spend versus delivered quality: nothing is measured, so nothing can
   be budgeted, compared or blocked.

`framework/references/11-hooks-and-automation.md` also documents a hook syntax
(`"if"`, `"decision": "block-on-nonzero"`, `claude invoke-agent`, `TaskCreated`
handlers with `${task.id}`) that Claude Code does not have. It is replaced by the
real schema in this change.

## 2. Verified platform facts (Claude Code 2.1.266, probed 2026-09-09)

These were measured with a throwaway probe plugin in headless sessions, not
taken from memory. The design depends on every one of them. Raw probe logs are
kept outside this repo with the wave's analysis documents.

| Event | What the hook receives on stdin |
|---|---|
| `PreToolUse` (`tool_name: "Agent"`) | `tool_input.description`, `tool_input.prompt`, `tool_input.subagent_type`, `tool_input.model` (absent when the caller omitted it), `tool_input.isolation` and `tool_input.run_in_background` when set, `tool_use_id`, `cwd`, `transcript_path`, `permission_mode`, `session_id`. Calls made **inside** a subagent additionally carry `agent_id` and `agent_type`; calls from the main session carry neither. |
| `PostToolUse` (`Agent`) | Same `tool_input` plus `tool_response` (`status: "async_launched"` for an async launch, `agentId`, `resolvedModel` — a full model id such as `claude-haiku-4-5-20251001`), `tool_use_id`, `duration_ms`. Fires at **launch**, not completion, for async dispatches. |
| `SubagentStop` | `agent_id`, `agent_type`, `agent_transcript_path`, `last_assistant_message`, `stop_hook_active`, `background_tasks` (which reports the agent as `running` even at its own stop — never read it as completion). |
| `PreCompact` | `trigger` (`manual` / `auto`), `cwd`, `transcript_path`. |
| any | env `CLAUDE_PLUGIN_ROOT`, `CLAUDE_PROJECT_DIR`. |

`SubagentStart` carries only `agent_id` and `agent_type` — no `tool_use_id`, no
`description` — so it cannot be joined to a dispatch on its own, and it fires
in the same second as `PostToolUse` with no guaranteed order. It is not used.
The join chain is three events:

```
PreToolUse.tool_use_id → PostToolUse.tool_response.agentId → SubagentStop.agent_id
```

`tool_response` is read **tolerantly**: it may arrive as a JSON object or as a
JSON-encoded string. Scripts try `.tool_response.resolvedModel`, then a
`fromjson?` decode, then `command grep -o '"resolvedModel":"[^"]*"'` over the
raw text. A `resolvedModel` that cannot be read is recorded as `unknown` and
warned about (`W-RESOLVE-UNKNOWN`); it is **never** treated as a violation.
`outputFile` is never read; completion is only ever observed at `SubagentStop`.

Subagent transcript: the path is handed to the hook as `agent_transcript_path`
and lives under the account's `projects/<slugged-cwd>/<session>/subagents/`,
**not** under the project. Never construct it; if the field is absent, skip the
ledger's token sum with `note: "no transcript"` and do not fail. Every
`assistant` line carries `message.model` and `message.usage`
(`input_tokens`, `output_tokens`, `cache_creation_input_tokens`,
`cache_read_input_tokens`).

Worktree-isolated subagents (measured): `cwd` becomes
`<project>/.claude/worktrees/agent-<agent_id>`, while `CLAUDE_PROJECT_DIR` in
the hook environment stays the **main** project directory. Hooks therefore do
fire inside worktree subagents and can read the main project's `.wave/`.

Blocking: `PreToolUse` blocks with exit 2 (stderr goes to the model) or with
`{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"…"}}`.
`Stop`/`SubagentStop` block with `{"decision":"block","reason":"…"}` — measured
to work: the subagent kept working, executed the reason's instruction, and
stopped again with `stop_hook_active: true`. A hook that blocks again on
`stop_hook_active: true` loops to the block cap, so it must not.
`PreToolUse`, `PostToolUse`, `SessionStart`, `UserPromptSubmit` and `Stop`
inject with `additionalContext`.

## 3. Design principles

- **No wave, no hooks.** Every hook exits 0 with no output unless an *active*
  wave state file exists for the project. Sessions that never run `/wave-start`
  are untouched, and a wave whose `status` is `closed` enforces nothing. This is
  the "minimum disturbance" guarantee.
- **Deny only on a precise, testable rule.** A false NO-GO is worse than a
  missing check, so every deny has a mutation-proved negative control in the
  test suite and prints exactly which rule fired and how to satisfy it.
- **A hook that could not read its input has not measured anything.** Missing
  `jq` or `flock`, unparseable stdin, an unreadable or half-written state file,
  a lock timeout, a gating scan that returned nothing where it should return a
  count — all of these emit one warning and **allow**. No deny is ever emitted
  unless a positive parse marker is set. No `set -e`; never `exit 2` from an
  error path.
- **Data over code.** The phase table, the model tiers, the budgets, the
  planning-path patterns, the orchestrator-writable allow-list and every deny
  reason string are TSV files the scripts read. Changing the framework means
  editing a row, not a script.
- **Cross-check, don't trust.** The requested model is checked at dispatch; the
  model that actually ran is read from the transcript at stop. Artifacts are
  checked on disk, not from the subagent's claim.
- **Escape hatch that leaves a record.** `enforce: "warn"` in the state file
  turns every deny into a warning that names the same rule id; approvals and
  overrides are files under `.wave/approvals/`, so a later reader can see who
  allowed what. Those records are **local-only and not durable** — `.wave/` is
  excluded from git by construction (§4), so the only committable copy of an
  approval is the line the checkpoint doc carries. Anything stronger (a real
  signature, an audit trail that survives the working copy) is out of scope.

## 4. Wave state

`/wave-start` runs `scripts/wave-init.sh`, which writes
`<project>/.wave/state.json`:

```json
{
  "schema": 1,
  "wave": "1",
  "mode": "full",              // full | demo | solo
  "status": "active",          // active | closed
  "ui": "unknown",             // true | false | "unknown"
  "behaviour_change": "unknown",
  "cr_enabled": "unknown",
  "enforce": "block",          // block | warn
  "feature": "…",
  "started": "2026-09-09T12:00:00Z",
  "ended": null,
  "base_sha": "abc123",        // git HEAD at wave start, for diff-based metrics
  "phases": { "AC": { "status": "done", "at": "…", "agent": "…" } },
  "active": { "<agent_id>": { "phase": "TDE-RED", "role": "executor", "requested_model": "sonnet", "resolved_model": "…", "tool_use_id": "…", "status": "launched" } },
  "pending": { "<tool_use_id>": { "phase": "…", "role": "…" } },
  "rounds": { "TDE-GREEN/executor": 1 }
}
```

`ui`, `behaviour_change` and `cr_enabled` start as `"unknown"`, not `false`. A
default of `false` would silently switch off `[DR]` and the visual gate, which
is precisely the failure the framework's own DR rule exists to prevent. While
any of the three is `"unknown"`, a `TDE-RED` dispatch is denied (`W-SCOPE`) with
the one command that sets it:
`scripts/wave-set.sh ui true|false` (also `behaviour-change`, `cr`), which
records the answer in `.wave/approvals/scope.md`. An explicit `false` is fine; a
silent skip is impossible.

Wave lifetime: `status` is `active` until the active mode's terminal phase
(`AD` in full, `TEET` in demo) is marked `done`, or `scripts/wave-close.sh`
runs; either sets `status: "closed"` and `ended`. Every hook exits 0
immediately when `status != "active"`, so an abandoned `.wave/` cannot enforce
rules over an unrelated later session. `wave-init.sh` archives a `closed`
state to `.wave/archive/<started>-state.json` and refuses (non-zero, nothing
written) while an `active` wave exists unless `--force` is passed.
`session-start.sh` prints one warning when an `active` wave is older than 24 h,
naming the close command.

Project root resolution, in order: `CLAUDE_PROJECT_DIR`; else `cwd` with a
`/.claude/worktrees/<name>` suffix stripped; else the first ancestor of `cwd`
that contains `.wave/state.json`, with the walk stopped at
`git rev-parse --show-toplevel` so a nested unrelated repository never inherits
another project's wave. Every path is compared after `realpath`; a `.wave` that
resolves outside the project root is refused (`W-STATE`) and never written
through.

`.wave/` must not reach a commit. `wave-init.sh` appends `.wave/` to the
project's `.git/info/exclude` (not `.gitignore` — the user's tracked tree is
left alone) and reports it, and `.wave/**` is the first row of
`hooks/planning-paths.tsv` so the commit guard denies it as well.

## 5. Dispatch tag

Every `Agent` dispatch **made from the main session** during a full- or
demo-mode wave must begin its `description` with

```
[W:<wave> P:<PHASE> R:<lead|executor|reviewer|scanner|writer>]
```

for example `[W:1 P:TDE-GREEN R:executor] implement AC-3..AC-7`. The grammar is
anchored at byte 0, case-sensitive, with exactly one space between fields. An
untagged main-session dispatch during an active wave is denied (`W-TAG`) with
the template in the reason.

The tool documents `description` as a short phrase, so: the same tag may be
repeated as the **first line of `prompt`**, and `pre-agent.sh` accepts the tag
from either field (description first, then the prompt's first line). A
`description` over 120 characters is warned about (`W-DESC`), never denied.

Dispatches made **inside** a subagent (stdin carries `agent_id`) are denied
outright by §8.4 — the orchestrator is the single dispatcher — so the tag rule
never needs to judge them. `run_in_background` is a `Bash` parameter and no rule
keys on it; `isolation: "remote"` and `isolation: "worktree"` agents still raise
an ordinary main-session `PreToolUse(Agent)` and are gated normally.

Role vocabulary: the tag enum is exactly those five values. The framework's
richer role names (Implementer, Verifier, Auditor, Comparator, Tester, Mockup
Writer, Adversarial Writer/Scanner/Executor …) map onto the five in
`hooks/roles.tsv`, which the deny reason quotes so the orchestrator can see
which tag role its role name belongs to. For the tier comparison, `scanner` and
`writer` both resolve to the row's `executor` column.

## 6. Phase table (`hooks/phases.tsv`)

Columns (12): `code`, `modes`, `when`, `condition`, `after`, `fanout`, `lead`,
`executor`, `reviewer`, `artifact`, `marker`, `findings`.

- `modes`: `full`, `demo` or `full,demo`.
- `when`: `phase` (ordinary) or `anytime`. An `anytime` row is exempt from the
  `after` check, the round ceiling and the budget gate — the continuous Haiku
  dashboard is the one role that must be dispatchable throughout a wave.
- `condition`: `always`, `ui|behaviour_change` (either state flag true), `cr`
  (`state.cr_enabled`), or `findings:<CODE>` — the findings file named by
  `<CODE>`'s `findings` column reports ≥1 finding.
- `after`: comma list of phase codes that must be `done`. **The skip rule is
  transitive: a row whose `condition` is false, or whose `modes` excludes the
  active mode, is skipped, but its own `after` is looked through recursively.**
  Its applicable predecessors must still be `done`. This lets a clean scan
  (`FINDINGS: 0`, so its `BF-*` never runs) and the demo subset proceed without
  bypassing unfinished work behind a skipped conditional row.
- `fanout`: how many concurrent dispatches of the same phase+role count as
  **one** round (PDT fan-out: 3 TEET-TC writers, 3 TEET testers, 3 BTEET-X
  executors, 3 BC scanners, 2 AC executors, 2 DR executors). It also multiplies
  the phase's budget.
- `lead` / `executor` / `reviewer`: minimum model tier for that role, or `-`
  when the role does not exist in the phase. A dispatch naming a `-` role is
  denied (`W-ROLE`) with the roles that do exist.
- `artifact`: path under `.wave/` that must exist when the phase's closing
  dispatch stops; `-` when none.
- `marker`: an extended regex at least one line of the artifact must match
  (`command grep -E`). Anchored at both ends wherever a prefix could collide.
- `findings`: the scan code whose findings file is `.wave/findings/<CODE>.md`
  (marker `^FINDINGS: [0-9]+$`), or `-`.

Full-mode rows, in order — `AC`, `ACB`, `DR`, `TDE-RED`, `TDE-GREEN`, `CR`,
`BC`, `BF-BC`, `SEA`, `BF-SEA`, `DS`, `BF-DS`, `BSEA`, `BF-BSEA`, `OA`,
`TEET-TC`, `TEET`, `BF-TEET`, `BTEET`, `BTEET-X`, `BF-BTEET`, `VB`, `COMMIT`,
`CL`, `CCP`, `AD` (26 rows × 3 role cells = 78 tier cells). Demo-mode rows:
`AC`, `DR`, `TDE-RED`, `TDE-GREEN`, `TEET`.

The tier cells reproduce the `framework/SKILL.md` phase table exactly: rows that
name a single model there (`BC`, `SEA`, `DS`, `VB`, `COMMIT`, `CL`, `CCP`, `AD`)
fill only the `executor` cell and carry `-` for `lead` and `reviewer`; `CR` is
plugin-managed and is expressed as one `reviewer` dispatch at `sonnet`. The
`[TDE-RED]` reviewer tier is `sonnet`; the framework's cross-language escalation
to Opus needs no table change, because a higher tier always passes.

`after` is written per row, not implied by file order. `VB`, `COMMIT`, `CL` and
`CCP` share one predecessor set (`BTEET-X,BF-BTEET`) so the framework's parallel
finalization is not serialised, and `AD` is `anytime`.

Hand-off artifacts and markers (the contract the orchestrator skill already
states, now checked on disk):

| Phase | Artifact | Marker |
|---|---|---|
| AC | `.wave/ac.md` | `^AC-[0-9]+` |
| ACB | `.wave/acb.md` | `^ACB-VERIFIED` |
| DR | `.wave/dr.md` | `^DR-VERIFIED` |
| TDE-RED | `.wave/red.md` | `^RED-VERIFIED failing=[1-9][0-9]*$` |
| TDE-GREEN | `.wave/green.md` | `^GREEN-VERIFIED passing=[1-9][0-9]* failing=0$`; UI waves also need a non-empty `.wave/screenshots/green-<name>.png` (`^green-.+\.png$`, size > 0) |
| CR | `.wave/cr.md` | `^CR-VERIFIED` |
| BC / SEA / DS / BSEA | `.wave/findings/<PHASE>.md` | `^FINDINGS: [0-9]+$` |
| BF-`<X>` | `.wave/bf-<X>.md` | `^BF-VERIFIED` |
| OA | `.wave/oa.md` | `^ALIGNMENT: [0-9]+%$` |
| TEET-TC | `.wave/teet-tc.md` | `^TEET-TC-VERIFIED$` |
| TEET | `.wave/teet.md` | `^TEET-VERIFIED$` (findings: `.wave/findings/TEET.md`) |
| BTEET | `.wave/bteet.md` | `^BTEET-VERIFIED$` (findings: `.wave/findings/BTEET.md`) |
| BTEET-X | `.wave/bteet-x.md` | `^BTEET-X-VERIFIED$` |
| CCP | `.wave/checkpoints/<ts>-ccp.md` | exists (a `*-precompact.md` file does **not** satisfy it) |
| VB, COMMIT, CL, AD | — | — |

Gates that read an artifact at dispatch time rather than at stop:

- **DR OPEN items.** `TDE-RED` is denied (`W-DR-OPEN`) unless
  `.wave/approvals/dr-open.md` holds one `RESOLVED:` line for every `OPEN:`
  line in `.wave/dr.md`, counted after stripping fenced code blocks and
  anchored at `^OPEN:`. The user answers DR OPEN items in conversation and
  nothing rewrites `dr.md`, so the gate is the approval file, never the absence
  of text. The deny prints the unanswered lines.
- **Visual approval.** While `ui` is true, every phase ordered after
  `TDE-GREEN` is denied (`W-VISUAL`) until `.wave/approvals/green-visual.md`
  exists.
- **Bug-fix approval.** A `BF-<X>` dispatch is denied (`W-BF-APPROVAL`) unless
  `.wave/approvals/bf-<X>.md` exists — byte-exact path, not case-folded.
- **Findings condition.** A `findings:<CODE>` condition whose findings file is
  absent is a `W-ARTIFACT` deny naming the file; the wave stops rather than
  guessing. The count is the first `^FINDINGS: [0-9]+$` line, base 10.

**Solo mode.** `phases.tsv` is not consulted at all when `mode` is `solo`: no
row applies, no phase is gated, and a dispatch carrying a valid tag is recorded
but not judged against the table. Untagged dispatches are ledgered under phase
`SOLO`. Solo keeps only the explicit-model rule, the commit guard, the
PreCompact checkpoint and the ledger. There are no prompt caps, phase-order
checks, tier comparisons, orchestrator-only rules, round ceilings or budget
gates. Solo is for medium tasks the user drives directly with at most a
separate review dispatch, and it exists so the cheap invariants do not have to
be turned off to get out of the way.

## 7. Model routing (`hooks/models.tsv` + tiers)

Tiers: `haiku=1`, `sonnet=2`, `opus=3`, `fable=4`. A dispatch's requested model
must be **at least** the tier the phase table gives for its role; higher is
always allowed (the framework's never-degrade rule). A missing `model` key, an
empty `model`, or the literal `inherit` is denied (`W-MODEL-MISSING`): every
dispatch names its model.

Mapping a model string to a tier: trim, lowercase, then match tier names as
tokens delimited by non-alphanumerics — so `claude-sonnet-4-5-20250929` and
`claude-opus-5[1m]` map cleanly, while `opusless-1` does not. Exactly one
distinct tier token must match. Zero matches (`gpt-5`), two matches
(`claude-sonnet-opus-preview`), or an alias `models.tsv` marks as `unknown`
(`opusplan`, `default` — aliases whose execution model is not the substring)
produce a **warning** (`W-MODEL-UNKNOWN`) and **allow**: a model the map cannot
read is a gap in our table, and denying it would false-NO-GO a legitimate alias
or a model released after this version. `fable`'s rank above `opus` is this
document's assumption, not a measured quality claim, and is recorded as such in
`models.tsv`.

Cross-checks:

- At `PostToolUse`, `resolvedModel` is mapped to a tier. Below the requested
  tier (a settings override silently downgraded it) → the launch is recorded
  `status: "downgraded"` and a `W-DOWNGRADE` warning is injected. Unreadable →
  `resolved_model: "unknown"` and a `W-RESOLVE-UNKNOWN` warning. Above the
  request → nothing. A `PostToolUse` hook cannot deny and never tries.
- At `SubagentStop`, the agent transcript is streamed and the **modal tier of
  `assistant` turns with `usage.output_tokens > 0`** is compared with the
  requirement, reconciled against `resolvedModel`. Below it, the phase records
  `tier_ok: false` and `tainted: true`, one warning is emitted, and dependent
  dispatches carry a `W-TAINT` warning — **but are allowed**. A single
  lower-tier line is produced by ordinary tool behaviour (a fetch tool that
  answers a prompt with a small model) and by platform quota fallback; a
  platform-side downgrade is recorded, not punished, because the remedy of a
  gate here would be paid rework on a correct wave. A transcript with no
  `assistant` line, or lines with no `message.model`, records
  `tier_verified: false` and `tier_ok: null` — unverifiable is not taint.
- `subagent_type: "fork"` is denied during a full/demo wave (`W-FORK`): a fork
  inherits the orchestrator's entire context, which defeats §9's lean-context
  rule and invariant 1, and its model cannot be routed at all (the tool ignores
  a `model` override on a fork). The reason names the remedy — dispatch a typed
  subagent with an explicit model.

## 8. Orchestrator-only session (subagent-driven development)

Every rule in this section applies only while a `full` or `demo` wave is
`active`, and every one of them honours `enforce: "warn"`.

**8.1 Edits.** A main-session `Edit`, `Write`, `NotebookEdit` or `MultiEdit`
(stdin carries no `agent_id`) is denied (`W-EDIT`) when the target, after
`realpath`, is **inside the project root AND tracked by git AND not under
`.wave/`**, unless its repo-relative path matches a row of
`hooks/orchestrator-writable.tsv` (ships with `CHANGELOG.md`, `README.md`,
`CONTINUE-HERE.md`, `docs/**`). Paths outside the project root are untouched —
the orchestrator's own analysis and handoff documents live there by the
framework's own instruction — and `.wave/**` is allowed by construction, so
writing an approval file is never blocked. A symlink under `.wave/` pointing at
project source does not launder an edit; the decision is taken after `realpath`.

**8.2 Reads.** A main-session `Read` is denied (`W-READ`) unless the resolved
path is under `.wave/` (reports, artifacts, checkpoints) or outside the project
root. The reason says: locate with Grep/Glob, then read through a subagent that
returns the conclusion. `Grep`, `Glob` and `LS` are never gated.

**8.3 Builds and tests.** A main-session `Bash` whose `tool_input.command`
matches a test/build runner is denied (`W-BASH`). Shipped form (widened by
the Task 9 review's Fix round 1, 2026-09-10 — the original anchor admitted
none of leading whitespace, an env-var assignment, or a wrapper command, so
`sudo make`, `CI=1 npm test` and ` make` all silently passed):

```
(^|[;&|])\s*((sudo|time|nice|env)(\s+-\S+)*\s+|[A-Za-z_][A-Za-z0-9_]*=\S*\s+)*(npx\s+)?(jest|vitest|mocha|playwright|pytest|py\.test|go test|cargo (test|build)|dotnet (test|build)|make|tsc|ng (build|test)|vite build|npm (test|run (build|test|e2e))|pnpm (test|build)|yarn (test|build))\b
```

The runner name may now be preceded, at the start of the command or right
after a `;`/`&`/`|`, by any amount of whitespace, any number of env-var
assignments (`CI=1 npm test`), and any of the wrapper commands `sudo`,
`time`, `nice`, `env` — each optionally carrying its own dash-flags
(`sudo -E`) — before an optional `npx`. A wrapper/env token still has to
look like one, so the anchor cannot bridge across an unrelated command:
`echo sudo make` stays silent (`sudo make` is text following `echo`, not a
wrapper), as does `FOO=bar ls` and `sudo ls` (neither names a runner). A
flag's own bare argument (the `5` in `nice -n 5`) is not skipped — a
declared bound, not a Fix-round-1 requirement.

Everything else is allowed with no output at all (`git status`/`log`/`diff`,
`ls`, `wc`, reading `.wave/`), so ordinary inspection produces no noise. A
`Bash` write (`sed -i src/x.ts`) is **not** covered — §13 records it as a
declared bound rather than pretending the hook closes it. Neither is a
runner name reached through a shell built-in indirection (`bash -c "npm
test"`, a variable, or an alias) — the hook is a deliberate lexical filter
over the literal command text, never a shell interpreter (Fix round 1
ruling: "do not try to be shell-quote-aware; the declared lexical bound
stands for `bash -c "…"`, variables and aliases").

**8.4 Nested dispatch.** An `Agent` call whose stdin carries `agent_id` is
denied (`W-NESTED`): "the orchestrator is the single dispatcher; return your
result and let it dispatch the reviewer." This is the framework's own position —
nested subagents are not supported on this platform, and every team is
re-expressed as a sequence of dispatches the orchestrator coordinates.

**8.5 Lean return.** At `SubagentStop`, when `last_assistant_message` is longer
than 2,000 characters and `stop_hook_active` is false, block **once** with:
"write the full report to `.wave/reports/<PHASE>-<ROLE>-<agent_id>.md` and
return a summary under 2,000 characters". On any stop with
`stop_hook_active: true`, never block again; record `long_return: true` on the
ledger line.

**8.6 Prompt-time reminder.** `UserPromptSubmit` injects, only while a wave is
active: "wave `<id>` active, phase `<last done>` → `<next allowed>`. This
session is the orchestrator: dispatch tagged Agents, read only `.wave/`
reports, no builds/tests/edits here."

**8.7 Round ceiling.** A third **round** of the same `phase+role` in one wave is
denied (`W-ROUND`) until `.wave/approvals/rerun-<PHASE>-<role>.md` exists — the
orchestrator has to surface the repeated failure to the user instead of retrying
blindly. Rounds, not dispatches: `state.rounds["<PHASE>/<role>"]` is incremented
by `subagent-stop.sh` when the last concurrent agent of that phase+role stops,
so a `fanout` of 3 PDT writers is one round and a denied or user-rejected
dispatch never burns the ceiling. The approval file is scoped to the phase **and
role** it names. `anytime` rows are exempt.

## 9. Token ledger and budgets (point 4)

At `SubagentStop` the hook streams the agent transcript line by line, sums
`message.usage` over `assistant` lines, and appends one line to
`.wave/ledger.jsonl`:

```json
{"agent":"…","phase":"TDE-GREEN","role":"executor","requested":"sonnet","resolved":"claude-sonnet-5","tier_ok":true,"tier_verified":true,"input":1234,"output":5678,"cache_read":0,"cache_create":0,"turns":7,"stopped":"…"}
```

The key set is closed; `tier_ok` is boolean or `null`; absent usage fields count
as `0`. Extra keys appear only where this document names them (`warn`,
`long_return`, `note`, `skipped_lines`). The ledger is append-only, one line per
`agent_id` (a duplicate `agent_id` is the tell of a lost lock), and a spend is
recorded even when the phase fails its artifact check. Above a stated transcript
byte cap the sum is skipped with `note: "transcript too large"`.

`hooks/budgets.tsv` gives an **output-token** budget per phase (output is the
work produced; cache reads are cheap and would hide waste). The effective budget
is the row's value × the phase's `fanout`, and it is a **per-phase total**
summed over the ledger's lines for that phase. On the next dispatch: over 1× →
warning; over 2× → denied (`W-BUDGET`) until `.wave/approvals/budget-<PHASE>.md`
exists. A phase with no budget row, an absent ledger, or a ledger whose lines do
not parse never produces a `W-BUDGET` deny.

Lean-context caps at dispatch: a `prompt` over 8,000 characters warns; over
24,000 characters warns more loudly but **does not deny** — the framework
requires cross-team data to pass through the orchestrator, and a hard cap would
force it to make the brief worse. What is denied (`W-PASTE`) is the actual
pollution pattern: a block of ≥4,000 characters in the prompt that is
byte-identical to a file already under `.wave/`, which the subagent could read
itself. Length is counted in Unicode scalar values after JSON unescaping.

Scorecard: `scripts/wave-scorecard.sh` renders the ledger as a table (phase,
role, model, output tokens, budget, ratio, rework count) plus, for `TDE-GREEN`,
output tokens per changed line (`git diff --shortstat <base_sha>`) and the
passing-test count from `green.md`. The `Stop` hook fires at the end of every
assistant turn, so it prints the scorecard path **only** once the active mode's
terminal phase (`AD` full, `TEET` demo) is `done`, and writes
`.wave/.scorecard-printed` so it prints once.

## 10. Invariants 6 and 7

Invariant 6 (planning docs never committed) is enforced. Invariant 7's
**checkpoint** is enforced; its **stop** is advised — `PreCompact` output is
ignored by the platform and compaction proceeds regardless, so no hook can
block it. `framework/references/07-invariant-rules.md` currently claims
compaction is blocked if the save fails; that sentence is corrected in this
change.

- `PreCompact`: writes `.wave/checkpoints/<ts>-precompact.md` from
  `state.json` and the ledger (goal, phase reached, artifacts present, ledger
  totals, trigger, resume command). No agent is spawned, so it cannot fail for
  lack of context. An unwritable `.wave/` produces a warning and exit 0 — never
  a hook error during compaction.
- `SessionStart` with matcher `startup|resume|clear|compact`: injects the wave
  banner (wave id, mode, enforce, last done phase, tag template) and, on
  `compact`, the invariant-7 advisory naming the latest checkpoint and asking
  for a fresh terminal.
- `PreToolUse` on `Bash` (matcher `^Bash$`; the *script* greps
  `tool_input.command`) matching a `git commit` in any of its real shapes
  (`git -C dir commit`, `cd x && git commit`, extra spaces): denies when a
  staged path matches a row of `hooks/planning-paths.tsv` (`W-COMMIT-DOC`) or
  when the message text carries an attribution trailer
  (`Co-Authored-By: .*(Claude|Anthropic)`, `Generated with .*Claude Code`,
  `claude.ai/code/session`) (`W-COMMIT-TRAILER`). Functional mentions in code
  or in a message ("fix the claude-config parser", "bump the vendor SDK") are
  not touched, and `--amend --no-edit` is judged on `git log -1 --format=%B`.
  Git is run as `git -C "<stdin cwd>"` — never `CLAUDE_PROJECT_DIR` — so the
  guard inspects the index the commit will actually use, including inside a
  worktree. `.wave/approvals/commit-doc.md` turns the `W-COMMIT-DOC` deny into
  a warning: this replaces ref 11's `settings.json` "allow" override, and it is
  what a methodology repository (this one included) uses to commit
  plan-shaped documents.
- Because the Bash fast path cannot see a message supplied by `-F`, a heredoc,
  `-t` or an editor, `wave-init.sh` also installs a repo-local
  `.git/hooks/commit-msg` (written with a Bash heredoc, since `.git/` is
  protected from the Write tool) that sees the final message whatever the path.
  If a `commit-msg` hook already exists it is **not** overwritten: the fact is
  reported and recorded in state, and the Bash fast path remains.

Every gating scan in every script uses `command grep` or `rg`, never a bare
`grep` (a wrapped searcher can decline a file and print nothing where real grep
prints `0`), asserts a positive run marker, and treats an absent count as a
**failed scan** — warned about, never reported as clean.

## 11. Files

New:

```
hooks/hooks.json                  real schema; every command via ${CLAUDE_PLUGIN_ROOT}
hooks/phases.tsv                  §6
hooks/models.tsv                  tier names → rank, plus declared-unknown aliases
hooks/roles.tsv                   framework role names → the five tag roles
hooks/budgets.tsv                 §9
hooks/planning-paths.tsv          commit-guard patterns (first row `.wave/**`)
hooks/orchestrator-writable.tsv   §8.1 allow-list
hooks/reasons.tsv                 one printf template per rule id + the precedence order
scripts/hooks/lib.sh              stdin parse, root resolution, state read/write, tier map, emitters
scripts/hooks/session-start.sh
scripts/hooks/user-prompt.sh      §8.6
scripts/hooks/pre-agent.sh        tag, mode, role, model, tier, scope, order, condition, artifacts, round, budget, prompt
scripts/hooks/post-agent.sh       record agent id + resolvedModel
scripts/hooks/subagent-stop.sh    artifact + marker, transcript tiers, ledger, mark done, lean return
scripts/hooks/pre-edit.sh         §8.1
scripts/hooks/pre-read.sh         §8.2
scripts/hooks/pre-bash.sh         §8.3
scripts/hooks/pre-commit-guard.sh §10
scripts/hooks/pre-compact.sh      §10
scripts/hooks/stop.sh             scorecard pointer at wave close
scripts/wave-init.sh              writes state.json (called by /wave-start)
scripts/wave-set.sh               sets ui / behaviour_change / cr_enabled
scripts/wave-close.sh             closes the wave
scripts/wave-scorecard.sh
tests/run.sh                      harness: feeds JSON fixtures to each script, asserts allow/deny/context
tests/e2e.sh                      load proof + real headless run
tests/cases/*.json|*.sh
tests/golden/phases-tiers.tsv     78 tier cells transcribed from framework/SKILL.md
tests/golden/budgets.tsv
```

Hook wiring rules, all load-bearing:

- Matchers are unanchored JavaScript regexes over **tool names**:
  `^Agent$` for the dispatch hooks, `^(Edit|Write|NotebookEdit|MultiEdit)$` for
  §8.1, `^Read$` for §8.2, `^Bash$` for §8.3 and the commit guard; `Stop`,
  `PreCompact`, `SubagentStop` and `UserPromptSubmit` take no matcher, and
  `SessionStart` uses `startup|resume|clear|compact`. `MultiEdit` stays in the
  regex as forward-compatibility; it is not a tool on the client of record.
- `async` is **false everywhere**. Every deny hook is disqualified from async by
  definition (exit 2 is not enforced for an async hook), and `post-agent.sh` and
  `subagent-stop.sh` are disqualified because the next dispatch's gate reads the
  state they write.
- The command-hook `timeout` default is 10 minutes. `subagent-stop.sh` sets an
  explicit `timeout: 60` (it streams a possibly multi-MB transcript with
  `jq -c` per line and a byte cap); the fast hooks set 5–10 s. A long default is
  the hazard, not a short one.
- State writes: `flock` a dedicated, never-replaced `.wave/lock` created by
  `wave-init.sh` — **not** `state.json`, because writing via `tmp && mv`
  replaces the locked inode and a concurrent holder's update is then lost
  silently. The lock is held across the whole read-modify-write including the
  rename, `flock -w 10`, and a timeout warns and never denies. Ledger appends
  happen under the same lock with one `printf`; a hook that timed out writes its
  line to `.wave/ledger.pending/<agent_id>.json`, and the next successful
  acquisition drains it exactly once. A stale lock whose recorded holder pid is
  dead is acquired, not waited on.

Changed (minimal):

- `.claude-plugin/plugin.json`: version 0.2.0 only. **Do not add a `hooks`
  field**: the client auto-loads `hooks/hooks.json`, and a manifest entry
  duplicates it; clients from about 2.1.26x then log "Duplicate hooks file
  detected … Hook load failed" and load the plugin with no hooks at all (hit
  org-wide on 2026-09-09 with another plugin). `claude plugin validate` does not
  catch it, and the published docs are silent on the failure, so the §12 load
  proof is the only thing that would catch a regression.
- `commands/wave-start.md`: parses `--demo` and `--solo`; step 0 runs
  `wave-init.sh`, asks the UI / behaviour-change / CR questions and records them
  via `wave-set.sh`, then verifies `.wave/state.json` exists before invoking the
  orchestrator and refuses with one line if it does not (a wave that starts
  without state runs with enforcement silently off). The `allowed-tools`
  front-matter gains the exact permission for the `wave-init.sh` /
  `wave-set.sh` invocations — without it step 0 prompts or is refused.
- `skills/wave-orchestrator/SKILL.md`: one section "Hook-enforced contract"
  (tag, artifacts, markers, approvals dir, enforce modes, the three modes, the
  declared bounds). No other edits.
- `framework/references/11-hooks-and-automation.md`: rewritten to the real
  schema and to what the plugin now ships; the pattern list moves into
  `hooks/planning-paths.tsv` and the doc cites the file.
- `framework/references/07-invariant-rules.md`: the "compaction is blocked if
  the save fails" claim corrected to what the platform allows.
- `README.md`, `CHANGELOG.md`: hooks section, version badge, 0.2.0 entry.

## 12. Testing

- **Unit.** `tests/run.sh` runs every script against JSON fixtures with a temp
  project dir; asserts exit code, the JSON decision, the rendered reason string
  byte-for-byte against its `hooks/reasons.tsv` template, and that the reason
  carries exactly **one** `W-` token. Every deny fixture violates exactly one
  rule (it names a valid model and a satisfied order) so a script that prints
  every id cannot pass the corpus. Each rule id has a positive case and a
  negative control on the neighbouring valid input, and the harness fails if any
  id in `reasons.tsv` lacks either, if a script emits an id `reasons.tsv` lacks,
  or if fewer cases executed than there are case files.
- **Mutation.** A disposable copy of `scripts/hooks/` and of the tier golden is
  mutated one rule / one cell at a time, with a forced clean copy between
  mutants (never a timestamp-preserving restore). A mutant that reds nothing is
  reported as a vacuously covered rule and fails the suite.
- **Load proof.** `tests/e2e.sh` runs
  `claude --debug-file <log> --plugin-dir . -p ok` and fails if the log contains
  `Duplicate hooks` or `Hook load failed`, or lacks a line showing this plugin's
  hooks registered. Validation is not a load test.
- **End to end.** `tests/e2e.sh` then runs a headless session in a scratch
  project with a seeded `state.json` and asks for (a) an untagged dispatch,
  (b) a tagged dispatch on a too-low model, (c) a correct dispatch; asserts the
  deny reasons appear, that `resolvedModel` was read from the real launch, and
  that the ledger gains one line. It also asserts `/wave-start` produces
  `state.json` with no permission prompt, that a real `git commit` carrying a
  trailer is refused by the installed `commit-msg` hook (git runs it under the
  system `grep`, so verifying with a shell wrapper measures a different
  instrument), that a `PreToolUse` `additionalContext` string reaches the
  transcript (the channel `enforce: "warn"` depends on), and that a project with
  no `state.json` is untouched. The whole file is skipped with a loud message
  when `claude` is not on `PATH`.

## 13. Out of scope, and declared bounds

- A `Bash` write (`sed -i`, a heredoc into a source file) from the main session
  is not covered by §8.1; only the four edit tools are.
- Rules inside a worktree-isolated subagent. Hooks **do** fire there and can
  read the main project's state — the reason they are not gated is the
  `agent_id` discriminator, not the working directory. The commit guard is the
  one rule that deliberately does run there, and it reads the worktree's index.
- Verifying that a user really approved an approval file: the file is an audit
  record, not a signature. Approval records are local to the working copy and
  are not durable; the only committable trace is the line the checkpoint carries.
- Pricing in currency; the ledger records tokens by type, cost is a later
  multiplication.
- Enforcing anything in `solo` mode beyond §7's explicit-model rule, §9 and §10.

## 14. Decisions taken from the design review

32 findings were reviewed. Each line says what changed in this document.

| # | Decision |
|---|---|
| F1 | **Rejected as false** — the 300-byte `tool_response` was the probe's own dump truncating its output, not the platform. §2 keeps a tolerant three-step read (object → `fromjson?` → regex) and treats an unreadable `resolvedModel` as `unknown`, never as a violation; the transcript stays authoritative. No description cap is justified by truncation. |
| F2 | All six `BF-*` rows carry `findings:<CODE>`; §6 states once that a false condition counts as `done` for `after`. `findings` is now a column, so `BF-TEET` / `BF-BTEET` are reachable. |
| F3 | Round ceiling counts **rounds**, incremented at stop when the fan-out group empties; new `fanout` column (3 for the PDT phases). No concurrency deny was added — it would be a new false-NO-GO path. |
| F4 | Artifact/marker checks run last-one-out only (no other agent of that phase in `state.active`) and only at the closing role's stop. |
| F5 | New `when` column with `anytime`; `AD` is `anytime` and exempt from `after`, the round ceiling and budgets. |
| F6 | New principle 3 in §3 (a hook that could not read its input has measured nothing): `jq`/`flock` guards, a positive parse marker gating every deny, no `set -e`, no `exit 2` on error paths. |
| F7 | `flock` a dedicated never-replaced `.wave/lock` held across the whole read-modify-write including the rename; `-w 10`; timeout warns; ledger appended under the same lock; duplicate `agent_id` named as the tell of a lost lock. |
| F8 | The transcript tier check is a **warning**, judged on the modal tier of assistant turns with output tokens, reconciled with `resolvedModel`. `tainted` no longer gates a dependent dispatch. |
| F9 | `ui`, `behaviour_change` and `cr_enabled` start `"unknown"`; `TDE-RED` is denied (`W-SCOPE`) while any is unknown, naming `scripts/wave-set.sh`. A silent DR skip is impossible. |
| F10 | `wave-init.sh` appends `.wave/` to `.git/info/exclude`; `.wave/**` is the first row of `hooks/planning-paths.tsv`. |
| F11 | Tag enum stays the five values (a closed grammar is testable); `hooks/roles.tsv` maps the framework's role names onto them and the deny reason quotes it; `scanner` and `writer` resolve to the `executor` tier cell. |
| F12 | §8.1 narrowed to inside-project **and** git-tracked **and** not under `.wave/`, with `hooks/orchestrator-writable.tsv`; everything outside the project root is untouched. |
| F13 | Matcher `^Bash$` with the script grepping `tool_input.command`; git run as `git -C "<stdin cwd>"`. |
| F14 | Bash fast path kept, plus a repo-local `.git/hooks/commit-msg` installed only when absent (an existing hook is reported, never overwritten); `--amend --no-edit` judged on the previous message. |
| F15 | §10 retitled: invariant 6 enforced, invariant 7's checkpoint enforced and its stop advised via `SessionStart` matcher `compact`; `07-invariant-rules.md` corrected in the same change. |
| F16 | `status` / `ended` added; every hook exits 0 when a wave is not `active`; `wave-init.sh` archives a closed state and refuses over an active one without `--force`; `session-start.sh` warns past 24 h. |
| F17 | RED gates on `.wave/approvals/dr-open.md` (one `RESOLVED:` per `^OPEN:` line, fenced blocks stripped), not on the absence of text. |
| F18 | Partly rejected: a `fork` dispatch is **denied** (`W-FORK`) rather than exempted — it inherits the whole orchestrator context and cannot be model-routed. `inherit` stays named in the `W-MODEL-MISSING` rule as a defensive case. See §15. |
| F19 | The 24,000-character prompt cap becomes a warning; the deny (`W-PASTE`) fires only on a ≥4,000-character block byte-identical to a file under `.wave/`. |
| F20 | Explicit `after` per row; `VB`/`COMMIT`/`CL`/`CCP` share one predecessor set; a `-` role cell means the dispatch is denied (`W-ROLE`) with the roles that exist; the framework's tiers for the cheap phases filled in. |
| F21 | `commands/wave-start.md` gains the exact `allowed-tools` permission and a step-0 verification that `state.json` exists; the e2e asserts no prompt. |
| F22 | `async: false` everywhere, `timeout: 60` plus per-line streaming and a byte cap on the transcript reader, stated in §11. |
| F23 | Answered by §8.4 rather than by exemption: the framework does not use nested dispatch (teams are sequences the orchestrator coordinates), so a nested `Agent` call is denied. §5 is scoped to main-session dispatches. See §15. |
| F24 | §2 corrected: the transcript lives under the account's projects directory; never construct the path — use `agent_transcript_path`, and skip the sum with a note when it is absent. |
| F25 | `fable` kept at rank 4 with the assumption stated in `models.tsv`; tier matching is token-delimited; unknown or ambiguous models and the declared aliases (`opusplan`, `default`) **warn and allow**. |
| F26 | `SubagentStart` dropped; the join chain is the three events, written into §2. |
| F27 | Every matcher string written into §11; `MultiEdit` kept as forward-compatibility only. |
| F28 | `command grep`/`rg` in every gating scan; empty count = failed scan; positive run marker; noted that git runs `commit-msg` under the system grep. |
| F29 | §3 and §13 now say plainly that approval records are local-only and not durable, and name the checkpoint line as the one committable trace. |
| F30 | Patterns moved to `hooks/planning-paths.tsv`; ref 11's `set -euo pipefail` / `exit 2` guard replaced; the per-project override survives as `.wave/approvals/commit-doc.md` instead of a settings.json allow-hook. |
| F31 | `behaviour_change` added to state and DR's condition is `ui|behaviour_change`. See §15. |
| F32 | Rebased on F1 being false: `description` over 120 characters **warns** (`W-DESC`), and the tag may be repeated as the prompt's first line, which `pre-agent.sh` accepts as a fallback. |

The twelve items the review left open are decided as follows. Worktree
`CLAUDE_PROJECT_DIR`: measured, it stays at the main project root, so §2/§4/§13
state it as fact. `enforce` default: `block` (§15). `fable`: kept, ranked, with
the assumption labelled (F25). Roles: closed enum plus `roles.tsv` (F11, §15).
`[TDE-RED]` reviewer tier: `sonnet`, with cross-language escalation needing no
table change because a higher tier always passes. DR condition:
`ui|behaviour_change` (F31, §15). `commit-msg` in a user repo: installed only
when absent, never overwritten (F14). Budgets: per **phase total**, multiplied
by `fanout`. Nested dispatch: denied (§8.4, §15). Prior state on
`wave-init.sh`: archived when closed, refused when active without `--force`.
Ref 11's per-project override: survives as an approval file (F30).
Description length: 120-character warning plus the prompt-line tag (F32).

## 15. Decisions the user may want to revisit

1. **`enforce` default is `block`.** Alternative: ship `warn` and make `block`
   opt-in per wave. Block was chosen because enforcement that does not stop
   anything is the state v0.1.0 was already in, and every deny now has a
   narrowed rule plus a mutation-proved negative control. `--enforce warn` is
   one flag away, and every warning names the same rule id.
2. **A `fork` dispatch is denied during a wave (`W-FORK`).** Alternative: allow
   it and skip the model checks, since the tool ignores a `model` override on a
   fork. Denying keeps the lean-context invariant literal; allowing would make
   one dispatch shape immune to §7 and §9.
3. **A nested (subagent-issued) `Agent` call is denied (`W-NESTED`).**
   Alternative: allow it with tag inheritance, for teams that want a lead to
   brief its own executors. Denying matches what the vendored framework says
   about this platform and keeps one dispatcher; allowing would leave nested
   dispatches ungated for tier, prompt size and the round ceiling.
4. **The tag's role enum stays the five values, with `hooks/roles.tsv` as the
   documented map.** Alternative: widen the enum to the framework's own role
   names (Auditor, Comparator, Tester, Implementer, Verifier, Adversarial-*).
   Five keeps the grammar closed and the deny reason short; widening would read
   more naturally in a dispatch description.
5. **DR's condition is `ui|behaviour_change`.** Alternative: keep the narrower
   UI-only trigger the vendored framework ships. The broader trigger matches the
   standing rule that every behaviour-changing wave gets a design review, at the
   cost of one more scope question at wave start.
