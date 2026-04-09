#!/bin/bash
# Install gavel — copies release binaries and restarts the daemon.
# Usage: ./install.sh

set -e

INSTALL_DIR="$HOME/.claude/gavel/bin"
LABEL="com.gavel.daemon"

echo "Building release..."
swift build -c release

echo "Installing binaries to $INSTALL_DIR..."
mkdir -p "$INSTALL_DIR"
cp .build/release/gavel .build/release/gavel-hook "$INSTALL_DIR/"

echo "Restarting daemon..."
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
sleep 1
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/$LABEL.plist"

echo "Done. Gavel is running."
