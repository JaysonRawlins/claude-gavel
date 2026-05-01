# Changelog

## [1.3.0](https://github.com/JaysonRawlins/claude-gavel/compare/v1.2.3...v1.3.0) (2026-05-01)


### Features

* **monitor:** click row to pin highlight, drop first-row default highlight ([#50](https://github.com/JaysonRawlins/claude-gavel/issues/50)) ([65b0f12](https://github.com/JaysonRawlins/claude-gavel/commit/65b0f126dc185d6dfe260bafa42019f19af273c1))


### Bug Fixes

* **daemon:** bump socket read timeout 2s→30s, fail-closed on empty payload ([#51](https://github.com/JaysonRawlins/claude-gavel/issues/51)) ([338d228](https://github.com/JaysonRawlins/claude-gavel/commit/338d22853a005a286019b1934e791599ddcd021f))

## [1.2.3](https://github.com/JaysonRawlins/claude-gavel/compare/v1.2.2...v1.2.3) (2026-04-30)


### Bug Fixes

* **daemon:** single-instance guard via connect-probe before bind ([#45](https://github.com/JaysonRawlins/claude-gavel/issues/45)) ([d7fc79e](https://github.com/JaysonRawlins/claude-gavel/commit/d7fc79e09fc5d65dd6893b2607ec901dd8a24da8))

## [1.2.2](https://github.com/JaysonRawlins/claude-gavel/compare/v1.2.1...v1.2.2) (2026-04-30)


### Bug Fixes

* **cli:** handle --version/--help, reject unknown args before daemon launch ([#43](https://github.com/JaysonRawlins/claude-gavel/issues/43)) ([7f7a1b4](https://github.com/JaysonRawlins/claude-gavel/commit/7f7a1b465302097694b6e0bb0fa3a8fd76492f75))

## [1.2.1](https://github.com/JaysonRawlins/claude-gavel/compare/v1.2.0...v1.2.1) (2026-04-30)


### Bug Fixes

* **security:** pattern FP audit + approval dialog visibility ([#41](https://github.com/JaysonRawlins/claude-gavel/issues/41)) ([566527a](https://github.com/JaysonRawlins/claude-gavel/commit/566527aac3a57d1d6e9fc723e45ac4acb9ddb103))

## [1.2.0](https://github.com/JaysonRawlins/claude-gavel/compare/v1.1.1...v1.2.0) (2026-04-29)


### Features

* **monitor:** discover running Claude Code sessions at startup ([#39](https://github.com/JaysonRawlins/claude-gavel/issues/39)) ([9b1f502](https://github.com/JaysonRawlins/claude-gavel/commit/9b1f5027cdaabb0836bd4459466907f0b93df749))
* **monitor:** per-session labels and active session persistence ([9c48301](https://github.com/JaysonRawlins/claude-gavel/commit/9c48301f002997ddbab164bd5d81b373ac68438d))
* **monitor:** row redesign with activity flash and recency sort ([#40](https://github.com/JaysonRawlins/claude-gavel/issues/40)) ([19725dd](https://github.com/JaysonRawlins/claude-gavel/commit/19725dd9c753de827ad5e31c616f6362d2be4f14))


### Bug Fixes

* **bump-tap:** commit directly with git instead of fork-and-PR action ([#36](https://github.com/JaysonRawlins/claude-gavel/issues/36)) ([787d33f](https://github.com/JaysonRawlins/claude-gavel/commit/787d33f93f3d515fe4e8080a213a0fefe2e3299e))
* **security:** anchor DNS exfil pattern to command position ([774a8b1](https://github.com/JaysonRawlins/claude-gavel/commit/774a8b1bdadd1f4e730354722be41de697b78911))

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
