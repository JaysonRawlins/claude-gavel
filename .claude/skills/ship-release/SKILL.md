---
name: ship-release
description: Run the claude-gavel release train end to end after fixes land on main - merge the release-please PR, watch notarization and the Homebrew tap bump, brew upgrade, and RESTART the daemon so the live process actually runs the new image. Invoke when the user says "ship it", "cut a release", "ship 1.x.y", "merge the release PR", or after a fix is pushed to main and needs to reach the brew-managed daemon.
metadata:
  version: 1.0.0
disable-model-invocation: false
---

# Ship a gavel release

Release automation is release-please + notarization + a tap-bump workflow, but
the last mile (brew upgrade + daemon restart) is manual and has one
load-bearing gotcha: **the live daemon keeps running the OLD image until the
process is restarted** (engram c07655b0 — `--version` and binary mtime lie;
verify the live pid's start time).

Run 2026-07-06/07: this train shipped v1.41.0, v1.41.1, and v1.41.2 in one
night without a miss.

## Preconditions

- The fix/feature is on `main` with a conventional-commit subject
  (`fix(scope):` / `feat(scope):`) — that's what release-please parses.
- CI is green (Semgrep, Socket, Scan).

## Steps

1. **Find and merge the release PR** (opens automatically after the push;
   wait for it if it hasn't appeared yet):
   ```
   gh pr list --state open --json number,title -q '.[] | "\(.number) \(.title)"' | grep release
   gh pr merge <N> --squash
   ```
2. **Wait for the release + watch notarization**:
   ```
   until gh release list --limit 1 | grep -q v<X.Y.Z>; do sleep 15; done
   RID=$(gh run list --workflow Release --limit 1 --json databaseId -q '.[0].databaseId')
   gh run watch "$RID" --exit-status
   ```
   Notarization 403 → both Apple agreements gotcha (engram cd7a0417).
3. **Wait for the tap bump**:
   ```
   until [ "$(gh run list --workflow 'Bump Homebrew Tap' --limit 1 --json status -q '.[0].status')" = "completed" ]; do sleep 15; done
   ```
4. **Upgrade AND restart** (the restart is the step that actually deploys):
   ```
   brew upgrade gavel
   brew services restart gavel
   ```
   If a dev daemon is live instead of brew (check `gavel-daemon.sh status`),
   use `gavel-daemon.sh restore` rather than `brew services restart`.
5. **Verify the LIVE process, not the filesystem**:
   ```
   /opt/homebrew/opt/gavel/bin/gavel --version          # new version
   ps -o lstart -p <daemon pid>                          # started AFTER the upgrade
   ```

## Bridging while the train runs

If the fix is needed live before the release lands (active dogfooding), bounce
the dev daemon first — `gavel-dev-daemon` skill — and restore in step 4. The
restore target survives repeated bounces (pristine = first recorded).
