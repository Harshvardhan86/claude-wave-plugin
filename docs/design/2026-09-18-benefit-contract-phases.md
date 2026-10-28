# Benefit contract, user-intent and empty-state phases (v0.3.0)

Status: design, 2026-09-18, revised after two independent adversarial reviews against the code. Extends `2026-09-09-hook-enforcement.md`; where the two disagree, this document wins and says so.

## 1. Why

Three failure classes survive the 0.2.x pipeline with every gate green.

1. **The module is correct and the feature does nothing.** A wave whose success criterion is "build the component and touch nothing else" runs every control on the component and none on the outcome. RED and GREEN are written from the same brief, `[OA]` compares the build with the spec, and mutation testing measures only the tests that exist. None of them asks whether the behaviour the wave was for actually happens.
2. **Acceptance criteria are written in the builder's vocabulary.** "The `status` enum gains `ON_HOLD`" is testable and says nothing about what a person sees. Waves that add a new kind of record, or a new value of an existing one, need criteria in the user's voice first.
3. **The screen is only ever tested with data in it.** On the day of a deploy there are no records of the new kind. Anything whose presence depends on a non-zero count is absent for every real user, and every fixture-seeded test passes.

0.3.0 adds five phase rows, one scope flag, one condition keyword and a close-time delivery verdict for these. It also repairs two defects in how a wave closes (section 9), because the verdict depends on them.

Out of scope, planned for 0.3.1: a production walk and a first-time-user walk after deploy, and an end-to-end run against a baseline with no new-vocabulary records. They need a `deploys` flag and cannot be verified locally the way this change can.

## 2. Summary of the table change

| # | Code | Condition | After | Artifact | Marker (POSIX ERE, as it appears in the TSV) |
|---|---|---|---|---|---|
| 0.5 | `UIA` | `vocabulary` | (none) | `.wave/uia.md` | `^UIA-[0-9]+` |
| 0.8 | `BEN` | `behaviour_change` | `UIA` | `.wave/ben.md` | `^BEN-VERIFIED red=[1-9][0-9]* authorities=[1-9][0-9]*$` |
| 1 | `AC` (existing) | always | **`UIA,BEN`** (was empty) | unchanged | unchanged |
| 4.2 | `ES` | `vocabulary` | `BF-BC` | `.wave/findings/ES.md` | `^FINDINGS: [0-9]+$` |
| 4.3 | `BF-ES` | `findings:ES` | `ES` | `.wave/bf-ES.md` | `^BF-VERIFIED` |
| 5 | `SEA` (existing) | always | **`BF-ES`** (was `BF-BC`) | unchanged | unchanged |
| 12.5 | `BEN-CLOSE` | `done:BEN` | `BTEET-X,BF-BTEET` | `.wave/ben-close.md` | `^BENEFIT: (DELIVERED` &#124; `UNDELIVERED)$` |
| 13–16 | `VB`, `COMMIT`, `CL`, `CCP` (existing) | always | **`BEN-CLOSE`** (was `BTEET-X,BF-BTEET`) | unchanged | unchanged |

The `BEN-CLOSE` marker is the single ERE `^BENEFIT: (DELIVERED|UNDELIVERED)$`; the table above splits it only because a pipe cannot sit inside a Markdown cell. The TSV carries it unescaped, as `ui|behaviour_change` already is.

All five new rows are `full` only, `when=phase`. Demo keeps its five phases. `AD` stays the last row of the file. The table grows from 26 rows to 31, from 78 tier cells to 93, from 6 self-naming findings rows to 7, and the budgets table from 26 rows to 31. `reasons.tsv` grows from 37 rules to 38 (section 5.4).

| Code | fanout | lead | executor | reviewer | budget (same as) |
|---|---|---|---|---|---|
| `UIA` | 1 | opus | sonnet | opus | `AC` |
| `BEN` | 2 | opus | sonnet | opus | `AC` |
| `ES` | 1 | - | sonnet | - | `SEA` |
| `BF-ES` | 1 | opus | sonnet | opus | `BF-SEA` |
| `BEN-CLOSE` | 1 | opus | sonnet | opus | `OA` |

No new framework role names: the new teams use the tag roles directly, as the `AC` team does. `roles.tsv` is unchanged. `framework/SKILL.md`'s phase table is the stated source of `tests/golden/phases-tiers.tsv`, so the five rows are added there first.

**The table rows and the `case` arms that understand their conditions ship in one commit.** An unknown condition keyword fails open, so a table that lands ahead of its arms would make `UIA` run for every wave.

## 3. The `vocabulary` scope flag

`vocabulary` answers: *does this wave introduce a new kind of record, or a new value of an existing classification, that a user will see?* A new entity, a new status, a new category, a new role. It is the trigger for `UIA` and `ES`.

- `wave-init.sh` writes `vocabulary` into `state.json`, default `"unknown"`, and gains `--vocabulary` / `--no-vocabulary`. It also gains `--behaviour-change` / `--no-behaviour-change`; until now `behaviour_change` was always written `"unknown"` and could only be set afterwards.
- `wave-set.sh` gains the key `vocabulary`.
- `wv_state_read` appends `vocabulary` as a ninth field and exports `WV_VOCAB`.
- The schema stays at 1. A flag **absent** from `state.json` reads as the empty string, which is neither `true` nor `unknown`, so it behaves as false; this is how the engine treats every absent field today. Bumping the schema instead would leave every in-flight wave unenforced.
- `wv_scope_ready`, the `TDE-RED` scope gate, is **not** changed. It is mode-blind, so adding `vocabulary` there would deny every demo wave at `TDE-RED` over a flag no demo row reads; and in full mode section 3.1 already forces the answer earlier.

### 3.1 A full-mode wave needs both answers before `AC`

`AC` names `UIA` and `BEN` as predecessors. A predecessor whose flag is `unknown` denies the successor with `W-SCOPE`, by the existing rule that an unanswered condition is never skipped through. So `AC`, and every row after it, cannot be dispatched until `vocabulary` and `behaviour_change` are both answered. The gate enforces each flag only where it is read: `UIA` needs `vocabulary` alone, `BEN` needs `behaviour_change` and a settled `UIA`. Asking both before the first dispatch is the command's policy (`/wave-start` asks them before `wave-init.sh`), not a gate rule; `tests/cases/scope-v030-new-rows.sh` pins the mixed answered/unknown states. `ui` and `cr` may still wait until `TDE-RED`.

This withdraws the 0.2.x statement "earlier phases stay dispatchable; a wave has to be able to start" (the comment above the scope gate in `pre-agent.sh` is rewritten). It is accepted because the alternative, hanging `UIA` and `BEN` off `TDE-RED` the way `DR` is, would let the criteria and the design be written before the benefit is stated, which is the failure the phase exists to prevent.

- `/wave-start` Step 0 asks four questions, and asks the two early ones **before** `wave-init.sh`, whose invocation gains the two flag pairs. `ui` and `cr` keep their `wave-set.sh` route.
- The two flags sit on separate rows, so a wave with both unanswered is told about them one dispatch at a time (`vocabulary` first). Accepted; the command asks both up front, so this only meets someone driving the scripts by hand.
- Demo is unaffected, because `wv_phase_done` and its advisory twin test the row's **mode before its condition**: a full-only predecessor is skipped in demo without its flag ever being read. `TEET` already relies on this for `TEET-TC`. `AC` becomes the first demo row whose full-only predecessors are conditional, so the ordering gets a test of its own.

### 3.2 The advisory evaluator must stop contradicting the gate

`wv_up_condition_met` collapses "unanswered" into "not met", and `wv_up_phase_settled` reads "not met" as skipped. With both flags unknown the prompt reminder would announce `AC` as the next allowed phase on every prompt while the gate refuses every `AC` dispatch. (The same disagreement exists today between `DR` and `TDE-RED`; it becomes the first thing every user sees.)

The advisory evaluator gains a third outcome, *unanswered*: the row is treated as **required and not yet allowed**, never as skipped. `wv_next_allowed_phase` then returns the unanswered row itself, or `none`, and never a successor. `wv_up_phase_settled` does not encode this as a bare non-zero, which it would read as skipped. A test asserts that the advisory and the gate agree at `AC` and at `SEA` for every combination of the two flags over `true`, `false`, `unknown` and absent.

## 4. `[UIA]` user-intent criteria (0.5)

Input: the feature statement. Output `.wave/uia.md`, one block per criterion, each heading matching `^UIA-[0-9]+`:

> As a *role*, when I *action* against *data state*, I expect *observable outcome*.

Each criterion names one of three pinned data states (section 6). `AC` receives `uia.md`, and every `UIA-n` must be covered by at least one `AC-n`. `[OA]` maps both sets to evidence; either failing is a gap in the alignment percentage.

## 5. `[BEN]` the benefit contract (0.8) and `[BEN-CLOSE]` (12.5)

### 5.1 At the start: three artifacts in `.wave/ben.md`

1. **The Benefit AC.** Exactly one. A sentence whose grammatical subject is not the new component and whose verb is what the user or the surrounding system does differently once the feature exists. **It may not name any symbol the wave introduces**; that is mechanically checkable by searching the sentence for the new identifiers, and the reviewer does so. It is backed by one named, executing test, which the `BEN` executor writes and runs (a subagent may edit and run tests in any phase), and which must fail for the right reason. `red=<n>` in the marker is the number of failing benefit tests and must be at least 1.
2. **The authority census.** Name the decision the feature influences. Then list, by reading code, every existing component that already decides that same outcome: location, how it decides, what its input is, what happens when it and the new feature disagree, and how the disagreement resolves. The census must include the authority that produces the outcome named in the Benefit AC; that is what makes the two artifacts interlock. `authorities=<n>` must be at least 1: a feature that influences a decision nothing makes today is a new decision, and the census says so in one row.
3. **Integration count, sign inverted.** The number of files the wave expects to change outside the feature's own directory. A behaviour-changing wave with a count of 0 or 1 has been *hosted, not integrated*: a finding that needs a written justification naming the existing mechanism that will carry the behaviour. "Untouched" is not a score; every row of the blast-radius table is the question "must this change, and why not?".

`AC`, `ACB` and `DR` receive `ben.md`.

The `TDE-RED` and `TDE-GREEN` markers remain self-attested counts; the engine does not cross-check them against `red=`. That the benefit test is among the red tests, and is green or deliberately excluded at GREEN, is a reviewer contract for the `TDE-RED` verifier and `[OA]`. If the benefit can only be observed end to end, `ben.md` says so and names the command; `[TEET]` runs it.

### 5.2 At the close: `.wave/ben-close.md`

After the last hardening phase and before version bump and commit, a separate team:

1. Runs the named benefit test and records the command, the exit status and the tail of the output. Where the benefit test is part of the unit run it has been green since `TDE-GREEN`, and this step is a regression check; the next two steps then carry the phase. Where it is end to end, this is its decisive run.
2. **Orphan-state sweep.** For every new class, table, flag or state the wave introduced, searches for production readers outside the feature's own directory. Zero external readers means the rest of the system cannot see it: name the reader that should exist, or justify.
3. **Defeat list.** Searches the wave's own new comments and documents for any statement that the existing system undoes, ignores or overrides the feature. Each is a requirement unless a named test guards it.
4. Writes the verdict line: `BENEFIT: DELIVERED` only if the benefit test passed **and** neither list contains an unjustified item; otherwise `BENEFIT: UNDELIVERED`, followed by the reasons.

Both verdicts satisfy the marker, so an undelivered wave can still be committed and closed. That is deliberate: a hard block here invites weakening the Benefit AC to get out. What the plugin guarantees instead is that the verdict cannot be silent.

### 5.3 `done:BEN`, a new condition keyword

`BEN-CLOSE` runs when `BEN` ran. `done:<CODE>` is met when `state.phases[CODE].status` is `done`; unanswered when the source row's own condition is unanswered; not met when the source does not run in this wave, or is **superseded** (section 10); otherwise **pending** on the source: the row waits for it, and the order gate names the source in `W-ORDER`. A wave started under 0.2.x whose `AC` was already done is not asked for `BEN` (the order walk stops at the done `AC`, the only row that names `BEN`), and with `done:BEN` it does not suddenly owe a close-time verdict over a contract nobody wrote: its tail is unchanged. A 0.3.0 wave whose behaviour-change answer is corrected to `true` after `AC` is not legacy: `BEN` is still dispatchable (its only predecessor is `UIA`), `BEN-CLOSE` and the tail wait for it, and the wave stays open until it has run.

### 5.4 The delivery verdict: state, scorecard, and a rule that announces it

`wave-close.sh` folds a `delivery` field into its single state write. The verdict line is found with the same predicate the stop marker uses, the first line of the file matching the ERE, so the two can never disagree.

| `BEN` done | `behaviour_change` | first matching line of `.wave/ben-close.md` | `delivery` |
|---|---|---|---|
| any (solo, or a mode the `BEN` row's `modes` cell does not list, such as demo) | any | n/a | `not-applicable` |
| no | `false`, or absent | n/a | `not-applicable` |
| no | `true` or `unknown` | n/a | `unverified` |
| yes | any | `BENEFIT: DELIVERED` | `delivered` |
| yes | any | `BENEFIT: UNDELIVERED` | `undelivered` |
| yes | any | file absent or no matching line | `unverified` |

Nothing unanswered or missing ever reads as a pass. The first row is read from `hooks/phases.tsv`, never a hard-coded mode name: the contract cannot apply where its phase does not run, and a table with no `BEN` row falls through to the rows below, so a missing table never reads as a pass.

`wave-scorecard.sh` prints a `## Delivery` section directly under the title whenever `delivery` is set, including on a wave with an empty ledger (the early return prints the title and this section first). For `undelivered` it quotes the reasons from `ben-close.md`; for `unverified` it says the benefit was never checked at close.

A new warning, **`W-UNDELIVERED`** (rule 38), is emitted by the hook call that closes the wave whenever `delivery` is `undelivered` or `unverified`, always in the same call as a scorecard pointer (section 9). `wave-close.sh` run by hand prints the same sentence. Under `--if-complete` it prints nothing to stdout, as today, and its stderr is discarded by the caller, so the hook reads `delivery` back from state and emits the rule itself.

## 6. Data-state matrix on acceptance criteria

Not a new phase. Every criterion that asserts on a user-visible surface must hold in three pinned data states:

- **empty**: no records at all;
- **partial**: only records that existed before the wave, none of the new kind. This is what every installation looks like on the day of the deploy;
- **full**: records in every value the wave introduces.

`ac-writer` writes a `**Data states:**` line per UI criterion. `[ACB]` rejects criteria conditional on data being present ("when a hold exists, …") unless the same criterion states the absent-data outcome, and hunts absent-data gaps explicitly. This is a skill and reviewer contract; the marker `^AC-[0-9]+` is unchanged, because a marker is one regex per row and cannot depend on `ui`.

## 7. `[ES]` empty-state scan (4.2) and `[BF-ES]` (4.3)

A scanner, like `SEA`: no lead, no reviewer, a findings file whose first matching line is `FINDINGS: <n>`, and a `BF-` row that runs only when `n >= 1` and requires `.wave/approvals/bf-ES.md` by the existing `BF-` prefix gate.

The scan reads the data-state matrix in `ac.md`, and for each user-visible surface in scope simulates the partial state and the empty state. It reports any element whose visibility, presence or rendering depends on a count being non-zero, with file and line, unless a criterion explicitly accepts hiding it.

### 7.1 Engine change: a scan that will never run has nothing to fix

Today every scanner row is `always`, so the `findings:<CODE>` arm assumes its scan will run: with no findings file and the scan not done it returns *pending*, and the successor waits. `ES` is the first conditional scanner. With `vocabulary=false` it is skipped, `findings:ES` would be pending for ever, and `SEA` could never be dispatched.

The change is confined to the branch that returns *pending* today. The order of the arm is otherwise untouched, because a scan the ledger records as done is done whatever its condition now says (the invariant `wv_phase_done` states one level up): a findings file that exists is counted, and a missing file for a done scan is still `W-ARTIFACT`, even if `vocabulary` was flipped to false afterwards.

On the pending branch only, a new helper reports whether the source row applies to this wave, from its mode and its condition keyword alone, with no file reads:

- not in this mode, or condition false → the arm returns *not met*, with the caller's own `WV_COND_TEXT` (`findings:ES`) intact and the detail "`ES` does not run in this wave, so there is nothing for `BF-ES` to fix";
- condition unanswered → the arm returns 2 carrying the source's `W-SCOPE` arguments;
- applies → *pending*, as today.

`wv_condition_met` resets its five `WV_COND_*` globals on entry, so the helper does not call it recursively without saving and restoring them; the design requirement is that a denied `BF-ES` names `findings:ES`, never `vocabulary`. The source of a `findings:` or `done:` row may not itself be conditioned on `findings:` or `done:`; a data test pins that, which bounds the evaluation at one level.

The new lines are a flat addition. **No existing line of the `findings:*` arm is re-indented or re-worded**, and the two `wv_unanswered_scope … && return 2` lines stay byte-identical: mutants 13, 24, 25, 26 and 27 anchor on that text, and a mutant that no longer applies fails its driver. The advisory evaluator already treats a missing file as not met, so it needs only the unanswered outcome of section 3.2. `wv_required_because` gains clauses for `vocabulary`, `behaviour_change` and `done:`, so a `W-ORDER` naming `UIA` says why `UIA` is required.

### 7.2 Engine change: a closed condition vocabulary

An unknown condition string fails open in both evaluators. That stays the right run-time behaviour for a table newer than the scripts, but nothing stops the shipped table carrying a typo. A data test pins the shipped `condition` column to the closed set `always`, `ui|behaviour_change`, `cr`, `vocabulary`, `behaviour_change`, `findings:<a scanner row>`, `done:<a row>`, and pins that every keyword that can make a row conditional (all but `always`) has an arm in each of the three `case` statements.

## 8. Other engine touch points

- `wv_stale_successors` caps its walk at 30 generations; the longest chain becomes 27 nodes, so the literal still holds. It is nevertheless derived from the row count, and the "26-row" comment goes.
- The visual gate (every phase structurally after `TDE-GREEN` waits for the visual approval when `ui=true`) extends to `ES`, `BF-ES` and `BEN-CLOSE` by construction. Intended.
- `BEN-CLOSE` is nine characters, the same as `TDE-GREEN`; the session banner budget is unaffected.

## 9. How a wave closes (repairs two 0.2.x defects)

**Defect 1.** The terminal phase is derived as the last table row of the mode. In full mode that is `AD`, an `anytime` row with no artifact, exempt from the order gate. The first time a dashboard executor stops, the wave closes, whatever else has or has not run, and every hook is silent for the rest of the work.

**Defect 2.** The Stop hook prints the scorecard pointer when the wave is active and its terminal phase is done. The hook call that records the terminal phase as done closes the wave in the same breath, so in full and demo mode the two conditions are never true together outside a blocked stop. The fixtures that exercise the pointer seed a state the engine cannot durably produce.

**Repair.** The notion of a terminal phase is replaced by **wave complete**: every `when=phase` row of the active mode is settled, meaning done, or skipped by mode or condition. An unanswered condition is not settled, and neither is an unmeasurable one (a findings file without a `FINDINGS: n` line, an unreadable file, a scan that returned no count): the gate denies or fails open there, it never skips. `anytime` rows never count, and only a `when=phase` row's stop triggers the close, so an `AD` stop never closes a wave, not even one that is already complete. One function in `lib.sh` replaces the three copies of the terminal-phase derivation (`wave-close.sh`, `stop.sh`, the leftover inventory).

- `subagent-stop.sh`: when the closing role's stop of a `when=phase` row records it done, with no block, and the wave is now complete, it takes the leftover inventory (previously at the terminal role's close), runs `wave-close.sh --if-complete`, and reads `state.json` back. Only when it reads `closed` does it announce, on stderr, through one composition in `lib.sh` (`wv_close_announce`): `W-LEFTOVER` when leftovers exist and no earlier call warned of them (it names the scorecard, so it is this call's pointer), then `W-UNDELIVERED` when section 5.4 calls for it and it has not been told, then `W-SCORECARD` unless `W-LEFTOVER` went out in this call — forced whenever a verdict was queued, so a verdict never goes out without a same-call pointer, and otherwise once per wave when the ledger is non-empty. Each marker (`.leftover-warned`, `.undelivered-warned`, `.scorecard-printed`) is written after its warning is queued, in the same call. A close that did not happen gets `W-STATE` alone ("complete but could not be closed", naming `scripts/wave-close.sh`); nothing is announced or marked, and the next closing stop retries.
- The closing role's stop of a final row (one no other `when=phase` row of the mode names in `after`: full `VB`, `COMMIT`, `CL`, `CCP`; demo `TEET`) whose every other row is settled takes the inventory whatever its outcome, so a wave that ends on a failed final row — which never completes — still warns `W-LEFTOVER` once, without closing.
- `stop.sh` never closes a wave and, in full and demo mode, never announces one. On a wave that is complete but still active (the close failed, the final stop was blocked, or the remaining rows were skipped without a closing stop) it refreshes the leftover inventory and emits only `W-STATE`: complete but not closed, noting leftovers when found, with the remedy `scripts/wave-close.sh`. No verdict, no pointer, no marker; it repeats on every Stop until the wave is closed, and an incomplete or closed wave is silent. In solo mode, which has no close and whose verdict is always `not-applicable`, a non-empty ledger gets the same `wv_close_announce` composition.
- `wave-close.sh` gains `--if-complete`. `--if-terminal <PHASE>` is kept as an accepted alias with the same meaning, its argument ignored, so nothing that calls it breaks. Bare `wave-close.sh` is unchanged: a person may close a wave at any point, and section 5.4 then records the honest verdict. Both forms take the wave lock before reading the state that authorises the close, then re-read it, check it is the same active wave (id and start time) they first saw, decide completeness and delivery, and write, all under that one lock; a wave changed while they waited is not closed (the bare form says so and exits 1).
- Full mode therefore closes when `VB`, `COMMIT`, `CL` and `CCP` are all done; demo closes when `TEET` is done, as before.
- **A superseded row is settled.** Completeness and the advisory read the same legacy discriminator the order gate reads (section 10, `wv_row_superseded`), so an upgraded wave that the gate lets finish also completes and closes, `unverified` when it changed behaviour.

## 10. Compatibility and upgrade

- **Schema** stays 1. No state migration. No hook goes silent.
- **Waves in flight across the upgrade:**
  - `AC` not done, `behaviour_change` `unknown` → `AC` is now denied `W-SCOPE` until it is answered (it was always written `unknown` by 0.2.x).
  - `AC` not done, `behaviour_change` `true` → `BEN` is required before `AC`, and `BEN-CLOSE` before the tail.
  - `AC` done → `BEN` is superseded: not required by the gate, settled for completeness, never named by the reminder; `BEN-CLOSE` is skipped (`done:BEN` not met), the tail is unchanged, and the closing stop closes the wave. If `behaviour_change` is `true` the verdict is `unverified` and is said once. (`BEN` may still be dispatched by choice; once it has an entry in `.phases` it is no longer superseded and runs to the end like any other row.)
- **The legacy discriminator** (`scripts/hooks/lib.sh` `wv_row_superseded`, the one definition the gate's `done:` arm, completeness and the advisory all call). A row is superseded when all three hold:
  1. `state.json` has no `vocabulary` key. Every `wave-init.sh` since 0.3.0 writes it (`"unknown"` by default), so its absence identifies a wave started by an earlier plugin without a schema change. Answering `vocabulary` with `wave-set.sh` on such a wave writes the key and ends the exemption.
  2. The row has no entry in `.phases` (it was never dispatched).
  3. A row whose `after` names it is recorded done. This mirrors the order walk's own stop (`pre-agent.sh` `wv_after_unmet_walk`: "a predecessor the state records as done ends the walk"), which is why the gate never asked for such a row.
  Condition 3 looks only at rows that name the row directly in `after` (for `BEN`, `AC`). A state the discriminator cannot classify as legacy is treated as a 0.3.0 wave.
- **`created_by`.** `wave-init.sh` writes an additive state field `created_by`, the plugin version from `.claude-plugin/plugin.json` (schema stays 1; a state without it was created before 0.3.0; `wave-set.sh` never writes it). The 0.2.x → 0.3.0 exemption above still keys on the absent `vocabulary` key; the next release keys its exemptions on `created_by` against the version that introduced each row, because the absence of a later flag stops meaning anything once that flag is set by hand. Bare `scripts/wave-close.sh` remains the supported way to close any wave by hand, and records the honest verdict; never change `behaviour_change` to get a wave closed.
  - `vocabulary` is absent in every 0.2.x state file → `UIA` and `ES` are skipped.
  - A wave whose dashboard has not yet been dispatched no longer closes when it is; a wave already closed that way stays closed.
- **New waves:** `/wave-start` asks four scope questions. A wave driven by hand must answer `vocabulary` and `behaviour-change` before `AC` (section 3.1).
- **Solo mode:** unchanged. **Demo mode:** unchanged phases and gates; it closes on `TEET` as before.
- Anything that parsed "`AD` closes the wave" out of the 0.2.x spec must use wave complete instead; section 9 supersedes sections 4 and 8 of that document on this point.

## 11. Tests (written first) and every pinned artefact that moves

Counts and lists, each updated in the same commit as the table: `tests/cases/data-all.sh` (26 → 31 rows, the ordered phase list literal, 78 → 93 cells, 26 → 31 budgets, 37 → 38 rules), `data-tier-cells.sh` (78), `data-budgets-full.sh` (26), `data-artifacts-markers.sh` (expected table and 26), `data-findings-column.sh` (the six self-naming rows become seven), `data-after-dag.sh` (first row is `UIA`; `SEA←BF-ES`; the tail's shared `after`), `data-reasons.sh` (37), `tests/golden/phases-tiers.tsv`, `tests/golden/budgets.tsv`, `tests/golden/reasons-precedence.tsv`, `tests/tools/mutants-tier-cells.sh` (hard abort unless 78), `tests/tools/gen-pre-agent-cases.sh` (`PHASES`, the tier table, `P2_CHAIN`, the state writers gaining `vocabulary`, new all-done fixtures with `behaviour_change` and `vocabulary` true; the generated corpus is regenerated, never hand-edited), `lib-state-unknown.sh` (`WV_VOCAB`), `init-354`, `init-356` (it asserts there is no `--behaviour-change` flag), `init-360`, `init-362a/b`, `init-374` (the command's flag and key assertions), `tests/e2e.sh` `wv_e2e_seed_wave` (seeds `vocabulary`, and its comment about the missing flag goes), the notes in `order-067a/b` and `order-107`, `budget-178`'s prose.

Close redesign: `init-363`, `init-364`, `init-364b`, `stop-227` (its `AD` leg flips: an `AD` stop leaves the wave active; a new leg closes on the last tail phase), `bgwait-434`, `leftover-423/424/425/431/433`, `stopcard-320/321/322/323/324` and their fixtures, `tests/lib/assert.sh`'s seeded `AD` ledger line, mutant `terminalskip` and the lifecycle mutants that anchor the scorecard and leftover lines.

New behaviour, each with a negative control:

- both flags unknown → `AC`, `UIA`, `BEN` denied `W-SCOPE`; answered false → `AC` silent with `ui`/`cr` still unknown (the rewritten `scope-111`); demo with every flag unknown → `AC` silent.
- advisory and gate agree at `AC` and `SEA` for all sixteen flag combinations (3.2).
- `vocabulary=true`: `AC` before `UIA` denied `W-ORDER` with a required-because clause; `SEA` before `ES` denied; `BF-ES` with `FINDINGS: 0` denied `W-COND`; with `FINDINGS: 2` and no approval, denied by the `BF-` gate.
- `vocabulary=false` and absent: `UIA`, `ES`, `BF-ES` denied `W-COND`, the `BF-ES` text naming `findings:ES`; `SEA` dispatchable straight after `BF-BC`.
- `vocabulary=unknown` at `SEA` → `W-SCOPE`, never skipped through.
- `ES` done with `FINDINGS: 2`, then `vocabulary` flipped to false → `BF-ES` still met (7.1's ordering).
- `behaviour_change=true`, `BEN` done: `COMMIT` before `BEN-CLOSE` denied. `BEN` not done and `AC` done, the outcome depends on the wave: with `behaviour_change=false`, `COMMIT` allowed (5.3); with `behaviour_change=true` in a 0.3.0 wave (`vocabulary` key present), `COMMIT` denied `W-ORDER` naming `BEN` (`done:BEN` is pending, section 5.3); with `behaviour_change=true` in a wave started before 0.3.0 (no `vocabulary` key), `COMMIT` allowed because `BEN` is superseded (section 10). Generated cases `order-commit-ben-not-done-allow`, `order-commit-ben-not-done-bc-deny`, `order-commit-ben-not-done-legacy-allow`.
- `BEN` stop with `red=0` or `authorities=0` fails the marker; `BEN-CLOSE` accepts both verdicts and rejects anything else.
- tier cells: an allow case and a one-tier-below deny case for every non-`-` cell of the five rows, from the generator.
- `wave-init` writes `vocabulary`; the four new flags; conflicting flags refused with state untouched. `wave-set vocabulary true|false`, other values refused.
- `wave-close`: every row of the 5.4 table; verdict on line 5 of the file still read; stdout empty under `--if-complete` and under the alias; an `AD` stop does not close; the last tail phase does; a skipped tail row does not block the close; an unanswered flag does.
- `W-UNDELIVERED`: positive and negative control, reason within 400 characters, emitted once, corpus and replay clean. Scorecard `## Delivery` present with reasons, absent when unset, present on an empty ledger.
- closed condition set and the one-level rule (7.2, 7.1).
- new mutants: the pending-branch rule in both directions, the `done:` arm, the unanswered advisory outcome, the 5.4 mapping ("absent reads as delivered"), wave complete ("`anytime` rows count", "unanswered counts as settled").

Release gates are the 0.2.1 set, run on the host: full run with `--coverage`, pinned clock, reason corpus and `--replay-enforce`, all mutation drivers, clean-clone run, real-client load check, and the end-to-end scenarios.

## 12. Documents that change

`README.md` (phase counts, the DR wording, the 0.3.0 contracts, badge), `CHANGELOG.md`, `framework/SKILL.md` (table, legend, DR rule), `framework/references/03-wave-pipeline.md` (five phase entries, AC/ACB data-state text, DR heading), `04-meta-orchestration.md` (phase arithmetic, scope flags), `06-team-quick-reference.md`, `10-model-routing.md`, `11-hooks-and-automation.md` (wave complete, rule 38), `commands/wave-start.md`, `skills/wave-orchestrator/SKILL.md` (artifact table, 0.3.0 contracts), `skills/ac-writer/SKILL.md`, `skills/design-reviewer/SKILL.md`, a new `skills/benefit-contract/SKILL.md`, `hooks/reasons.tsv` (rule 38), `.claude-plugin/plugin.json`, and the 0.2.x spec, which gains a pointer to this document at sections 4, 6 and 8. Design Review is described as "UI waves only" in sixteen places although the table has said `ui|behaviour_change` since 0.2.0; all sixteen are corrected, except the historical 0.1.0 changelog entry.
