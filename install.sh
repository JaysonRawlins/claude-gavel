#!/bin/bash
# Install gavel — builds, installs binaries, hooks, LaunchAgent, and restarts.
# Usage: ./install.sh

set -e

INSTALL_DIR="$HOME/.claude/gavel/bin"
HOOKS_DIR="$HOME/.claude/gavel/hooks"
PLIST_DIR="$HOME/Library/LaunchAgents"
LABEL="com.gavel.daemon"
PLIST="$PLIST_DIR/$LABEL.plist"

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

echo "Restarting daemon..."
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
sleep 1
launchctl bootstrap "gui/$(id -u)" "$PLIST"

echo "Done. Gavel is running."
