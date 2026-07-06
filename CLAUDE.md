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

Gavel's own PreToolUse hook gates its guardrail paths — but the mechanism is
an **unconditional prompt, not a deny** (verified against ApprovalEngine.swift
2026-07-06; this section previously said "blocks writes", which was wrong):

- Writes/edits to `~/.claude/gavel/**`, `~/.claude/settings*`,
  `~/.claude/hooks/**`, `.mcp.json`, `.git/hooks/`, `.github/workflows/`,
  `.aws/config` → `matchUnconditionalPromptPath` fires BEFORE all rules.
  Allow-once ONLY: no session-allow, no persistent allow rule, no suppression
  can ever silence the prompt. The user approving the panel applies the write.
- Deletes (`rm` against `~/.claude/gavel/`) → hard deny (`matchDangerous`).
- `rules.json` additionally carries `uchg` filesystem immutability (Tier 1).
- Shell-side writes (`>>`, `tee`, `cp`, `mv`, `sed -i` into those paths) are
  caught by a seeded Bash rule — same Allow-once-only prompt.

A `User denied — …` error on those paths means the user declined the prompt,
not that the path is unwritable. Separately, Claude Code's auto-mode
classifier can deny self-modification writes (e.g. session-context.md) even
after Gavel approval if there's no explicit user directive in the transcript —
that's the harness, not Gavel.
