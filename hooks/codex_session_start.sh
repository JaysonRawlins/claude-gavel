#!/bin/bash
# Gavel Codex SessionStart hook — emits ~/.claude/gavel/session-context.md as
# additionalContext so a Codex session starts with the same philosophy injection
# every Claude session gets. Outputs the Codex hookSpecificOutput JSON shape
# (camelCase fields under deny_unknown_fields).
CONTEXT_FILE="$HOME/.claude/gavel/session-context.md"
[[ -f "$CONTEXT_FILE" ]] || exit 0

/usr/bin/python3 <<'PYEOF'
import json, os, pathlib
content = pathlib.Path(os.environ["HOME"], ".claude/gavel/session-context.md").read_text()
print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "SessionStart",
        "additionalContext": content,
    }
}))
PYEOF
