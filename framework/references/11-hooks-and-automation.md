# 11. Hooks and automation

The v0.2.0 hook layer enforces wave dispatch and hand-off contracts, orchestrator
boundaries and the planning-document commit guard. It also records token usage
and writes recovery checkpoints. The implementation contract is
[`docs/design/2026-09-09-hook-enforcement.md`](../../docs/design/2026-09-09-hook-enforcement.md);
phase, tier, budget, path and reason data live in `hooks/*.tsv`.

## 11.1 Registration and real hook schema

Claude Code auto-loads a plugin's `hooks/hooks.json`. **Do not add a `hooks` field
to `.claude-plugin/plugin.json`.** Duplicate registration can make the client
report `Duplicate hooks file detected` / `Hook load failed` and drop all plugin
hooks. Manifest validation does not catch that failure; verify an actual load.
No copy into user or project `settings.json` is needed.

The hook file contains an event map. Each event has an array of matcher groups;
each group contains a `hooks` array of command objects. This is one registration
from that schema; `hooks/hooks.json` is the complete wiring file:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "^Agent$",
        "hooks": [
          {
            "type": "command",
            "command": "\"${CLAUDE_PLUGIN_ROOT}\"/scripts/hooks/pre-agent.sh",
            "async": false,
            "timeout": 10
          }
        ]
      }
    ]
  }
}
```

Every command uses the quoted `"${CLAUDE_PLUGIN_ROOT}"/scripts/...` path.
Matchers select **tool names**, not shell command text. The Bash scripts inspect
`tool_input.command` themselves. Matcher strings are JavaScript regexes and are
not implicitly anchored; the tool-name matchers below explicitly use `^` and `$`.

| Event | Matcher | Script under `scripts/hooks/` |
|---|---|---|
| `SessionStart` | `startup\|resume\|clear\|compact` | `session-start.sh` |
| `UserPromptSubmit` | none | `user-prompt.sh` |
| `PreToolUse` | `^Agent$` | `pre-agent.sh` |
| `PreToolUse` | `^(Edit\|Write\|NotebookEdit\|MultiEdit)$` | `pre-edit.sh` |
| `PreToolUse` | `^Read$` | `pre-read.sh` |
| `PreToolUse` | `^Bash$` | `pre-bash.sh`, `pre-commit-guard.sh` |
| `PostToolUse` | `^Agent$` | `post-agent.sh` |
| `SubagentStop` | none | `subagent-stop.sh` |
| `PreCompact` | none | `pre-compact.sh` |
| `Stop` | none | `stop.sh` |

`MultiEdit` is retained for forward compatibility; it was not available on the
verified client. `SubagentStart` is not used: its payload cannot join a launch
to a dispatch. `Stop`, `PreCompact`, `SubagentStop` and `UserPromptSubmit` have
no matcher. All command hooks are synchronous (`async: false`). Fast hooks use
explicit 5–10 second timeouts; `subagent-stop.sh` has `timeout: 60` for bounded
transcript streaming. The platform's default command timeout is 10 minutes.

## 11.2 Stdin, state and the dispatch lifecycle

`scripts/hooks/lib.sh` parses the stdin JSON object and reads `hook_event_name`,
`tool_name`, `agent_id` and `cwd`. The presence of `agent_id` distinguishes a
subagent-issued tool call from a main-session call. Script-specific reads are:

| Script | Additional stdin fields read |
|---|---|
| `session-start.sh` | `source` (`compact` selects the restart advisory) |
| `user-prompt.sh` | none; the reminder is derived from wave state |
| `pre-agent.sh` | `tool_input.description`, `.prompt`, `.subagent_type`, `.model` |
| `post-agent.sh` | `tool_use_id`, `tool_input.description`, `.prompt`, `.model`; `tool_response` below |
| `subagent-stop.sh` | `agent_transcript_path`, `last_assistant_message`, `stop_hook_active` |
| `pre-edit.sh` | `tool_input.file_path`; `tool_input.notebook_path` for `NotebookEdit` |
| `pre-read.sh` | `tool_input.file_path` |
| `pre-bash.sh` | `tool_input.command` |
| `pre-commit-guard.sh` | `tool_input.command`; common `cwd` selects the git index |
| `pre-compact.sh` | `trigger` (`manual` or `auto`) |
| `stop.sh` | none; terminal phase and ledger state select the scorecard pointer |

In the table, `.prompt`, `.model` and similar abbreviations remain under
`tool_input`. Other payload fields, such as `permission_mode`, `session_id`,
`duration_ms` or `background_tasks`, are not gating evidence. `background_tasks`
can still call an agent running at its own stop. `transcript_path` may arrive on
session events; the agent's transcript is read from `agent_transcript_path`,
never a constructed project-relative path. `outputFile` is not read.

`PostToolUse(Agent)` records a launch, including an asynchronous launch, rather
than completion. It reads `tool_response.status`, `.agentId` and `.resolvedModel`
tolerantly from an object, a JSON-encoded string, then a raw-text field fallback.
An unreadable resolved model warns and is recorded as unknown. The join is:

```text
PreToolUse.tool_use_id → PostToolUse.tool_response.agentId → SubagentStop.agent_id
```

The requested tier is checked before dispatch. At launch, a lower resolved tier
warns. At stop, the modal tier of assistant turns with output tokens is compared
with the requirement; a downgrade records taint and warns, including on dependent
dispatches, but does not block them. Unknown models warn and allow.

Project resolution starts with `CLAUDE_PROJECT_DIR`, then stdin `cwd` with a
worktree suffix removed, then ancestors containing `.wave/state.json`, stopping
at the git root. Paths are canonicalised; a `.wave` symlink outside the project
is refused. `CLAUDE_PLUGIN_ROOT` locates the plugin's scripts and data.

No state file, or `status` other than `active`, means plugin hooks exit 0 without
output or writes. Missing `jq`/`flock`, malformed input, unreadable state, lock
timeouts and failed scans warn and allow. A scan uses `command grep` or `rg` and
must produce a positive run marker; an absent count is never proof of success.

State updates lock the dedicated, never-replaced `.wave/lock` with `flock -w 10`,
through the entire read-modify-rename. Ledger appends use the same lock and one
write. A timed-out append is spooled to `.wave/ledger.pending/<agent_id>.json`
and drained once on the next successful acquisition.

## 11.3 What is enforced and how blocking works

Full and demo waves require the case-sensitive dispatch tag at byte 0 of
`description`, or as the first line of `prompt` (description takes precedence):

```text
[W:<wave> P:<PHASE> R:<lead|executor|reviewer|scanner|writer>]
```

`hooks/phases.tsv` supplies phase membership, conditions, predecessors, fan-out,
minimum tiers and artifact markers. `hooks/roles.tsv` maps the framework's roles;
`scanner` and `writer` use the executor tier. The orchestrator skill's
[Hook-enforced contract](../../skills/wave-orchestrator/SKILL.md#hook-enforced-contract)
contains the full artifact and approval tables.

Full checks every applicable phase. Demo checks `AC`, `DR`, `TDE-RED`,
`TDE-GREEN`, `TEET`. DR runs for UI or behaviour changes. A skipped conditional
or out-of-mode row is looked through transitively via its own `after`; it cannot
hide an unfinished applicable predecessor. `AD` is `anytime` and exempt from
order, rounds and budgets.

Solo keeps only the explicit-model rule, commit guard, PreCompact checkpoint
and ledger. It has no required tag, prompt caps, order, tier, orchestrator-only
rules, round ceiling or budget gate. Untagged dispatches are recorded as `SOLO`.

In full/demo, the main session delegates tracked source edits, project-source
reads and recognised build/test commands. Edits under `.wave/`, paths outside
the project and entries in `hooks/orchestrator-writable.tsv` are allowed;
`Read` allows `.wave/` and paths outside the project. `Grep`, `Glob` and `LS`
remain available. Nested Agent dispatch and fork dispatch are denied.

The build/test filter is spec §8.3's literal-command regex, including leading
whitespace, environment assignments, `sudo`/`time`/`nice`/`env` wrappers with
dash-flags, optional `npx`, and command separators `;`, `&`, `|`. It recognises
Jest, Vitest, Mocha, Playwright, pytest/py.test, Go tests, Cargo and dotnet
builds/tests, make, tsc, Angular builds/tests, Vite builds, npm test/run
build/test/e2e, and pnpm/yarn test/build. `CI=1 npm test` and `sudo make` match;
`echo sudo make` does not. It does not interpret shell indirection (`bash -c`,
variables, aliases) or skip a wrapper flag's bare argument (`nice -n 5`).
A Bash source write is outside the edit-tool guard's coverage. Hooks also fire
inside worktree subagents, where main-session edit/read/build restrictions do
not apply; the commit guard deliberately inspects the worktree index there.
Nested dispatch remains a separate full/demo rule.

A measured `PreToolUse` violation emits one JSON object and exits 0:

```json
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "[W-RULE] observed violation; remedy: required action"
  }
}
```

At `SubagentStop`, missing artifacts or markers can block the closing role's
last stop for the phase. A return over 2,000 characters blocks once, requesting
a report at `.wave/reports/<PHASE>-<ROLE>-<agent_id>.md` and a shorter summary:

```json
{"decision":"block","reason":"[W-RULE] observed violation; remedy: required action"}
```

A stop with `stop_hook_active: true` is never blocked again. The shipped stop
handler also records its recovery state to avoid repeated return blocks.
Artifact checks verify files and marker syntax; they do not independently run
tests or prove that a screenshot represents correct behaviour.

Warnings and informational messages on supported events use `additionalContext`
with no permission decision:

```json
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "additionalContext": "[W-RULE] observed issue; remedy: suggested action"
  }
}
```

`SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse` and `Stop` can
receive context this way. `PostToolUse` never denies. Subagent-stop warnings
use stderr and ledger records; PreCompact warnings use stderr. These command
hooks emit at most one JSON object, use no asynchronous deny and never use
`exit 2` as an error path.

## 11.4 Rule ids and remedies

Reasons are rendered from `hooks/reasons.tsv` in precedence order. A deny names
one rule, the measured problem and its remedy. Satisfy that remedy and retry;
obtain the user's decision before recording an approval. Warning and information
ids are included below so every shipped id has an interpretation.

| Rule id | One-line meaning and remedy |
|---|---|
| `W-STATE` | State/input/scan cannot be trusted; repair it or scope flags; unreadable data warns and allows. |
| `W-NESTED` | A subagent dispatched an Agent; return the result and let the orchestrator dispatch. |
| `W-FORK` | Fork context cannot be routed; use a typed subagent with an explicit model. |
| `W-TAG` | Dispatch tag is missing or invalid; prefix description or prompt's first line correctly. |
| `W-MODE` | Phase is outside this wave's mode; choose a phase listed for the active mode. |
| `W-ROLE` | Role has no cell in this phase; choose an available role using `hooks/roles.tsv`. |
| `W-MODEL-MISSING` | Model is absent, empty or inherited; name a non-empty explicit model. |
| `W-TIER` | Requested model is below the phase/role minimum; select that tier or higher. |
| `W-SCOPE` | Required scope is unknown; use `scripts/wave-set.sh` with the named flag and boolean. |
| `W-COND` | Phase condition is false; skip it or correct the scope answer if it was wrong. |
| `W-ORDER` | Applicable predecessors are unfinished; complete the named predecessors first. |
| `W-ARTIFACT` | Required evidence file is absent; have its phase produce the exact named path. |
| `W-MARKER` | Evidence lacks the required marker; verify the result and write a matching line. |
| `W-DR-OPEN` | DR questions remain; record one `RESOLVED:` per `OPEN:` in `approvals/dr-open.md`. |
| `W-VISUAL` | UI GREEN needs approval; review its screenshot and record `approvals/green-visual.md`. |
| `W-BF-APPROVAL` | Bug-fix strategy is unapproved; record the decision in `approvals/bf-<X>.md`. |
| `W-ROUND` | Two phase/role rounds completed; obtain `approvals/rerun-<PHASE>-<role>.md`. |
| `W-PASTE` | Prompt copies ≥4,000 characters from a `.wave/` file; pass its path instead. |
| `W-BUDGET` | Phase output exceeds its budget; reduce rework or obtain `approvals/budget-<PHASE>.md`. |
| `W-EDIT` | Main session edits protected tracked source; delegate the edit to a subagent. |
| `W-READ` | Main session reads project source outside `.wave/`; locate, then delegate the read. |
| `W-BASH` | Main session runs a recognised build/test command; delegate that run. |
| `W-COMMIT-DOC` | Staged planning paths are guarded; unstage or approve via `approvals/commit-doc.md`. |
| `W-COMMIT-TRAILER` | Message contains a prohibited attribution/session line; remove it and retry. |
| `W-LONG-RETURN` | Return exceeds 2,000 characters; save the report under `.wave/reports/` and summarise. |
| `W-MODEL-UNKNOWN` | Requested tier is unmapped; warning only, verify the alias or update `models.tsv`. |
| `W-DESC` | Description exceeds 120 characters; warning only, shorten it or use a prompt-line tag. |
| `W-PROMPT` | Prompt exceeds 8,000 or 24,000 characters; warning only, move lengthy data to files. |
| `W-TAINT` | Transcript tier fell below the requirement; warning only, inspect fallback and proceed. |
| `W-DOWNGRADE` | Launch resolved below the requested tier; warning only, check model settings. |
| `W-RESOLVE-UNKNOWN` | Launch/model resolution is unreadable; verify the launch or transcript mapping. |
| `W-SESSION` | Active-wave banner or restart/staleness advisory; resume its checkpoint or close the wave. |
| `W-REMINDER` | Full/demo orchestrator reminder; follow the next allowed tagged dispatch. |
| `W-SCORECARD` | Terminal-phase spend summary is available; run the named scorecard command. |

Every `approvals/` path in the table is relative to `.wave/`. Rerun approvals
are phase **and role** scoped: `rerun-<PHASE>.md` alone does not count.

## 11.5 Ledger, checkpoints and commit guard

`SubagentStop` appends one record per agent to `.wave/ledger.jsonl`, including
failed hand-offs. It sums transcript assistant usage into input, output,
cache-read and cache-creation tokens, with requested/resolved models, phase,
role, turns, stop time and tier verification. Missing transcripts or oversized
ones are noted; absent usage fields count as zero. The transcript reader has a
byte cap. The ledger measures tokens, not currency.

`hooks/budgets.tsv` budgets output tokens per **phase total**, multiplied by
`phases.tsv`'s `fanout`. On the next dispatch, more than 1× warns; more than 2×
denies without `.wave/approvals/budget-<PHASE>.md`. Missing or unreadable ledger
data cannot justify a budget deny. Concurrent stops for one phase/role count
as one round; the third round needs the role-scoped rerun approval. `anytime`
phases bypass these gates.

`scripts/wave-scorecard.sh` writes `.wave/scorecard.md` with phase, role, model,
output, budget ratio and rework, plus GREEN output per changed line since
`base_sha` and the passing-test count in `green.md`. `Stop` provides a once-only pointer at the terminal phase
(`AD` full, `TEET` demo), tracked by `.wave/.scorecard-printed`.

Invariant 7's **checkpoint is enforced; its stop is advised**. `PreCompact`
writes `.wave/checkpoints/<ts>-precompact.md` directly from state and ledger:
goal, phase, artifacts, token totals, trigger and resume command. It spawns no
agent. An unwritable directory warns and allows compaction. The platform ignores
PreCompact output, so the hook cannot prevent compaction. On `SessionStart`
with source `compact`, the latest checkpoint is named with a fresh-terminal
advisory. `/wave-checkpoint` is the manual form; CCP separately requires a
`*-ccp.md` file.

Invariant 6 uses `scripts/hooks/pre-commit-guard.sh` on `Bash`. It recognises git
commit command shapes, checks staged paths against `hooks/planning-paths.tsv`
(including `.wave/**`) and checks visible message text for prohibited trailers
or session links. For `--amend --no-edit`, it reads the previous message.
Git inspection uses stdin `cwd`, including inside worktree subagents.

`wave-init.sh` also installs `.git/hooks/commit-msg` to inspect the final message
from a file, template, heredoc or editor. It never overwrites an existing hook:
it reports the conflict and records `skipped-existing` in state. The installed
Git hook is separate from Claude Code event hooks and currently checks messages
even after a wave closes; it does not consult `enforce`.

## 11.6 Escape hatch and lifecycle

`wave-init.sh --enforce warn` selects warning-only enforcement at wave creation;
the default is `block`. For an active wave, change `enforce` to `warn` in
`.wave/state.json`, retaining the other fields. Each event-hook deny becomes a
warning with the same rule id. This does not disable the separately installed
Git `commit-msg` hook. `wave-set.sh` accepts only
`ui|behaviour-change|cr true|false`, not an enforcement setting.

For a methodology repository that intentionally commits plan-shaped documents,
record the decision in `.wave/approvals/commit-doc.md`. This changes only
`W-COMMIT-DOC` to a warning. Approval records are local, not signatures or durable
audit history; a checkpoint can carry the committable account of an exception.

`wave-init.sh` excludes `.wave/` via `.git/info/exclude`, creates state and the
lock, archives a closed state and refuses to replace an active one without
`--force`. It accepts `--mode full|demo` or `--solo`, `--wave`, `--feature`,
`--ui|--no-ui`, `--cr|--no-cr` and `--enforce block|warn`. Set behaviour-change
scope afterwards through `wave-set.sh`. Its usage is in the script header;
there is no implemented `--help` switch.

`scripts/wave-close.sh` sets `status: "closed"` and `ended`. Terminal phase
completion also closes full/demo waves; solo has no automatic terminal phase.
An active state older than 24 hours produces a session-start close advisory.

## 11.7 Verification and rollback

Run the release gates from the plugin root:

```bash
bash tests/run.sh
bash tests/run.sh --coverage
bash tests/clean-clone-check.sh
bash tests/e2e.sh
```

The ordinary runner executes the fixture and shell cases and reports coverage
gaps; `--coverage` makes missing positive/negative rule controls a failing gate.
A filtered pass is not a release gate. The clean-clone check verifies the
committed tree in a clean checkout, so uncommitted documentation cannot satisfy
that check. `tests/tools/mutants-*.sh` are the focused mutation drivers: they
alter disposable copies and require neighbouring controls to catch each mutant.

The end-to-end gate checks real plugin registration and headless dispatch,
launch/stop accounting, warning delivery, wave-start permissions, commit-message
guarding and no-wave silence. When `claude` is unavailable it reports a skip;
a skip is not evidence of a successful load. For direct load inspection:

```bash
claude --debug-file /tmp/wave-hooks-debug.log --plugin-dir . -p ok
```

Confirm the log registers this plugin's hooks and contains neither
`Duplicate hooks` nor `Hook load failed`. `claude plugin validate` alone is
insufficient. Exercise denies only in a scratch project with an active wave;
a project without active state should remain silent.

For temporary rollback, close the wave with `scripts/wave-close.sh` to stop
plugin event enforcement, or keep it active in `enforce: "warn"` to diagnose
rules. To remove the layer completely, disable/remove the plugin and restart
the client. Inspect `.git/hooks/commit-msg` separately: remove only the guard
installed by `wave-init.sh`, preserving any pre-existing or subsequently edited
hook. Keep `.wave/` and its `.git/info/exclude` entry while recovery history is
useful; neither belongs in the tracked source tree.
