# Contributing to claude-wave-plugin

Thanks for taking a look. Contributions are welcome — especially:

- Bug reports for cases where a wave produces wrong output despite the rules being followed
- Improvements to demo on-ramp skills (clarity, additional anti-patterns, banned-assertion entries)
- Reference doc fixes / clarifications
- Additional language-binding rules for stacks not yet covered (Rust FFI, Python C extensions, JNI, Swift bridging…)

## Filing an issue

Open a GitHub issue with:

- A clear title naming the affected skill, phase, or reference file
- The wave goal and the dispatch that produced the issue
- Expected vs actual artifact — paste the relevant `.wave/<phase>.md` excerpt
- Your environment: Claude Code version, OS, the project's stack

## Submitting a pull request

1. Fork the repo
2. Create a topic branch: `feat/<short-name>` or `fix/<short-name>`
3. For framework changes (`framework/SKILL.md` or any reference): include a short rationale in the PR description naming which incident or pattern motivated the change. Framework rules are non-negotiable; new ones earn their place by surviving real production work.
4. For demo on-ramp skill changes: include a before/after example showing the new guidance in action
5. Sign off your commit (`git commit -s`)
6. One PR per logical change

## Style

- Markdown files: hard-wrap not required; prefer one sentence per line for clean diffs in long-form prose
- ASCII diagrams use box-drawing characters (`├ ─ │ └ ┌ ┐ ┘`)
- Skill `description:` frontmatter stays under 200 characters
- No AI-attribution boilerplate in commits, file headers, or docstrings
- Lean prose: rules and contracts stated directly, not buried in motivation

## What we will not merge

- Changes that soften the invariants (lean context, strict TDD, fresh-eyes hardening, user-decides-on-bugs)
- New phases without a clear gate definition and hand-off contract
- Examples that endorse one specific design system over another (keep on-ramps stack-agnostic)
- Co-authored trailers naming AI assistants
