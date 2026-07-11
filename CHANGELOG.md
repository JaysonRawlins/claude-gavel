# Changelog

## [1.43.0](https://github.com/JaysonRawlins/claude-gavel/compare/v1.42.0...v1.43.0) (2026-07-11)


### Features

* **approval:** full-command review page + rule adjudication from Telegram ([#201](https://github.com/JaysonRawlins/claude-gavel/issues/201)) ([620d6e0](https://github.com/JaysonRawlins/claude-gavel/commit/620d6e016daf779fe2196bb05f71fe9d977db349))
* **approval:** scoped Always Allow authoring on the command review page ([#203](https://github.com/JaysonRawlins/claude-gavel/issues/203)) ([669f68b](https://github.com/JaysonRawlins/claude-gavel/commit/669f68ba9b89fa93a1e51f61c2e30647abd020f1))
* **matcher:** per-argument scoping for MCP allow rules ([#200](https://github.com/JaysonRawlins/claude-gavel/issues/200)) ([676920e](https://github.com/JaysonRawlins/claude-gavel/commit/676920eb7a5a9ee5a2fc7ea0ecfcc1ac498fa382))

## [1.42.0](https://github.com/JaysonRawlins/claude-gavel/compare/v1.41.2...v1.42.0) (2026-07-10)


### Features

* **approval:** tell the agent when the diff was reviewed before approval ([#198](https://github.com/JaysonRawlins/claude-gavel/issues/198)) ([d5eaa14](https://github.com/JaysonRawlins/claude-gavel/commit/d5eaa147ddf41e53826851b5c6e0dad7d7eba981))

## [1.41.2](https://github.com/JaysonRawlins/claude-gavel/compare/v1.41.1...v1.41.2) (2026-07-07)


### Bug Fixes

* **approval:** honor cd compounds when resolving review diff repo ([6086612](https://github.com/JaysonRawlins/claude-gavel/commit/60866124bd4e0832990819e2457b030a0fdfcf80))

## [1.41.1](https://github.com/JaysonRawlins/claude-gavel/compare/v1.41.0...v1.41.1) (2026-07-07)


### Bug Fixes

* **approval:** capture add-and-commit compounds for review diff ([7d5a3df](https://github.com/JaysonRawlins/claude-gavel/commit/7d5a3dff8373617714c11ddfe0d23d79d4e57918))

## [1.41.0](https://github.com/JaysonRawlins/claude-gavel/compare/v1.40.0...v1.41.0) (2026-07-07)


### Features

* **approval:** embedded diff review server with web resolver ([#193](https://github.com/JaysonRawlins/claude-gavel/issues/193)) ([02106a1](https://github.com/JaysonRawlins/claude-gavel/commit/02106a1b98522c79f2e43edb36e92c63222fb45f))
* **notifications:** review link in Telegram commit approvals ([#194](https://github.com/JaysonRawlins/claude-gavel/issues/194)) ([d4f4e1c](https://github.com/JaysonRawlins/claude-gavel/commit/d4f4e1c08751e264f394416eeddd0028d95eeb84))


### Bug Fixes

* **approval:** dismiss Mac panel on web-review resolution ([43cbf11](https://github.com/JaysonRawlins/claude-gavel/commit/43cbf112003d62977eb31fac545a8dda732147fe))
* **approval:** honor git -C when capturing review diff ([ad1918b](https://github.com/JaysonRawlins/claude-gavel/commit/ad1918b5fac62be0184895063a085a65bb52b5f9))
* **approval:** offer review link on credential-withheld commits ([6929502](https://github.com/JaysonRawlins/claude-gavel/commit/69295024d87b3ac052f279809966849ab70db03f))

## [1.40.0](https://github.com/JaysonRawlins/claude-gavel/compare/v1.39.1...v1.40.0) (2026-07-06)


### Features

* **approval:** site-scoped browsing lease for claude-in-chrome ([#190](https://github.com/JaysonRawlins/claude-gavel/issues/190)) ([9f1f31a](https://github.com/JaysonRawlins/claude-gavel/commit/9f1f31a5dbd9ca9a6ab2d6db2f380f870854bfb1))

## [1.39.1](https://github.com/JaysonRawlins/claude-gavel/compare/v1.39.0...v1.39.1) (2026-07-02)


### Bug Fixes

* **session:** discover native-install claude sessions with version-named binaries ([#187](https://github.com/JaysonRawlins/claude-gavel/issues/187)) ([60b6f5d](https://github.com/JaysonRawlins/claude-gavel/commit/60b6f5d7bf140cfc58da2f7d75e7ae76595885ef))

## [1.39.0](https://github.com/JaysonRawlins/claude-gavel/compare/v1.38.0...v1.39.0) (2026-07-02)


### Features

* **approval:** tighten-only rule proposals with audited accept/reject ([#185](https://github.com/JaysonRawlins/claude-gavel/issues/185)) ([926668e](https://github.com/JaysonRawlins/claude-gavel/commit/926668e80663482788b9ceefb33f43bc9bf75903))

## [1.38.0](https://github.com/JaysonRawlins/claude-gavel/compare/v1.37.0...v1.38.0) (2026-06-29)


### Features

* **matcher:** gate .aws/config + close the Bash-bypass of guardrail paths ([#183](https://github.com/JaysonRawlins/claude-gavel/issues/183)) ([55b4c58](https://github.com/JaysonRawlins/claude-gavel/commit/55b4c581fd9463c695e96941f2499888c677b979))

## [1.37.0](https://github.com/JaysonRawlins/claude-gavel/compare/v1.36.0...v1.37.0) (2026-06-27)


### Features

* **matcher:** extend unconditional tier to outbound + exec-persistence vectors ([#181](https://github.com/JaysonRawlins/claude-gavel/issues/181)) ([2a64a46](https://github.com/JaysonRawlins/claude-gavel/commit/2a64a4695410ec548c0e47c2d57a258a162e9849))

## [1.36.0](https://github.com/JaysonRawlins/claude-gavel/compare/v1.35.2...v1.36.0) (2026-06-27)


### Features

* **matcher:** unconditional-prompt tier for guardrail-mutation writes ([#179](https://github.com/JaysonRawlins/claude-gavel/issues/179)) ([1197a81](https://github.com/JaysonRawlins/claude-gavel/commit/1197a8174c50b1bd5f6c8544552d57b7ebd8626f))

## [1.35.2](https://github.com/JaysonRawlins/claude-gavel/compare/v1.35.1...v1.35.2) (2026-06-27)


### Bug Fixes

* **matcher:** prompt on temp-file exec instead of hard deny ([#177](https://github.com/JaysonRawlins/claude-gavel/issues/177)) ([7f88b06](https://github.com/JaysonRawlins/claude-gavel/commit/7f88b0635d358bdcff22d35e47dc54db9ab735af))

## [1.35.1](https://github.com/JaysonRawlins/claude-gavel/compare/v1.35.0...v1.35.1) (2026-06-26)


### Bug Fixes

* **matcher:** prompt on exfil-content heuristic instead of silent deny ([#175](https://github.com/JaysonRawlins/claude-gavel/issues/175)) ([c0defe1](https://github.com/JaysonRawlins/claude-gavel/commit/c0defe1a53dcf8a6f154b4ba27ba7603a92a2b74))

## [1.35.0](https://github.com/JaysonRawlins/claude-gavel/compare/v1.34.2...v1.35.0) (2026-06-26)


### Features

* **monitor:** session history viewer + Forget Short triage ([#173](https://github.com/JaysonRawlins/claude-gavel/issues/173)) ([291e306](https://github.com/JaysonRawlins/claude-gavel/commit/291e306d19e311e1ea98252ea29a0f63f867c86f))

## [1.34.2](https://github.com/JaysonRawlins/claude-gavel/compare/v1.34.1...v1.34.2) (2026-06-26)


### Bug Fixes

* **session:** cap and TTL-evict dead-session tombstones ([#171](https://github.com/JaysonRawlins/claude-gavel/issues/171)) ([7228ed2](https://github.com/JaysonRawlins/claude-gavel/commit/7228ed28b21522f4cb14e1df29933afbf6c5631f))

## [1.34.1](https://github.com/JaysonRawlins/claude-gavel/compare/v1.34.0...v1.34.1) (2026-06-24)


### Bug Fixes

* **codex:** drop permissionDecision on codex fail-open allow (0.142 wire contract) ([#169](https://github.com/JaysonRawlins/claude-gavel/issues/169)) ([9bf1afa](https://github.com/JaysonRawlins/claude-gavel/commit/9bf1afa01ef99b539f6974a4c42f530e898e8f75))

## [1.34.0](https://github.com/JaysonRawlins/claude-gavel/compare/v1.33.1...v1.34.0) (2026-06-23)


### Features

* **matcher:** gate mutating kubectl verbs, hard-prompt prod context ([#167](https://github.com/JaysonRawlins/claude-gavel/issues/167)) ([e7dec1b](https://github.com/JaysonRawlins/claude-gavel/commit/e7dec1b2bf213fa155e3f9ceb0fb89d005c6aa34))
* **notifications:** allow-with-note ForceReply on phone approvals ([#168](https://github.com/JaysonRawlins/claude-gavel/issues/168)) ([72b31d4](https://github.com/JaysonRawlins/claude-gavel/commit/72b31d49fdba9193353523abb56df44c5f6a2cac))


### Bug Fixes

* **matcher:** block Bash reads of credential files ([#165](https://github.com/JaysonRawlins/claude-gavel/issues/165)) ([116b9d1](https://github.com/JaysonRawlins/claude-gavel/commit/116b9d105b8b24a7eadb2a06fada8ec8d1326521))

## [1.33.1](https://github.com/JaysonRawlins/claude-gavel/compare/v1.33.0...v1.33.1) (2026-06-21)


### Miscellaneous Chores

* release 1.33.1 ([cbaebce](https://github.com/JaysonRawlins/claude-gavel/commit/cbaebcebe0026281111de239455594202ab07bc3))

## [1.33.0](https://github.com/JaysonRawlins/claude-gavel/compare/v1.32.0...v1.33.0) (2026-06-19)


### Features

* **session:** default phone toggle + [[/stop-phone]] emergency hatch ([#161](https://github.com/JaysonRawlins/claude-gavel/issues/161)) ([a308186](https://github.com/JaysonRawlins/claude-gavel/commit/a3081864d4adde13ea30c4a86744d4d0c1b03ed9))

## [1.32.0](https://github.com/JaysonRawlins/claude-gavel/compare/v1.31.0...v1.32.0) (2026-06-19)


### Features

* **session:** name spawned/remote sessions via GAVEL_SESSION_NAME ([#159](https://github.com/JaysonRawlins/claude-gavel/issues/159)) ([7ffaa4f](https://github.com/JaysonRawlins/claude-gavel/commit/7ffaa4ff919102478b383651bbada4ef5004661b))


### Bug Fixes

* **monitor:** serialize gavelLog writes to stop concurrent-write log drops ([#158](https://github.com/JaysonRawlins/claude-gavel/issues/158)) ([78d2038](https://github.com/JaysonRawlins/claude-gavel/commit/78d20382ef1c5185da79cb713b9f53949f273310))

## [1.31.0](https://github.com/JaysonRawlins/claude-gavel/compare/v1.30.0...v1.31.0) (2026-06-19)


### Features

* **approval:** inline deny-with-reason button via ForceReply ([#156](https://github.com/JaysonRawlins/claude-gavel/issues/156)) ([c8cba1a](https://github.com/JaysonRawlins/claude-gavel/commit/c8cba1ac7658b5096a06a9e769f77feb2982ae79))

## [1.30.0](https://github.com/JaysonRawlins/claude-gavel/compare/v1.29.0...v1.30.0) (2026-06-18)


### Features

* **session:** [[-/skill]] marker to remove a session tag ([#155](https://github.com/JaysonRawlins/claude-gavel/issues/155)) ([8d027d7](https://github.com/JaysonRawlins/claude-gavel/commit/8d027d7f6225601a61257a85cf8370bd9a86f7ee))
* **session:** [[/skill]] manual tag marker, gated to user transcript entries ([#154](https://github.com/JaysonRawlins/claude-gavel/issues/154)) ([a7e84b6](https://github.com/JaysonRawlins/claude-gavel/commit/a7e84b649f837bc52a8142f6bb4922539a6d8734))
* **session:** tag sessions from user-typed skill slash commands ([#152](https://github.com/JaysonRawlins/claude-gavel/issues/152)) ([c16d6a0](https://github.com/JaysonRawlins/claude-gavel/commit/c16d6a00fff4036a578c72555b1b0fb7dc840cd1))

## [1.29.0](https://github.com/JaysonRawlins/claude-gavel/compare/v1.28.0...v1.29.0) (2026-06-18)


### Features

* **approval:** instrument the remote-approval path in gavel.log ([#151](https://github.com/JaysonRawlins/claude-gavel/issues/151)) ([f214002](https://github.com/JaysonRawlins/claude-gavel/commit/f214002af3a5d1db4551bced920e0e6f223513c1))
* **approval:** resolvable withheld remote approvals + gate trigger logging ([#150](https://github.com/JaysonRawlins/claude-gavel/issues/150)) ([c198dcb](https://github.com/JaysonRawlins/claude-gavel/commit/c198dcb963ee39e9f4cdfdbdcab0638d3908ce9e))
* **monitor:** show full session tags in Sessions tab + overflow tooltip ([#148](https://github.com/JaysonRawlins/claude-gavel/issues/148)) ([f59255a](https://github.com/JaysonRawlins/claude-gavel/commit/f59255a3eb191b83178f4fd9d30b3d76f18463be))

## [1.28.0](https://github.com/JaysonRawlins/claude-gavel/compare/v1.27.0...v1.28.0) (2026-06-17)


### Features

* **approval:** launchctl/LaunchAgent fail-closed prompt + opt-in remote-approval enable ([#146](https://github.com/JaysonRawlins/claude-gavel/issues/146)) ([2e6b576](https://github.com/JaysonRawlins/claude-gavel/commit/2e6b5760d218ecf69ec3d9515028d727f99380f7))

## [1.27.0](https://github.com/JaysonRawlins/claude-gavel/compare/v1.26.0...v1.27.0) (2026-06-17)


### Features

* **monitor:** show build version, or "Dev" for local builds ([#144](https://github.com/JaysonRawlins/claude-gavel/issues/144)) ([b99dfe2](https://github.com/JaysonRawlins/claude-gavel/commit/b99dfe243680f90711be64505a6e5191e3512e51))
* **session:** observed skill tags with tag filter and row badges ([#140](https://github.com/JaysonRawlins/claude-gavel/issues/140)) ([bd6e154](https://github.com/JaysonRawlins/claude-gavel/commit/bd6e154062d91a0da23959f4d472d413fb37b5e7))


### Bug Fixes

* **approval:** exclude 2&gt;&1 fd-dup from taint redirect-target capture ([#142](https://github.com/JaysonRawlins/claude-gavel/issues/142)) ([02b8960](https://github.com/JaysonRawlins/claude-gavel/commit/02b8960c94f71d7e50b9fa3e83e528f7b60e57b0))
* **approval:** strip string-literal content before taint extraction ([#145](https://github.com/JaysonRawlins/claude-gavel/issues/145)) ([6144829](https://github.com/JaysonRawlins/claude-gavel/commit/614482995a33727bd6babcf9a13b9e08bdf43014))
* **approval:** whitelist mixed-case kebab/snake identifiers in credential gate ([#143](https://github.com/JaysonRawlins/claude-gavel/issues/143)) ([dd645dc](https://github.com/JaysonRawlins/claude-gavel/commit/dd645dcc7f86efb91a932ff50071256f132ac5b0))
* **matcher:** scope curl data-flag hard-block to credential sources ([#139](https://github.com/JaysonRawlins/claude-gavel/issues/139)) ([451e697](https://github.com/JaysonRawlins/claude-gavel/commit/451e69707fd6fce5f93f56f6f02231c838e251b9))

## [1.26.0](https://github.com/JaysonRawlins/claude-gavel/compare/v1.25.0...v1.26.0) (2026-06-17)


### Features

* **approval:** richer telegram approvals + token source + config self-protect ([#137](https://github.com/JaysonRawlins/claude-gavel/issues/137)) ([bafe5ce](https://github.com/JaysonRawlins/claude-gavel/commit/bafe5ce9988050e5bea0e7cdb328ef23ecb23dec))

## [1.25.0](https://github.com/JaysonRawlins/claude-gavel/compare/v1.24.1...v1.25.0) (2026-06-16)


### Features

* **approval:** telegram remote approval with credential gate ([#134](https://github.com/JaysonRawlins/claude-gavel/issues/134)) ([28de3dd](https://github.com/JaysonRawlins/claude-gavel/commit/28de3dd4b7527049c4d4f0b3b4ebdbfc89942054))


### Bug Fixes

* **approval:** exclude kebab/snake identifiers from credential gate heuristic ([#136](https://github.com/JaysonRawlins/claude-gavel/issues/136)) ([dabd828](https://github.com/JaysonRawlins/claude-gavel/commit/dabd8280817a45e2ea8c5db17e8517de88b2025a))

## [1.24.1](https://github.com/JaysonRawlins/claude-gavel/compare/v1.24.0...v1.24.1) (2026-06-11)


### Bug Fixes

* **matcher:** exclude crontab -l from persistence deny rule ([#132](https://github.com/JaysonRawlins/claude-gavel/issues/132)) ([52414fa](https://github.com/JaysonRawlins/claude-gavel/commit/52414fa99c5a8d1647fd784e6c005649943f9834))

## [1.24.0](https://github.com/JaysonRawlins/claude-gavel/compare/v1.23.0...v1.24.0) (2026-06-09)


### Features

* **approval:** place panels on the active display, remember minimized position ([#130](https://github.com/JaysonRawlins/claude-gavel/issues/130)) ([2da80bf](https://github.com/JaysonRawlins/claude-gavel/commit/2da80bf1f770cb5c732b8f920040a04045e310f0))

## [1.23.0](https://github.com/JaysonRawlins/claude-gavel/compare/v1.22.3...v1.23.0) (2026-06-07)


### Features

* **approval:** show plan-overlay miss context in approval panel ([#128](https://github.com/JaysonRawlins/claude-gavel/issues/128)) ([04bf1de](https://github.com/JaysonRawlins/claude-gavel/commit/04bf1de259a1b5a992f368a367bec65a303b4a21))

## [1.22.3](https://github.com/JaysonRawlins/claude-gavel/compare/v1.22.2...v1.22.3) (2026-06-05)


### Bug Fixes

* **approval:** gate ANTHROPIC_BASE_URL written into file content ([#125](https://github.com/JaysonRawlins/claude-gavel/issues/125)) ([b8f50c7](https://github.com/JaysonRawlins/claude-gavel/commit/b8f50c78c660dbf1c53de9f9196c128b0917e199))

## [1.22.2](https://github.com/JaysonRawlins/claude-gavel/compare/v1.22.1...v1.22.2) (2026-06-05)


### Bug Fixes

* **approval:** normalize line-continuations in PersistentRule bash matching ([#123](https://github.com/JaysonRawlins/claude-gavel/issues/123)) ([c1e150f](https://github.com/JaysonRawlins/claude-gavel/commit/c1e150f09f3884035b774b5b8431cc3c6eb9dbb0))

## [1.22.1](https://github.com/JaysonRawlins/claude-gavel/compare/v1.22.0...v1.22.1) (2026-06-05)


### Bug Fixes

* **approval:** evaluate deny/prompt rules per command segment ([#119](https://github.com/JaysonRawlins/claude-gavel/issues/119)) ([e66645b](https://github.com/JaysonRawlins/claude-gavel/commit/e66645bd9042241b7313bff82290be31960c3972))
* **approval:** protect .mcp.json and ANTHROPIC_BASE_URL writes ([#120](https://github.com/JaysonRawlins/claude-gavel/issues/120)) ([6b044b1](https://github.com/JaysonRawlins/claude-gavel/commit/6b044b1e34f59eca6f5d838b21f7b0834159990c))
* **matcher:** normalize shell line-continuations before bash matching ([#121](https://github.com/JaysonRawlins/claude-gavel/issues/121)) ([e852a16](https://github.com/JaysonRawlins/claude-gavel/commit/e852a16f5b752fac207ce76fa974484beb378868))

## [1.22.0](https://github.com/JaysonRawlins/claude-gavel/compare/v1.21.0...v1.22.0) (2026-06-04)


### Features

* **monitor:** collapse to top-most compact bar on deactivate instead of hiding ([#117](https://github.com/JaysonRawlins/claude-gavel/issues/117)) ([20fccbc](https://github.com/JaysonRawlins/claude-gavel/commit/20fccbc68c962765e857a937ca9d9928cbe92b20))

## [1.21.0](https://github.com/JaysonRawlins/claude-gavel/compare/v1.20.0...v1.21.0) (2026-06-04)


### Features

* **approval:** verify rules.json integrity on load via keyed baseline (tier 2.5) ([#115](https://github.com/JaysonRawlins/claude-gavel/issues/115)) ([d3f39f7](https://github.com/JaysonRawlins/claude-gavel/commit/d3f39f7f322941ceaf0a366fd9c9a834d483c5e3))

## [1.20.0](https://github.com/JaysonRawlins/claude-gavel/compare/v1.19.0...v1.20.0) (2026-06-04)


### Features

* **approval:** watch rules.json and revert out-of-band writes (config integrity tier 2) ([#113](https://github.com/JaysonRawlins/claude-gavel/issues/113)) ([1d1b812](https://github.com/JaysonRawlins/claude-gavel/commit/1d1b812ee36d90b6a3f1e238685199c54c1e2cb5))

## [1.19.0](https://github.com/JaysonRawlins/claude-gavel/compare/v1.18.1...v1.19.0) (2026-06-04)


### Features

* **approval:** enforce rules.json immutability (config integrity tier 1) ([#111](https://github.com/JaysonRawlins/claude-gavel/issues/111)) ([c6348b9](https://github.com/JaysonRawlins/claude-gavel/commit/c6348b98f2674ee6efc701792d8ad11a2e66d74b))

## [1.18.1](https://github.com/JaysonRawlins/claude-gavel/compare/v1.18.0...v1.18.1) (2026-06-04)


### Bug Fixes

* **approval:** block container bind-mount bypass of config self-protection ([#109](https://github.com/JaysonRawlins/claude-gavel/issues/109)) ([eeac163](https://github.com/JaysonRawlins/claude-gavel/commit/eeac16305eaad9c57170b5c0783dcddbf12bd1a6))

## [1.18.0](https://github.com/JaysonRawlins/claude-gavel/compare/v1.17.0...v1.18.0) (2026-06-01)


### Features

* **monitor:** auto-name sessions, open cwd in editor/Tower, forget unnamed ([#107](https://github.com/JaysonRawlins/claude-gavel/issues/107)) ([8e191ef](https://github.com/JaysonRawlins/claude-gavel/commit/8e191efa54607ed7e1fc9941c98cbbbf7c2bd360))

## [1.17.0](https://github.com/JaysonRawlins/claude-gavel/compare/v1.16.1...v1.17.0) (2026-06-01)


### Features

* **monitor:** collapsible compact monitor bar ([#105](https://github.com/JaysonRawlins/claude-gavel/issues/105)) ([b8dea39](https://github.com/JaysonRawlins/claude-gavel/commit/b8dea3900f1d573913bd917faa7ac10b37372c2f))
* **monitor:** log session appear/disappear to gavel.log and the Feed ([#104](https://github.com/JaysonRawlins/claude-gavel/issues/104)) ([067b877](https://github.com/JaysonRawlins/claude-gavel/commit/067b877a83398a7302bc072590993aeb12fd8690))

## [1.16.1](https://github.com/JaysonRawlins/claude-gavel/compare/v1.16.0...v1.16.1) (2026-05-31)


### Bug Fixes

* **session:** detect PID reuse via cwd so stale sessions sleep correctly ([#102](https://github.com/JaysonRawlins/claude-gavel/issues/102)) ([f3895ba](https://github.com/JaysonRawlins/claude-gavel/commit/f3895bacfc42d817f3f647e4aa835a3b7cd97954))

## [1.16.0](https://github.com/JaysonRawlins/claude-gavel/compare/v1.15.0...v1.16.0) (2026-05-30)


### Features

* **approval:** add override verb to release commit checkpoint for GitOps plans ([#99](https://github.com/JaysonRawlins/claude-gavel/issues/99)) ([b6db3e7](https://github.com/JaysonRawlins/claude-gavel/commit/b6db3e7433d1f445dfe0ba00c3c269af8efbf0c5))

## [1.15.0](https://github.com/JaysonRawlins/claude-gavel/compare/v1.14.0...v1.15.0) (2026-05-27)


### Features

* **approval:** replace YOLO bypass with a plan-policy overlay ([#97](https://github.com/JaysonRawlins/claude-gavel/issues/97)) ([aaeb04f](https://github.com/JaysonRawlins/claude-gavel/commit/aaeb04f86f34c1feb6be22ab69eb7970c42c3aad))
* **approval:** standing commit + infra-apply checkpoints, panel label + minimize ([#95](https://github.com/JaysonRawlins/claude-gavel/issues/95)) ([f021cf2](https://github.com/JaysonRawlins/claude-gavel/commit/f021cf2e997e22ba37256c7fa4da15876057308b))

## [1.14.0](https://github.com/JaysonRawlins/claude-gavel/compare/v1.13.0...v1.14.0) (2026-05-23)


### Features

* **approval:** manually select YOLO plan when auto-detect misses ([#90](https://github.com/JaysonRawlins/claude-gavel/issues/90)) ([3baf4f8](https://github.com/JaysonRawlins/claude-gavel/commit/3baf4f81fd13821c1f0508970947e4876d986573))

## [1.13.0](https://github.com/JaysonRawlins/claude-gavel/compare/v1.12.0...v1.13.0) (2026-05-21)


### Features

* **approval:** plan-gated YOLO mode for hands-off agent work ([#88](https://github.com/JaysonRawlins/claude-gavel/issues/88)) ([ffbe151](https://github.com/JaysonRawlins/claude-gavel/commit/ffbe15103a0aea1c4938df5907fa31762e1d8ac2))

## [1.12.0](https://github.com/JaysonRawlins/claude-gavel/compare/v1.11.0...v1.12.0) (2026-05-20)


### Features

* **monitor:** add Plans and Skills quick links to the bottom control bar, and seed `session.label` from the JSONL transcript's latest `/rename` or `--name` at session discovery ([#83](https://github.com/JaysonRawlins/claude-gavel/pull/83)) ([965c237](https://github.com/JaysonRawlins/claude-gavel/commit/965c237e6641223072e211f1d92f070f230452a9))
* **jsonl:** per-session JSONL transcript watcher dispatching new lines through a handler chain — initial handlers are mid-session rename sync (keeps `session.label` current as the user runs `/rename` mid-session) and secret detection with persistent dialog + 5-min cooldown for AWS/GitHub/Anthropic/OpenAI/Slack token patterns ([#84](https://github.com/JaysonRawlins/claude-gavel/pull/84)) ([b78aefa](https://github.com/JaysonRawlins/claude-gavel/commit/b78aefa2))


### Bug Fixes

* **resume:** drop `--name <pid>` from the Resume button's clipboard command — was polluting session titles with the PID every time someone pasted and ran it ([#83](https://github.com/JaysonRawlins/claude-gavel/pull/83)) ([965c237](https://github.com/JaysonRawlins/claude-gavel/commit/965c237e6641223072e211f1d92f070f230452a9))


### Documentation

* **claude-md:** add project `CLAUDE.md` documenting the release-please PR-title convention, dev iteration commands, and Gavel's self-protection deny rule ([#85](https://github.com/JaysonRawlins/claude-gavel/pull/85)) ([88b7c7b](https://github.com/JaysonRawlins/claude-gavel/commit/88b7c7be))


### Miscellaneous Chores

* **release:** backfill v1.12.0 release tracking for [#83](https://github.com/JaysonRawlins/claude-gavel/pull/83) [#84](https://github.com/JaysonRawlins/claude-gavel/pull/84) [#85](https://github.com/JaysonRawlins/claude-gavel/pull/85) ([#86](https://github.com/JaysonRawlins/claude-gavel/pull/86)) ([0418e6d](https://github.com/JaysonRawlins/claude-gavel/commit/0418e6d5a3a3825a35c501d0bb5cccd4afb60917))

## [1.11.0](https://github.com/JaysonRawlins/claude-gavel/compare/v1.10.1...v1.11.0) (2026-05-20)


### Features

* **justfile:** add dev-doctor to catch stale dev paths in hook configs ([#81](https://github.com/JaysonRawlins/claude-gavel/issues/81)) ([5cd808f](https://github.com/JaysonRawlins/claude-gavel/commit/5cd808fd77f513fb2923639ef71df194a5ac8abc))

## [1.10.1](https://github.com/JaysonRawlins/claude-gavel/compare/v1.10.0...v1.10.1) (2026-05-19)


### Bug Fixes

* **matcher:** stop AWS write rule false-firing on --start-time ([#79](https://github.com/JaysonRawlins/claude-gavel/issues/79)) ([8fe26d7](https://github.com/JaysonRawlins/claude-gavel/commit/8fe26d775083884d012fc5b111aa0fe1dcdc8c27))

## [1.10.0](https://github.com/JaysonRawlins/claude-gavel/compare/v1.9.1...v1.10.0) (2026-05-19)


### Features

* **justfile:** make dev-install actually usable — Dev ID signing + dev-daemon ([#77](https://github.com/JaysonRawlins/claude-gavel/issues/77)) ([e0b56f5](https://github.com/JaysonRawlins/claude-gavel/commit/e0b56f5fec07f17d262b0cbae00fdcde44b4e01c))


### Bug Fixes

* **approval:** make Session Allow work for multi-line bash commands ([#76](https://github.com/JaysonRawlins/claude-gavel/issues/76)) ([11309c8](https://github.com/JaysonRawlins/claude-gavel/commit/11309c8ac4191656fe72b2d6a4c5510f6a13df5a))

## [1.9.1](https://github.com/JaysonRawlins/claude-gavel/compare/v1.9.0...v1.9.1) (2026-05-18)


### Bug Fixes

* **hook:** drop updatedInput for Codex callers, gate edit UI ([#72](https://github.com/JaysonRawlins/claude-gavel/issues/72)) ([0478813](https://github.com/JaysonRawlins/claude-gavel/commit/0478813e7c494ba4f8455bc85ef632853b9d82e5))

## [1.9.0](https://github.com/JaysonRawlins/claude-gavel/compare/v1.8.0...v1.9.0) (2026-05-18)


### Features

* codex CLI support — hook compat + install + docs ([#66](https://github.com/JaysonRawlins/claude-gavel/issues/66)) ([dbefae7](https://github.com/JaysonRawlins/claude-gavel/commit/dbefae750764e97d3b6c102ee4af448ec7a68949))
* **install:** codex SessionStart hook — context injection parity with claude ([#70](https://github.com/JaysonRawlins/claude-gavel/issues/70)) ([f0b4b5e](https://github.com/JaysonRawlins/claude-gavel/commit/f0b4b5e03663bcdfeb67eb40bf5331a7bf7ba5c7))
* **monitor:** agent-aware Resume command -- codex sessions get `codex resume <sid>` ([#69](https://github.com/JaysonRawlins/claude-gavel/issues/69)) ([1236849](https://github.com/JaysonRawlins/claude-gavel/commit/1236849b0128eae2c8d03e2b330df9a1ecd8d24e))
* **monitor:** codex sessions get their own row with agent tagging ([#68](https://github.com/JaysonRawlins/claude-gavel/issues/68)) ([26726d2](https://github.com/JaysonRawlins/claude-gavel/commit/26726d24af7441b4a46182381ae6c6c36d4f67fd))

## [1.8.0](https://github.com/JaysonRawlins/claude-gavel/compare/v1.7.0...v1.8.0) (2026-05-16)


### Features

* **monitor:** filter sessions by pid, id, cwd, or name ([#63](https://github.com/JaysonRawlins/claude-gavel/issues/63)) ([1f232d6](https://github.com/JaysonRawlins/claude-gavel/commit/1f232d69c4adac53fa01e284e6aeaad5cbd0d429))
* **monitor:** sleep + resume sessions across daemon restart ([#65](https://github.com/JaysonRawlins/claude-gavel/issues/65)) ([592b455](https://github.com/JaysonRawlins/claude-gavel/commit/592b455fcdc07cf2274376074b621413ce3c524c))

## [1.7.0](https://github.com/JaysonRawlins/claude-gavel/compare/v1.6.0...v1.7.0) (2026-05-13)


### Features

* **monitor+approval:** click PID to focus Ghostty tab ([#61](https://github.com/JaysonRawlins/claude-gavel/issues/61)) ([98ff022](https://github.com/JaysonRawlins/claude-gavel/commit/98ff0220e93cbef7c825d971fc18ad655cec8ecc))

## [1.6.0](https://github.com/JaysonRawlins/claude-gavel/compare/v1.5.0...v1.6.0) (2026-05-11)


### Features

* **approval:** "Allow Rule" suppresses firing prompt rule for session ([#58](https://github.com/JaysonRawlins/claude-gavel/issues/58)) ([9fef8a4](https://github.com/JaysonRawlins/claude-gavel/commit/9fef8a463ac5857bd4f1a560545246448edc8b95))

## [1.5.0](https://github.com/JaysonRawlins/claude-gavel/compare/v1.4.0...v1.5.0) (2026-05-07)


### Features

* **daemon:** per-session state persistence + diagnostic logging ([#56](https://github.com/JaysonRawlins/claude-gavel/issues/56)) ([4c95317](https://github.com/JaysonRawlins/claude-gavel/commit/4c9531765a6a1629a7505c6f2aae57b357438dbe))

## [1.4.0](https://github.com/JaysonRawlins/claude-gavel/compare/v1.3.0...v1.4.0) (2026-05-02)


### Features

* **approval+monitor:** note-flow checkbox + 5s activity flash ([#53](https://github.com/JaysonRawlins/claude-gavel/issues/53)) ([cb4c304](https://github.com/JaysonRawlins/claude-gavel/commit/cb4c304d5f25ab53f3379e655f3c945f28f13847))

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
