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
    # Build + codesign + swap into Homebrew's Cellar. Identity resolution:
    #   1. $GAVEL_SIGN_IDENTITY env var (user override)
    #   2. First "Developer ID Application" from `security find-identity`
    #   3. Ad-hoc `-` (warns; may SIGKILL in hardened spawn contexts like
    #      Ghostty → Codex CLI → hook, or LaunchAgent → daemon)
    # The identity NAME is resolved from the local keychain at runtime so the
    # repo carries no personal info; the private key never leaves the keychain.
    #
    # Daemon-side caveat: even with Developer ID, LaunchAgent kills the daemon
    # for "Invalid Page" because the brew bottle is also notarized — `spctl -a`
    # confirms `source=Unnotarized Developer ID` rejects this binary. Notarizing
    # locally is impractical (multi-min round-trip to Apple per build). For
    # daemon-side dev, use `just dev-daemon` instead — foreground spawn from an
    # interactive shell is permissive about codesigning. dev-install is most
    # useful for hook-side testing where the parent chain is more lenient.
    set -euo pipefail
    ver=$(brew list --versions gavel | awk '{print $2}')
    cellar="/opt/homebrew/Cellar/gavel/${ver}/bin"
    backup="$HOME/.cache/gavel-backup"
    mkdir -p "$backup"

    identity="${GAVEL_SIGN_IDENTITY:-}"
    if [[ -z "$identity" ]]; then
        identity=$(security find-identity -v -p codesigning 2>/dev/null \
            | grep "Developer ID Application" \
            | head -1 \
            | sed -E 's/^[^"]*"([^"]+)".*$/\1/' || true)
    fi
    if [[ -z "$identity" ]]; then
        identity="-"
        echo "WARNING: no Developer ID found in keychain — falling back to ad-hoc."
        echo "         macOS will likely SIGKILL the binaries when spawned by Codex/Claude or LaunchAgent."
    else
        echo "Signing with: $identity"
    fi

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
        codesign --force --sign "$identity" --options runtime ".build/release/$bin"
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
    echo "  brew services restart gavel"

# Run a local dev daemon in the foreground; brew-managed daemon is paused for the duration.
dev-daemon: build
    #!/usr/bin/env bash
    # Stop brew-managed gavel, run .build/release/gavel in foreground.
    # The trap restores brew gavel on exit (Ctrl-C, error, normal return).
    # Foreground spawn from an interactive shell is permissive about codesigning,
    # so the linker-only signature from `swift build` works — no codesign or
    # notarization needed for daemon-side dev.
    set -euo pipefail
    cleanup() {
        echo
        echo "Restoring brew-managed gavel..."
        brew services start gavel >/dev/null 2>&1 || true
    }
    trap cleanup EXIT INT TERM
    echo "Stopping brew-managed gavel..."
    brew services stop gavel >/dev/null
    echo "Running .build/release/gavel — Ctrl-C to stop and restore brew daemon"
    echo
    .build/release/gavel

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
