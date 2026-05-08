# Part 11 — Hooks and Automation

v2 enforces three v1 invariants via Claude Code hooks. The snippets below are ready to paste into `~/.claude/settings.json` (or a project `.claude/settings.json`). Each hook is **conditional** and **narrow** — it only fires on the matching tool/pattern, not globally.

## 11.1 Combined hooks block

```jsonc
{
  "hooks": {
    // ─────────────────────────────────────────────────────────────────
    // (1) PreCompact — enforce Invariant 7 (Auto-compact = STOP).
    //     Forces the Checkpoint Team to run a save before any compaction.
    //     If the save fails, compaction is blocked and the user is notified.
    // ─────────────────────────────────────────────────────────────────
    "PreCompact": [
      {
        "command": "claude invoke-agent checkpoint-team --reason pre-compact --require-success",
        "decision": "block-on-nonzero"
      }
    ],

    // ─────────────────────────────────────────────────────────────────
    // (2) PostToolUse — Dashboard refresh on every writing tool use.
    //     Conditional filter limits firing to the tools that represent a
    //     state change. Background to avoid blocking the next tool call.
    // ─────────────────────────────────────────────────────────────────
    "PostToolUse": [
      {
        "if": "tool in (Edit, Write, Bash(git *), TaskCreate, TaskUpdate)",
        "command": "claude invoke-agent dashboard-team --mode refresh",
        "background": true
      }
    ],

    // ─────────────────────────────────────────────────────────────────
    // (3) PreToolUse — guard against committing planning docs (Invariant 6).
    //     Runs only on `git commit`. The guard script exits non-zero if any
    //     staged path matches planning-doc patterns, blocking the commit.
    // ─────────────────────────────────────────────────────────────────
    "PreToolUse": [
      {
        "if": "tool == 'Bash' && input matches /\\bgit\\s+commit\\b/",
        "command": "bash ~/.claude/hooks/guard-planning-docs.sh",
        "decision": "block-on-nonzero"
      }
    ],

    // ─────────────────────────────────────────────────────────────────
    // (4) TaskCreated — announce new tasks to Dashboard.
    //     Fires when the orchestrator creates a wave or phase task.
    // ─────────────────────────────────────────────────────────────────
    "TaskCreated": [
      {
        "command": "claude invoke-agent dashboard-team --mode announce --task-id ${task.id}",
        "background": true
      }
    ]
  }
}
```

## 11.2 `guard-planning-docs.sh`

Ship this script at `~/.claude/hooks/guard-planning-docs.sh`. It blocks a `git commit` whose staged diff touches any path matching planning-doc patterns.

```bash
#!/usr/bin/env bash
# Blocks commits that stage analysis/planning docs.
# Planning-doc patterns (extend as needed):
#   - tasks/todo.md, tasks/*.md
#   - analysis/**, *_analysis/**
#   - docs/wave*-*.md, docs/plan-*.md
#   - ~/.claude/plans/** (never should be staged, but belt-and-braces)

set -euo pipefail

staged=$(git diff --cached --name-only 2>/dev/null || true)
if [[ -z "$staged" ]]; then
  exit 0
fi

blocked=()
while IFS= read -r path; do
  case "$path" in
    tasks/*.md|tasks/todo.md)                 blocked+=("$path") ;;
    analysis/*|*_analysis/*)                  blocked+=("$path") ;;
    docs/wave*-*.md|docs/plan-*.md)           blocked+=("$path") ;;
    .claude/plans/*|*/.claude/plans/*)        blocked+=("$path") ;;
    *.plan.md)                                 blocked+=("$path") ;;
  esac
done <<< "$staged"

if [[ ${#blocked[@]} -gt 0 ]]; then
  echo "[wave-exec guard] Blocked commit — planning docs must not be committed:" >&2
  printf '  - %s\n' "${blocked[@]}" >&2
  echo "[wave-exec guard] Unstage them or move them outside the repo." >&2
  exit 2
fi
exit 0
```

After saving: `chmod +x ~/.claude/hooks/guard-planning-docs.sh`.

## 11.3 Per-project override

If a project legitimately needs to commit plan-shaped files (e.g., a methodology repo like this one), override the guard in the project's `.claude/settings.json`:

```jsonc
{
  "hooks": {
    "PreToolUse": [
      { "if": "tool == 'Bash' && input matches /\\bgit\\s+commit\\b/",
        "command": "true",
        "decision": "allow" }
    ]
  }
}
```

Project-level settings merge over user-level settings, so this disables the guard only for the project.

## 11.4 Verification of hooks

After pasting, verify with:

```bash
# 1. Ensure the guard script is executable
test -x ~/.claude/hooks/guard-planning-docs.sh && echo OK

# 2. Dry-run the guard with a staged planning file
cd /tmp && mkdir -p guard-test && cd guard-test && git init -q
mkdir tasks && touch tasks/todo.md && git add tasks/todo.md
~/.claude/hooks/guard-planning-docs.sh ; echo "exit=$?"
# Expected output:
#   [wave-exec guard] Blocked commit — planning docs must not be committed:
#     - tasks/todo.md
#   exit=2

# 3. PreCompact/PostToolUse hooks fire inside Claude Code — verify by forcing a compact
#    from within a session and confirming the dashboard/checkpoint agents were invoked.
```

## 11.5 Rollback

To temporarily disable all framework hooks (e.g., debugging a commit), comment out the `"hooks"` block in `~/.claude/settings.json` and restart the Claude Code session. There is no destructive state — hooks only intercept tool calls.
