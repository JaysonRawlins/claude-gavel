#!/bin/bash
# Gavel SessionStart hook — injects session context then registers with daemon.
# Resolution: $GAVEL_HOOK env → PATH → ~/.claude/gavel/bin/ → dev fallback
CONTEXT_FILE="$HOME/.claude/gavel/session-context.md"
if [[ -f "$CONTEXT_FILE" ]]; then
    cat "$CONTEXT_FILE"
fi

GAVEL_HOOK="${GAVEL_HOOK:-}"
[[ -z "$GAVEL_HOOK" ]] && GAVEL_HOOK="$(command -v gavel-hook 2>/dev/null || true)"
[[ -z "$GAVEL_HOOK" || ! -x "$GAVEL_HOOK" ]] && GAVEL_HOOK="$HOME/.claude/gavel/bin/gavel-hook"
[[ ! -x "$GAVEL_HOOK" ]] && GAVEL_HOOK="$(dirname "$0")/../.build/release/gavel-hook"
if [[ -x "$GAVEL_HOOK" ]]; then
    CLAUDE_HOOK_TYPE=SessionStart exec "$GAVEL_HOOK"
else
    cat > /dev/null
fi
