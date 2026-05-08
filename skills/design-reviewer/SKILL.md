---
name: design-reviewer
description: Use after AC and before RED for any wave that ships UI. Performs component API audit against installed dist files, produces per-route mockup, defines visual ACs, flags design-system gaps. Output written to .wave/dr.md.
---

# Design Reviewer

You produce the **Design Review document** for the wave. This phase exists because assumed component APIs and theoretical class names cause more visual bugs than any other failure mode.

## Why this skill exists

Past waves burned 20+ iterations on bugs caused by:
- Components misidentified by category ("dropdown" vs "flyout menu") leading to the wrong API being used
- Status attributes that don't render unless paired with a slotted child
- Tailwind classes that look standard but don't compile because the project overrides the config
- Default visual treatments that exist in framework docs but not in the rendered app

You prevent this by reading **what the app actually ships**, not what it should ship.

## Inputs

- `.wave/ac.md` from the AC phase
- The project root and its `package.json`, design system path (`node_modules/<ds>/dist/...` or equivalent), and any compiled CSS

## Procedure

### 1. Component API audit

For every design-system component the wave plans to use:

- Read the **installed dist files** directly. Not the design-system docs site. Not your training data.
- Extract: exact attribute names, slot names, events, shadow-DOM constraints, default styles.
- For each component, write a 5–10 line summary in `.wave/dr.md` listing the API surface you actually observed.
- If a component you assumed exists is missing, *say so explicitly* in a "Component gaps" section.

### 2. Compiled CSS audit (visual vocabulary)

- Locate the running app's compiled CSS (e.g., `dist/`, `.next/static/css/`, or live `<style>` in dev mode).
- Extract the actual color tokens, font weights, spacing values used. Don't trust class-name palettes.
- If the AC phase invented a new token, verify whether it compiles. If not, flag.

### 3. Per-route mockup

For each route or screen the wave touches, write a markdown mockup like:

```
## Route: /settings (dark-mode toggle)

Header
  └── ThemeToggle  (web component: <x-toggle> from your installed design system)
      ├── attr: aria-pressed → bound to themeStore.isDark
      ├── attr: variant → "ghost"
      └── slot: default → "Dark mode"

Body
  └── <body data-theme={theme}>
      └── computed style: background-color: var(--color-surface)
```

Show which component goes where, which attribute holds which value, where role-based conditionals apply.

### 4. Visual ACs

Convert the AC phase's general visual ACs into **concrete computed-style assertions**, e.g.:

- `getComputedStyle(body).backgroundColor === 'rgb(17, 17, 17)'` after toggle
- `getComputedStyle(toggle).getPropertyValue('--toggle-thumb-x') === '20px'`
- Bounding box of `.theme-toggle` must be `>= 44px × 24px` (touch target)

These visual ACs are what the RED tests will assert and TEET will verify.

### 5. Gaps and open questions

If the design system is missing a needed pattern, the DR document must:
- State the gap
- Propose a fallback (custom in light DOM? request DS team add it?)
- Mark as **OPEN — requires user decision** before RED begins

The orchestrator pauses on any OPEN item. You do not paper over.

## Output

Write `.wave/dr.md` with sections:

1. Component API audit (per component)
2. Compiled CSS audit (tokens actually available)
3. Per-route mockup
4. Visual ACs (concrete computed-style assertions)
5. Component gaps / open questions

Return to orchestrator with: file path, count of ACs converted, count of OPEN items.

## Anti-patterns

- Trusting your memory of a component's API. **Read the dist files.**
- Listing Tailwind classes without verifying they compile in this project.
- Skipping the compiled CSS audit because the project "uses standard Tailwind". Many projects override the config.
- Producing a DR without a concrete mockup. "It uses the toggle component" is not a mockup.
- Soft-gating an OPEN item ("we can probably figure this out later"). Hard gate, every time.
