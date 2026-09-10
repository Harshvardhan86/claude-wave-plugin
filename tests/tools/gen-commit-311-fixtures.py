#!/usr/bin/env python3
"""tests/tools/gen-commit-311-fixtures.py <big|nul> <output-path>

Writes one PreToolUse(Bash) stdin fixture for AC-311 (tests/cases/
commit-311-scale-timing.sh): a 1 MB single-line git-commit command carrying
one trailer ("big"), or the same shape with a literal NUL byte spliced into
the message text ("nul"). Kept as a standalone tool rather than an inline
shell heredoc because embedding a raw NUL byte inside a bash heredoc is
fragile (several tools, including a wrapped `grep`, treat any file that
later contains that byte as binary and decline to search it).
"""
import json
import sys

kind, out_path = sys.argv[1], sys.argv[2]

if kind == "big":
    big = "x" * 1_000_000 + " Co-Authored-By: Claude"
    cmd = 'git commit -m "' + big + '"'
elif kind == "nul":
    cmd = "git commit -m \"a\x00b Co-Authored-By: Claude\""
else:
    sys.exit(f"unknown kind: {kind}")

with open(out_path, "w") as f:
    json.dump(
        {
            "hook_event_name": "PreToolUse",
            "tool_name": "Bash",
            "tool_input": {"command": cmd},
        },
        f,
    )
