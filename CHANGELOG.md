# Changelog

## [1.1.1](https://github.com/JaysonRawlins/claude-gavel/compare/v1.1.0...v1.1.1) (2026-04-22)


### Bug Fixes

* 18: tighten `at` pattern to avoid false-positives in prose ([#30](https://github.com/JaysonRawlins/claude-gavel/issues/30)) ([899ce6f](https://github.com/JaysonRawlins/claude-gavel/commit/899ce6f4895b595bdeb7c60e49e611ea40bd3e5b))
* drop component prefix from release tag ([#34](https://github.com/JaysonRawlins/claude-gavel/issues/34)) ([3807309](https://github.com/JaysonRawlins/claude-gavel/commit/38073098d3de997015a70048f7eedee5667d036d))

## [1.1.0](https://github.com/JaysonRawlins/claude-gavel/compare/gavel-v1.0.0...gavel-v1.1.0) (2026-04-22)


### Features

* Prompt Mode controls for auto-approval — per-session Prompt button, bulk Prompt All (menu bar, Monitor button, system-wide `⌘⌥⇧P` hotkey), and a configurable inactivity timeout that fans out Prompt All after N minutes of no UI interaction as a walk-away defense ([#28](https://github.com/JaysonRawlins/claude-gavel/pull/28))
* Built-in prompt rules for persistence-creating scheduler tools (`CronCreate`, `ScheduleWakeup`, `CronDelete`) — force a dialog even under auto-approve since these plant future execution that fires while the user may not be watching ([#31](https://github.com/JaysonRawlins/claude-gavel/pull/31))


### Bug Fixes

* tighten `at` pattern so it no longer matches prose "at " in heredoc bodies (e.g. `gh pr create --body`), commit messages, or git ref descriptions — now requires a command-segment boundary plus a real timespec ([#30](https://github.com/JaysonRawlins/claude-gavel/pull/30))
