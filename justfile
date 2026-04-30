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
