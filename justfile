# Common dev tasks for gavel. Install just: `brew install just`.
# `just` (no args) lists targets.

default:
    @just --list

# Release build of the gavel + gavel-hook binaries
build:
    swift build -c release

# Build, then run the local release binary in the foreground
run-local: build
    .build/release/gavel

# Run the test suite
test:
    swift test

# Run a single test target by name, e.g. `just test-only SocketServerProbeTests`
test-only TARGET:
    swift test --filter {{TARGET}}

# Install via install.sh — copies binaries to ~/.claude/gavel/bin and manages com.gavel.daemon LaunchAgent (redundant if you install via brew)
install: build
    ./install.sh

# Uninstall the install.sh artifacts (leaves brew-managed gavel alone)
uninstall:
    ./install.sh --uninstall

# Tail the daemon log
log:
    tail -f ~/.claude/gavel/gavel.log

# Run tests; placeholder for future swiftformat/swiftlint hooks
check: test

# Codesign local build and swap it into Homebrew's Cellar (backup, revert with dev-restore)
dev-install: build
    #!/usr/bin/env bash
    # Build + ad-hoc codesign (hardened runtime) + swap into Homebrew's Cellar.
    # Caveat: brew bottle ships with Developer ID (TeamIdentifier=4RZ893CQ7B);
    # ad-hoc may still SIGKILL in hardened spawn contexts (Codex under Ghostty).
    # If first Codex tool call after dev-install fails, check
    # ~/Library/Logs/DiagnosticReports/gavel-hook-*.ips. If "Code Signature
    # Invalid" is present, run `just dev-restore`.
    set -euo pipefail
    ver=$(brew list --versions gavel | awk '{print $2}')
    cellar="/opt/homebrew/Cellar/gavel/${ver}/bin"
    backup="$HOME/.cache/gavel-backup"
    mkdir -p "$backup"
    for bin in gavel gavel-hook; do
        [[ -f "$cellar/$bin" ]] || { echo "missing $cellar/$bin"; exit 1; }
        # Preserve the FIRST backup as the brew-pristine snapshot — re-running
        # dev-install would otherwise capture the currently-installed dev binary,
        # erasing the restore path. `cp -p` also preserves source mode (555),
        # which makes an overwrite-cp permission-denied on subsequent runs.
        bak="$backup/${bin}.${ver}.bak"
        if [[ ! -f "$bak" ]]; then
            cp -p "$cellar/$bin" "$bak"
        fi
        codesign --force --sign - --options runtime ".build/release/$bin"
        chmod u+w "$cellar/$bin"
        cp ".build/release/$bin" "$cellar/$bin"
        chmod 555 "$cellar/$bin"
    done
    echo
    echo "Local build installed at $cellar/"
    echo "Backup: $backup/"
    echo "Restore: just dev-restore  (or: brew reinstall gavel)"
    echo
    echo "Bounce the daemon to pick up daemon-side changes:"
    echo "  pkill -f /opt/homebrew/opt/gavel/bin/gavel && launchctl kickstart -k gui/\$(id -u)/com.gavel.daemon 2>/dev/null || true"

# Restore Homebrew's signed binaries from the dev-install backup.
dev-restore:
    #!/usr/bin/env bash
    set -euo pipefail
    ver=$(brew list --versions gavel | awk '{print $2}')
    cellar="/opt/homebrew/Cellar/gavel/${ver}/bin"
    backup="$HOME/.cache/gavel-backup"
    for bin in gavel gavel-hook; do
        src="$backup/${bin}.${ver}.bak"
        if [[ ! -f "$src" ]]; then
            echo "no backup for $bin at $src — try 'brew reinstall gavel'"
            continue
        fi
        chmod u+w "$cellar/$bin"
        cp -p "$src" "$cellar/$bin"
        chmod 555 "$cellar/$bin"
        echo "restored $cellar/$bin"
    done
