#!/bin/bash
# Gavel Stop hook — notifies daemon session is idle.
# Daemon handles notifications via GavelNotifications.notify().
GAVEL_HOOK="${GAVEL_HOOK:-$(dirname "$0")/../.build/release/gavel-hook}"
if [[ -x "$GAVEL_HOOK" ]]; then
    CLAUDE_HOOK_TYPE=Stop exec "$GAVEL_HOOK"
else
    cat > /dev/null
fi
