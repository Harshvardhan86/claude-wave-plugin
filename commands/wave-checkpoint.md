---
description: Save wave state to disk so an auto-compact, session crash, or laptop battery death doesn't kill the run. Run this between phases or before any long operation.
allowed-tools: "Bash(mkdir:*), Bash(date:*), Bash(git:*)"
---

# Wave checkpoint

## Context

- Working dir: !`pwd`
- Timestamp: !`date -u +%Y-%m-%dT%H:%M:%SZ`
- Git head: !`git rev-parse --short HEAD 2>/dev/null || echo "no-git"`
- Status: !`git status --porcelain 2>/dev/null | wc -l | tr -d ' '` changed files

## Instructions

Save a wave checkpoint to `.wave/checkpoints/<timestamp>.md` containing:

1. **Wave goal** — the original feature description from `/wave-start`.
2. **Phase reached** — which of AC / DR / RED / GREEN / TEET is currently in flight.
3. **Last verified evidence** — paste the most recent screenshot path, test output, or computed-style assertion result. NOT "tsc passes". Real evidence only.
4. **Open questions** — anything the user still has to decide.
5. **Resume instructions** — exact commands and prompts a fresh session would need to pick up where this one left off.

If `.wave/` does not exist, create it. Add `.wave/` to `.gitignore` if a git repo and the entry is missing.

After writing the checkpoint, print the file path and the resume command to the user. Do not commit checkpoints — they're local recovery state, not source.
