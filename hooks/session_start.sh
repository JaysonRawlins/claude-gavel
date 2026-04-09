#!/bin/bash
# Gavel SessionStart hook — registers session with daemon.
exec 2>/dev/null
GAVEL_HOOK="${GAVEL_HOOK:-$(dirname "$0")/../.build/release/gavel-hook}"
if [[ -x "$GAVEL_HOOK" ]]; then
    CLAUDE_HOOK_TYPE=SessionStart exec "$GAVEL_HOOK"
else
    cat > /dev/null
fi
