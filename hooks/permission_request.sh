#!/bin/bash
# Gavel PermissionRequest hook — intercepts Claude's permission dialogs.
# Returns allow/deny decision to skip the built-in terminal prompt.
GAVEL_HOOK="${GAVEL_HOOK:-$(dirname "$0")/../.build/release/gavel-hook}"
if [[ -x "$GAVEL_HOOK" ]]; then
    CLAUDE_HOOK_TYPE=PermissionRequest exec "$GAVEL_HOOK"
else
    cat > /dev/null
    echo '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}'
fi
