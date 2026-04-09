#!/bin/bash
# Gavel Stop hook — notifies daemon session is idle.
exec 2>/dev/null
GAVEL_HOOK="${GAVEL_HOOK:-$(dirname "$0")/../.build/release/gavel-hook}"
if [[ -x "$GAVEL_HOOK" ]]; then
    CLAUDE_HOOK_TYPE=Stop exec "$GAVEL_HOOK"
else
    cat > /dev/null
fi
# Native macOS notification as fallback
osascript -e 'display notification "Ready for input" with title "Claude Code" sound name "Glass"' 2>/dev/null &
