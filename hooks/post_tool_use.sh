#!/bin/bash
# Gavel PostToolUse hook — fire-and-forget to daemon.
GAVEL_HOOK="${GAVEL_HOOK:-$HOME/.claude/gavel/bin/gavel-hook}"
[[ -x "$GAVEL_HOOK" ]] || GAVEL_HOOK="$(dirname "$0")/../.build/release/gavel-hook"
if [[ -x "$GAVEL_HOOK" ]]; then
    CLAUDE_HOOK_TYPE=PostToolUse exec "$GAVEL_HOOK"
else
    cat > /dev/null
fi
