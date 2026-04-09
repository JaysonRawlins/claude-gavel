#!/bin/bash
# Gavel PermissionRequest hook — suppresses Claude's built-in permission dialogs.
# The real approval decision already happened in PreToolUse via the daemon.
# This hook just tells Claude to skip its own prompt.
cat > /dev/null
echo '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}'
