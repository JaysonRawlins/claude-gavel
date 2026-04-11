#!/bin/bash
# Install gavel — builds, installs binaries, hooks, LaunchAgent, registers hooks, and restarts.
# Usage: ./install.sh
# Uninstall: ./install.sh --uninstall

set -e

INSTALL_DIR="$HOME/.claude/gavel/bin"
HOOKS_DIR="$HOME/.claude/gavel/hooks"
PLIST_DIR="$HOME/Library/LaunchAgents"
LABEL="com.gavel.daemon"
PLIST="$PLIST_DIR/$LABEL.plist"
SETTINGS="$HOME/.claude/settings.json"

# ── Uninstall ──
if [[ "$1" == "--uninstall" ]]; then
    echo "Uninstalling gavel..."
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    rm -f "$PLIST"

    # Remove gavel hooks from settings.json
    if [[ -f "$SETTINGS" ]] && command -v python3 &>/dev/null; then
        python3 -c "
import json, sys
with open('$SETTINGS') as f:
    cfg = json.load(f)
hooks = cfg.get('hooks', {})
changed = False
for event in list(hooks.keys()):
    original = hooks[event]
    filtered = [h for h in original if not any(
        'gavel' in hook.get('command', '')
        for hook in h.get('hooks', [])
    )]
    if len(filtered) != len(original):
        hooks[event] = filtered
        changed = True
    if not hooks[event]:
        del hooks[event]
if changed:
    with open('$SETTINGS', 'w') as f:
        json.dump(cfg, f, indent=2)
    print('Removed gavel hooks from settings.json')
else:
    print('No gavel hooks found in settings.json')
"
    fi

    rm -rf "$HOME/.claude/gavel"
    echo "Gavel uninstalled."
    exit 0
fi

# ── Install ──
echo "Building release..."
swift build -c release

echo "Installing binaries to $INSTALL_DIR..."
mkdir -p "$INSTALL_DIR" "$HOOKS_DIR"
cp .build/release/gavel .build/release/gavel-hook "$INSTALL_DIR/"

echo "Installing hook shims to $HOOKS_DIR..."
for f in hooks/*.sh; do
    cp "$f" "$HOOKS_DIR/$(basename "$f")"
    chmod +x "$HOOKS_DIR/$(basename "$f")"
done

echo "Installing LaunchAgent..."
mkdir -p "$PLIST_DIR"
cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$INSTALL_DIR/gavel</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$HOME/.claude/gavel/gavel.log</string>
    <key>StandardErrorPath</key>
    <string>$HOME/.claude/gavel/gavel.log</string>
</dict>
</plist>
PLIST

echo "Registering hooks in settings.json..."
if [[ -f "$SETTINGS" ]] && command -v python3 &>/dev/null; then
    python3 -c "
import json

HOOKS_DIR = '$HOOKS_DIR'
GAVEL_HOOKS = {
    'PreToolUse': [{
        'hooks': [{'type': 'command', 'command': f'{HOOKS_DIR}/pre_tool_use.sh', 'timeout': 86400}]
    }],
    'PermissionRequest': [{
        'hooks': [{'type': 'command', 'command': f'{HOOKS_DIR}/permission_request.sh', 'timeout': 86400}]
    }],
    'PostToolUse': [{
        'hooks': [{'type': 'command', 'command': f'{HOOKS_DIR}/post_tool_use.sh', 'async': True}]
    }],
    'SessionStart': [{
        'hooks': [{'type': 'command', 'command': f'{HOOKS_DIR}/session_start.sh'}]
    }],
    'Stop': [{
        'hooks': [{'type': 'command', 'command': f'{HOOKS_DIR}/stop.sh', 'async': True}]
    }],
}

with open('$SETTINGS') as f:
    cfg = json.load(f)

hooks = cfg.setdefault('hooks', {})
changed = False

for event, entries in GAVEL_HOOKS.items():
    existing = hooks.get(event, [])
    # Check if gavel hook already registered
    has_gavel = any(
        'gavel' in hook.get('command', '')
        for entry in existing
        for hook in entry.get('hooks', [])
    )
    if not has_gavel:
        hooks[event] = existing + entries
        changed = True

if changed:
    with open('$SETTINGS', 'w') as f:
        json.dump(cfg, f, indent=2)
    print('Gavel hooks registered in settings.json')
else:
    print('Gavel hooks already registered')
"
else
    echo "WARNING: Could not register hooks. Please add gavel hooks to $SETTINGS manually."
fi

echo "Starting daemon..."
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
sleep 1
launchctl bootstrap "gui/$(id -u)" "$PLIST"

echo ""
echo "Done. Gavel is running."
echo "  Monitor: click the gavel icon in the menu bar"
echo "  Update:  cp .build/release/gavel .build/release/gavel-hook $INSTALL_DIR/ then Reload Binary"
echo "  Uninstall: ./install.sh --uninstall"
