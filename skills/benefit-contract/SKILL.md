---
name: benefit-contract
description: Use at Phase 0.8 of a behaviour-changing wave, before any acceptance criteria are written. Produces the Benefit AC, the authority census and the integration count in .wave/ben.md.
---

# Benefit Contract

You write the contract that says what the wave is *for*, before anyone writes a criterion, a design or a test.

## Why this skill exists

A wave can run every gate green and still deliver nothing.
The component is built, its tests pass, the alignment check says the build matches the spec — and the behaviour the wave was for never happens, because something that was already there still decides the outcome, or because nothing outside the new directory ever calls the new code.

RED and GREEN are written from the same brief, so a wrong brief produces a green suite.
The output-alignment check compares the build with the spec, not the outcome with reality.
Mutation testing measures the tests that exist.
None of them asks whether the user's day changed.

That question is this phase's only job. You run when the wave changes existing behaviour.

## Output

Write `.wave/ben.md` with three sections and, at the end, the line:

```text
BEN-VERIFIED red=<n> authorities=<n>
```

`red` is the number of failing benefit tests and must be at least 1.
`authorities` is the number of rows in the census and must be at least 1.

## 1. The Benefit AC

Exactly one sentence. Not a list, not a paragraph.

Three rules, all checkable:

1. **Its grammatical subject is not the new component.** The subject is a person, or the surrounding system. If the sentence begins with the thing you are building, it is a description of the build, not of a benefit.
2. **Its verb is what that subject does differently** once the feature exists.
3. **It names no symbol the wave introduces.** No new class, function, table, column, flag, endpoint or file name. Search the finished sentence for each new identifier; a hit means rewrite. This is the rule that does the work, because a sentence that cannot mention the new code has to talk about the outcome instead.

Then back it with **one named, executing test**. You write it, you run it, and it fails — for the right reason, which you state. A test that fails because a file does not exist yet is not evidence about the benefit; a test that fails because the outcome does not happen is.

If the benefit can only be observed end to end, say so and name the command. `[TEET]` will run it.

## 2. The authority census

Name the decision the feature influences. One decision, in plain words.

Then list, **by reading code**, every existing component that already decides that same outcome. For each one:

| Column | What goes in it |
|---|---|
| Location | file and symbol |
| How it decides | the rule it applies |
| Input | what it reads to decide |
| On disagreement | what happens when it and the new feature want different outcomes |
| Resolution | which one wins today, and why |

The census **must include the authority that produces the outcome the Benefit AC names**. That is what makes the two artifacts interlock: if the Benefit AC says a returning user lands on a narrowed list, the census has to name whatever decides today what that list shows.

`authorities` is never 0. A feature that influences a decision nothing makes today is a *new* decision, and the census says exactly that, in one row.

## 3. The integration count, sign inverted

Count the files the wave expects to change **outside the feature's own directory**.

A behaviour-changing wave with a count of 0 or 1 has been **hosted, not integrated**. That is a finding, not an achievement. It needs a written justification naming the existing mechanism that will carry the behaviour to the rest of the system.

"Untouched" is not a score. Write the blast-radius table so that every row answers one question — *must this change, and why not?* — and a row that answers "no" carries the reason.

## At the close: `[BEN-CLOSE]`

A separate team, with fresh eyes, writes `.wave/ben-close.md` after the last hardening phase and before the version bump. It does four things:

1. **Runs the named benefit test**, recording the command, the exit status and the tail of the output.
2. **Orphan-state sweep.** For every new class, table, flag or state the wave introduced, search for production readers outside the feature's own directory. Zero external readers means the rest of the system cannot see it. Name the reader that should exist, or justify its absence.
3. **Defeat list.** Search the wave's own new comments and documents for any statement that the existing system undoes, ignores or overrides the feature. Each one is a requirement unless a named test guards it. Your own notes saying "the container resets this on mount, so we restore afterwards" are the clearest possible evidence that something is fighting the feature.
4. **Writes the verdict.** `BENEFIT: DELIVERED` only when the test passed and neither list holds an unjustified item. Otherwise `BENEFIT: UNDELIVERED`, followed by the reasons.

`UNDELIVERED` does not block the wave. It is recorded, printed in the scorecard and announced once at the close. Never edit the Benefit AC to turn the verdict green — that is the one move this whole phase exists to make visible.

## Worked example

Feature: *remember my last search filters.*

**Benefit AC — wrong:**

> The filter-persistence service writes the active filter set to storage whenever it changes.

The subject is the new component, the verb is what the code does, and it names the thing being built. It would be green the moment the service exists, whether or not anyone's screen ever changes.

**Benefit AC — right:**

> A returning user opens the results page and finds it already narrowed the way they left it, without touching the filter bar.

No new symbol; the subject is the user; the verb is what the user no longer has to do.

**Backing test.** Open the results page, apply two filters, end the session, start a new one, open the results page again, assert the visible result set is the narrowed one and the filter controls show those two values. It fails today because the page comes back unfiltered. That is the right reason.

**Authority census.** Who already decides what that page shows on load?

| Location | How it decides | Input | On disagreement | Resolution |
|---|---|---|---|---|
| route definition | supplies default query parameters when none are in the URL | the route's own defaults | the defaults overwrite a restored filter set | route wins — it runs first |
| results container, on mount | clears the filter state to "show everything" | none | the clear runs after a restore and erases it | container wins — it runs last |
| server list endpoint | applies a role-based default filter when the request carries none | the caller's role | a restored client filter is sent, so this branch is not reached | client wins when it sends filters |
| response cache | serves the previous unfiltered payload for a short window | the request URL | a restored filter changes the URL, so the entry misses | no conflict |

`authorities=4`. The second row is the one that matters: something already in the system resets exactly what the feature is trying to restore. That row is the reason the wave is not simply "add a service".

**Integration count.** If the plan changes only files inside the new service's own directory, the count is 0 and the feature is hosted, not integrated — nothing would ever ask it for the remembered filters. The honest plan changes the results container (to ask, and to stop clearing) and the route definition (to stop overwriting): count 2, with a blast-radius row for the endpoint and the cache saying why neither must change.

**At the close.** The orphan-state sweep asks whether anything outside the service's directory reads the stored filter set; if the answer is nothing, the feature is writing to a drawer no one opens. The defeat list picks up the comment someone added during GREEN — *"the container still clears on mount; we restore after it"* — and turns it into a requirement: either a named test pins that order, or the verdict says so.

## Anti-patterns

- A Benefit AC that is really two sentences joined by "and". Split the wave instead.
- A census assembled from memory or from documentation. Read the code; cite file and symbol.
- A census with one row that is the new feature itself. The census is about what exists *now*.
- Reporting an integration count of 0 as good news.
- Writing the benefit test after the implementation, so it has never been red.
- Softening the Benefit AC once the verdict looks like it will be `UNDELIVERED`.
