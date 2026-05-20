# Claude Gavel — project conventions for Claude Code

## PR titles MUST be conventional-commit format

This repo uses [release-please](https://github.com/googleapis/release-please)
(config: `.release-please-config.json`). GitHub's squash-merge takes the PR
title as the squash-commit's first line — so **the PR title is what
release-please parses**. Body bullets don't count.

Title format: `<type>(<scope>): <description>`

- Types: `feat`, `fix`, `chore`, `docs`
- Scopes used here: `justfile`, `matcher`, `approval`, `jsonl`, `monitor`,
  `session`, `resume`, `notifications`. Pick the specific module touched;
  avoid generic scopes like "observability" or "refactor".

If a PR's title isn't conventional, the work lands on `main` but never appears
in any release. Recovery: hand-edit `CHANGELOG.md` in the next release-please
PR to backfill the missing entry.

Full context (worked / failed examples from PR history, recovery details):
query engram for `claude-gavel pr title release-please convention`.

## Dev iteration

- `just dev-daemon` — runs the local build in the foreground; brew-managed
  gavel is paused for the duration; Ctrl-C restores brew gavel via trap.
  Cleanest test cycle for daemon-side changes.
- `just dev-install` — codesigns the local build and swaps it into the brew
  Cellar. Persistent across daemon restarts. Reversal: `just dev-restore`
  (or `brew reinstall gavel`).
- `just build` — release build only, no swap.
- `just dev-doctor` — diagnoses stale dev paths in hook configs.

## Gavel self-protection

Gavel's own PreToolUse hook blocks writes and deletes against:

- `~/.claude/gavel/**`
- `~/.claude/settings*`
- `~/.claude/hooks/**`
- `~/.codex/{config,hooks}`
- shell init files (`.zshrc`, `.bashrc`, etc.)

If a tool call against those paths fails with `User denied — …` style errors,
that's Gavel's deny rule firing — not a bug. Either route through Gavel's own
APIs (`setLabel`, `saveDefaults`, etc.) or have the user run the operation
in a non-Gavel-monitored terminal.
