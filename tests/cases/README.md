# `tests/cases/` — case-file schema

`tests/run.sh` discovers every file under `tests/cases/**` (excluding this
README) whose extension is `.json` or `.sh`, runs it, and prints one
`PASS <name>` or `FAIL <name>: <reason>` line per case. A case's **name** is
its basename with the extension stripped (`lib-foo.json` -> `lib-foo`),
regardless of which subdirectory it lives in — names must be unique across
the whole tree.

## JSON case schema

```json
{
  "script": "pre-agent.sh",
  "env": { "SOME_VAR": "value" },
  "seed": {
    "state": "state/valid-full.json",
    "files": { "relative/path.txt": "file contents" },
    "transcripts": { ".wave/tr/agent.jsonl": "transcripts/all-opus.jsonl" },
    "staged": ["relative/path.txt"]
  },
  "stdin": { "hook_event_name": "PreToolUse", "...": "..." },
  "expect": {
    "exit": 0,
    "decision": "deny|block|warn|allow|silent",
    "rule": "W-TAG",
    "reason_template": "W-TAG",
    "reason_contains": ["substring the rendered reason must carry"],
    "stdout_absent": ["substring stdout must not carry"],
    "state_assert": ".status == \"active\"",
    "ledger_lines": 1,
    "files_absent": ["some/path"],
    "negative_control_for": "W-TAG",
    "harness_fails": true
  }
}
```

All fields are optional except `stdin`; `expect` fields are checked only when
present (a case does not need to assert every field).

- **`script`** — a hook script name. A bare name (no `/`) resolves to
  `scripts/hooks/<name>`; a path containing `/` resolves relative to the repo
  root (used by the harness's own fixture scripts under `tests/fixtures/`,
  never by a real hook case).
- **`ac`** / **`note`** — informational only, ignored by the harness: the AC id
  a case implements and a one-line statement of what it asserts, so a case's
  provenance travels with the case rather than living only in a report.
- **`env`** — extra environment variables exported to the script's process.
- **`seed.state`** — a path relative to `tests/fixtures/` (or an absolute
  path) copied to `<tmp-project>/.wave/state.json` before the run; an empty
  `.wave/lock` file is also created (mirroring `wave-init.sh`, which does not
  exist yet).
- **`seed.files`** — a map of project-relative path -> file contents, written
  before the run.
- **`seed.transcripts`** — a map of project-relative destination path ->
  fixture path (resolved under `tests/fixtures/`, or absolute). Each fixture is
  copied to that destination before the run. This is how a `SubagentStop` case
  points `agent_transcript_path` at a real multi-line JSONL transcript without
  restating its bytes inline: the fixture stays the single source of truth
  under `tests/fixtures/transcripts/`. A fixture that cannot be found fails the
  case loudly (`SEED-FAILED` in the case log) rather than running the hook
  against an absent file — which would silently assert the hook's
  "no transcript" path while claiming to test the opposite.
- **`seed.staged`** — paths (already written via `seed.files`) that are
  `git add`-ed in the temp project before the run, for cases that need a
  file to be staged rather than merely present.
- **`stdin`** — the exact JSON object piped to the script on stdin. Every
  top-level key, and every key under `tool_input`, must appear in
  `tests/fixtures/measured-keys.txt` — see that file for how to extend it.
  No field name may be invented (AC-405).
- **`expect.decision`** — one of:
  - `silent`: exit 0, empty stdout, empty stderr.
  - `allow`: exit 0 and the output is not a deny or block shape (may still
    carry a warn-style `additionalContext`).
  - `deny`: `{"hookSpecificOutput":{"hookEventName":"...","permissionDecision":"deny","permissionDecisionReason":"..."}}`.
  - `block`: `{"decision":"block","reason":"..."}` (SubagentStop only).
  - `warn`: `{"hookSpecificOutput":{"hookEventName":"...","additionalContext":"..."}}`
    — the same object as a deny/warn but with `additionalContext` and no
    `permissionDecision` (Global Constraint 5). A `SubagentStop` warn is a
    state/ledger side effect rather than an stdout shape; assert that kind
    with `assert_state` / `assert_ledger_lines` instead of `assert_warn`.
- **`expect.rule`** — the rule id (`W-...`) the rendered reason must carry.
  Declaring this makes the case the **positive** case for that rule id.
- **`expect.negative_control_for`** — the rule id this case proves does
  *not* fire on a neighbouring, otherwise-similar input (paired with
  `expect.decision: "allow"` or `"silent"`). Declaring this makes the case
  the rule's **negative control**.
- **`expect.reason_template`** — asserts the rendered reason starts with
  `[<rule>] ` (Interfaces: every `reasons.tsv` template starts that way).
  Byte-exact template comparison against `hooks/reasons.tsv` is Task 13's
  job, not this harness's.
- **`expect.reason_contains`** — a list of **literal** substrings the rendered
  reason (or, for a warn, the `additionalContext`) must contain. Literal, not
  glob or regex, because a reason quotes the offending dispatch and that text
  routinely carries `*`, `[`, `$` and `\`. Use it when an AC says the reason
  must *name* something (the active wave id, the offending prefix, the roles a
  phase defines) — `reason_template` only checks the `[<rule>] ` prefix. A
  substring MAY span a newline: the list is decoded whole rather than read line by
  line, so a two-line needle is one assertion. It used to be split on newlines
  into two independent single-line assertions, both of which a reason can satisfy
  without ever containing the two-line string the case asked for.
- **`expect.stderr_contains`** — a list of **literal** substrings stderr must
  contain. `SubagentStop` and `PreCompact` have no `additionalContext` channel, so
  a warning on those events reaches the operator on stderr and nowhere else; this
  is how a case asserts that it was actually emitted rather than merely that it
  did not break the decision.
- **`expect.stdout_absent`** — a list of literal substrings that must **not**
  appear anywhere in stdout. This is how a case proves a rule did not fire (no
  `W-MODEL-UNKNOWN` token) and how an injection case proves the hook treated
  its input as data (no `uid=` from a substituted `id`).
- **`expect.state_assert`** — a `jq` boolean filter evaluated against the
  temp project's `.wave/state.json` after the run.
- **`expect.ledger_lines`** — the exact line count of
  `.wave/ledger.jsonl` after the run (0 if the file never got created).
  Because `wc -l` counts newlines, `ledger_lines: 1` also proves the file ends
  in exactly one newline.
- **`expect.ledger_assert`** — a `jq` boolean filter evaluated against the
  **last** line of `.wave/ledger.jsonl` (the line the run appended). The line
  must parse, so this doubles as the append-integrity check: a torn or
  interleaved line fails `jq -e`.
- **`expect.ledger_prefix_unchanged`** — an integer *n*: the first *n* lines of
  `.wave/ledger.jsonl` must still be byte-identical to the first *n* lines the
  case seeded via `seed.files[".wave/ledger.jsonl"]`. Append-only is a stronger
  claim than the line count, which a rewrite can also satisfy.
- **`expect.files_absent`** — project-relative paths that must not exist
  after the run.
- **`expect.harness_fails`** — see "Self-check cases" below.

A case may instead be a `tests/cases/<area>-<name>.sh` script for multi-step
or concurrency scenarios. It is executed directly (not sourced); it must
`source "$(dirname "$0")/../lib/assert.sh"`, drive `run_hook` itself as many
times as it needs (e.g. to fire N concurrent callers against one seeded
project), and exit 0 for PASS / non-zero for PASS, printing its own diff on
failure. Every `run_hook` call it makes writes the same positive run marker
as the JSON path, so the harness's "case log carries its run marker" check
covers `.sh` cases too.

## The rule-id coverage self-check

The id universe is the union of every `expect.rule` / `expect.negative_control_for`
value declared anywhere under `tests/cases/`, plus every id in
`hooks/reasons.tsv` when that file exists (it does not yet — Task 3 creates
it; until then the file simply contributes nothing to the universe). For
every id in that universe, at least one case must declare it via
`expect.rule` (a positive case) **and** at least one case must declare it via
`expect.negative_control_for` (a negative control on a neighbouring valid
input). `tests/run.sh` fails, naming the id, when either is missing
(AC-402).

## `tests/fixtures/state/` and `tests/fixtures/transcripts/`

`tests/fixtures/state/example-active.json` is a minimal `{"status":"active"}`
placeholder used only by this task's own smoke test
(`tests/fixtures/fake-hook.sh` only ever looks at `status`). The real,
schema-complete state fixtures (`valid-full`, `invalid`, `schema2`, `no-mode`,
`enforce-typo`, `no-enforce`, `closed`) are added in Task 2 once
`scripts/hooks/lib.sh` defines the schema they exercise.

`tests/fixtures/transcripts/example.jsonl` is one line in the shape measured
in spec section 2 (`type":"assistant"`, `message.model`, `message.usage.{input_tokens,output_tokens,cache_creation_input_tokens,cache_read_input_tokens}`),
kept only to document that shape. It is not read by anything yet — Task 8
adds the real scenario fixtures (`all-opus`, `one-haiku`, `all-haiku`,
`zero-assistant`, `model-less`, a truncated final line, an over-cap file)
that `wv_transcript_stats` is tested against.

## Self-check cases (`tests/cases/_selfcheck/`)

These cases test the harness itself, not any hook. Each one is a
deliberately broken or incomplete fixture that exercises one of the five
built-in detections:

1. a case naming a script that does not exist,
2. a case file that is exactly 0 bytes,
3. a case file that is not a parseable JSON object,
4. a case whose `stdin` uses a key absent from `measured-keys.txt`,
5. a rule id with a positive case (`expect.rule`) and no negative control.

For (1), (3) and (4) the case JSON carries `"expect": {"harness_fails": true, ...}`.
A case with `harness_fails: true` inverts the normal PASS/FAIL meaning: it
PASSes when the harness's own checks correctly rejected it, and FAILs if the
harness let the defect through undetected.

(2) cannot carry that field — a 0-byte file cannot carry any JSON — so the
inversion is instead keyed on location: **a 0-byte case file is always a
plain failure of the suite, except when it lives under
`tests/cases/_selfcheck/`, where it is understood to be the deliberate
self-check of the "0 bytes" detector** and is reported PASS once that
detector correctly flags it. A 0-byte file anywhere else in the corpus is a
real bug and is never inverted. The same inversion applies to a case file that
is not parseable JSON (`_selfcheck-unparseable.json`), which is that detector's
planted control — AC-401 names the detection, and without a control it was code
no case had ever executed.

`tests/cases/_selfcheck/` also carries one ordinary (non-inverted) case
proving the plumbing end to end — seeding an active state fixture, running a
throwaway test-only script (`tests/fixtures/fake-hook.sh`, never wired into
`hooks/hooks.json`), and asserting the deny JSON shape, the single-rule-token
rule, the reason-template prefix, the ledger line count and the state
assertion all in one pass.

## Suite-level behaviour

`tests/run.sh` exits non-zero if any case fails, if the number of cases it
executed is fewer than the number of case files it discovered (a sign the
run loop bailed out early), if any case file is 0 bytes or unparseable
(outside the exemption above), or if a case's log is missing its positive
run marker (`RAN <script> <case> decision=<x>`) after the harness attempted
to run it.

**Coverage gate (default: disabled).** The harness always scans for rule IDs
with no positive test case and no negative control. By default, it prints these
lines but does not fail (exits 0 and does not increment `failed=`). To enforce
coverage at release time, run with `--coverage` flag: `tests/run.sh --coverage`
fails if any rule lacks cases. During development, the default mode lets you add
test cases incrementally without blocking other work.

**A suite that cannot run at all — the whole file, not one case — is
reported `SKIPPED`, never counted as a pass.** This applies repo-wide: for
example `tests/e2e.sh` (added in a later task) is documented to skip itself
loudly when `claude` is not on `PATH`; a `SKIPPED` suite must never be
reported or logged as if it had passed.
