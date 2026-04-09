#!/bin/bash
# Gavel PreToolUse hook — pipes stdin to daemon, prints response.
# Preserve stderr for gavel-hook (it writes deny reasons there),
# but suppress bash's own errors on fd 3.
exec 3>&2
GAVEL_HOOK="${GAVEL_HOOK:-$(dirname "$0")/../.build/release/gavel-hook}"
if [[ -x "$GAVEL_HOOK" ]]; then
    CLAUDE_HOOK_TYPE=PreToolUse exec "$GAVEL_HOOK"
else
    # Daemon not available — allow and skip Claude's own prompt
    cat > /dev/null
    echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}'
fi
