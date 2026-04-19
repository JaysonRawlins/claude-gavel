#!/bin/bash
# Gavel Stop hook — notifies daemon session is idle.
# Resolution: $GAVEL_HOOK env → PATH → ~/.claude/gavel/bin/ → dev fallback
GAVEL_HOOK="${GAVEL_HOOK:-}"
[[ -z "$GAVEL_HOOK" ]] && GAVEL_HOOK="$(command -v gavel-hook 2>/dev/null || true)"
[[ -z "$GAVEL_HOOK" || ! -x "$GAVEL_HOOK" ]] && GAVEL_HOOK="$HOME/.claude/gavel/bin/gavel-hook"
[[ ! -x "$GAVEL_HOOK" ]] && GAVEL_HOOK="$(dirname "$0")/../.build/release/gavel-hook"
if [[ -x "$GAVEL_HOOK" ]]; then
    CLAUDE_HOOK_TYPE=Stop exec "$GAVEL_HOOK"
else
    cat > /dev/null
fi
