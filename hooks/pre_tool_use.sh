#!/bin/bash
# Gavel PreToolUse hook — pipes stdin to daemon, prints response.
# Checks installed path first, falls back to dev .build/ path.
GAVEL_HOOK="${GAVEL_HOOK:-$HOME/.claude/gavel/bin/gavel-hook}"
[[ -x "$GAVEL_HOOK" ]] || GAVEL_HOOK="$(dirname "$0")/../.build/release/gavel-hook"
if [[ -x "$GAVEL_HOOK" ]]; then
    CLAUDE_HOOK_TYPE=PreToolUse exec "$GAVEL_HOOK"
else
    cat > /dev/null
    echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}'
fi
