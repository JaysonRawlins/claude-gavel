#!/bin/bash
# Gavel PermissionRequest hook — suppresses Claude's built-in permission dialogs.
# Exception: AskUserQuestion must pass through so the user can actually answer.
INPUT=$(cat)
TOOL=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('tool_name',''))" 2>/dev/null)

if [[ "$TOOL" == "AskUserQuestion" || "$TOOL" == "ExitPlanMode" ]]; then
    # Let Claude's built-in UI handle user interaction tools
    echo '{}'
else
    echo '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}'
fi
