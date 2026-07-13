# Change Log

All notable changes to this project will be documented in this file.
See [Conventional Commits](https://conventionalcommits.org) for commit guidelines.

# 1.0.0-alpha.108 (2026-07-13)

**Note:** Version bump only for package @reventlessdev/reventless-gwt





# 1.0.0-alpha.107 (2026-07-13)

**Note:** Version bump only for package @reventlessdev/reventless-gwt





# 1.0.0-alpha.106 (2026-07-13)

**Note:** Version bump only for package @reventlessdev/reventless-gwt





# 1.0.0-alpha.105 (2026-07-12)

**Note:** Version bump only for package @reventlessdev/reventless-gwt





# 1.0.0-alpha.104 (2026-07-12)

**Note:** Version bump only for package @reventlessdev/reventless-gwt





# 1.0.0-alpha.103 (2026-07-12)

### Features

* **admin:** retire the Plugin-aggregate UI-fragment path in favour of the registry slices ([1dbc708](https://github.com/ReventlessDev/reventless-core/commit/1dbc708e7439b34ff970cc3d963d7835a8c6fd48))


# 1.0.0-alpha.102 (2026-07-11)

**Note:** Version bump only for package @reventlessdev/reventless-gwt





# 1.0.0-alpha.101 (2026-07-11)

**Note:** Version bump only for package @reventlessdev/reventless-gwt





# 1.0.0-alpha.100 (2026-07-11)

**Note:** Version bump only for package @reventlessdev/reventless-gwt





# 1.0.0-alpha.99 (2026-07-11)

**Note:** Version bump only for package @reventlessdev/reventless-gwt





# 1.0.0-alpha.98 (2026-07-10)

### Features

* **plugin-structure:** capture per-component chapter grouping for the deployed graph ([f9c88a9](https://github.com/ReventlessDev/reventless-core/commit/f9c88a9a48d8c032ffe23f9e5277caf12c29e85c))


# 1.0.0-alpha.97 (2026-07-10)

**Note:** Version bump only for package @reventlessdev/reventless-gwt





# 1.0.0-alpha.96 (2026-07-10)

**Note:** Version bump only for package @reventlessdev/reventless-gwt





# 1.0.0-alpha.95 (2026-07-10)

**Note:** Version bump only for package @reventlessdev/reventless-gwt





# 1.0.0-alpha.94 (2026-07-09)

**Note:** Version bump only for package @reventlessdev/reventless-gwt





# 1.0.0-alpha.93 (2026-07-09)

**Note:** Version bump only for package @reventlessdev/reventless-gwt





# 1.0.0-alpha.92 (2026-07-08)

**Note:** Version bump only for package @reventlessdev/reventless-gwt





# 1.0.0-alpha.91 (2026-07-08)

### Features

* **reventless-core:** classify plugins by kind in the lifecycle read model ([64e3f22](https://github.com/ReventlessDev/reventless-core/commit/64e3f22b8114a771886b7c8ec023e95971413c0b))


# 1.0.0-alpha.90 (2026-07-08)

**Note:** Version bump only for package @reventlessdev/reventless-gwt





# 1.0.0-alpha.89 (2026-07-07)

**Note:** Version bump only for package @reventlessdev/reventless-gwt





# 1.0.0-alpha.88 (2026-07-07)

**Note:** Version bump only for package @reventlessdev/reventless-gwt





# 1.0.0-alpha.87 (2026-07-07)

* feat(vscode-protocol)!: typed kind vocabularies (protocol v11, PascalCase wire) ([c087e76](https://github.com/ReventlessDev/reventless-core/commit/c087e76b8e2ed02ba98e7b0ce5c63eed35b39878))

### BREAKING CHANGES

* every kind vocabulary is uniformly PascalCase on the wire
(handles→Handles, file→File, …) and protocolVersion bumps to 11. The event
envelope is unchanged; unknown kinds degrade gracefully. Consumers keying on
kind strings must respell. The new minCompatibleProtocol/isCompatible exports
pin the advisory (warn, don't refuse) compat policy.

- GraphOps predicates/baseKind/isFqKind become exhaustive matches; read edges typed
- gwt emitters construct variants (DomainGraph, FormatterVsCode, DomainDeadCode)
- golden fixture regenerated; one appended Other* unknown-kind sample per typed field
- fixes two sample values that never occurred on the wire (orphanEvent, notEqual)
- BridgeDriftTest pins both hand-written genType bridges against src/*.gen.ts
  (surfaced missing position/failLocation re-exports — added)
- plan → docs/plans/done/vscode-protocol-hardening.md



# 1.0.0-alpha.86 (2026-07-06)

**Note:** Version bump only for package @reventlessdev/reventless-gwt





# 1.0.0-alpha.85 (2026-07-06)

**Note:** Version bump only for package @reventlessdev/reventless-gwt





# 1.0.0-alpha.84 (2026-07-06)

**Note:** Version bump only for package @reventlessdev/reventless-gwt





# 1.0.0-alpha.83 (2026-07-06)

### Features

* **reventless-aws:** classic EventLog Postgres deploy-time wiring + relay (B1 vertical) ([8235ba4](https://github.com/ReventlessDev/reventless-core/commit/8235ba44e506f7094d17251405c6a05c39789805))


# 1.0.0-alpha.82 (2026-07-05)

**Note:** Version bump only for package @reventlessdev/reventless-gwt





# 1.0.0-alpha.81 (2026-07-05)

**Note:** Version bump only for package @reventlessdev/reventless-gwt





# 1.0.0-alpha.80 (2026-07-05)

**Note:** Version bump only for package @reventlessdev/reventless-gwt





# 1.0.0-alpha.79 (2026-07-05)

**Note:** Version bump only for package @reventlessdev/reventless-gwt





# 1.0.0-alpha.78 (2026-07-04)

**Note:** Version bump only for package @reventlessdev/reventless-gwt





# 1.0.0-alpha.77 (2026-07-03)

### Performance Improvements

* **gwt:** affected-set watch re-runs + parent-owned discovery (plan B1) ([e7f4e6b](https://github.com/ReventlessDev/reventless-core/commit/e7f4e6bff8c28fdbcf1b15503005ed2ac613fa06))
* **gwt:** graph-reload dedup, build-classifier fixes, drop quadratic walks (plan B3) ([aeda1b4](https://github.com/ReventlessDev/reventless-core/commit/aeda1b47aec36373aee788def449959a290042f3))


# 1.0.0-alpha.76 (2026-07-02)

### Bug Fixes

* **gwt:** harden watch runner process/lifecycle/fidelity (plan A2–A4) ([9d5d566](https://github.com/ReventlessDev/reventless-core/commit/9d5d566f2de572b6de19c18e5a1d3dd53982f1e8))
* **gwt:** run each watch re-run in a fresh worker (plan A1/B2) ([af71131](https://github.com/ReventlessDev/reventless-core/commit/af711312b8d6f7482ee22faaa3265e72ca3ed68b))


# 1.0.0-alpha.75 (2026-06-29)

### Features

* external-system boxes for translation slices (Event Graph data) ([3f8ad39](https://github.com/ReventlessDev/reventless-core/commit/3f8ad39b78a3cb1182d59a0e1fb203b7dcb7379b))


# 1.0.0-alpha.74 (2026-06-27)

### Features

* **dcb:** infer cross-partition scope; drop [@cross](https://github.com/cross)Partition from hybrid catalog ([268c57b](https://github.com/ReventlessDev/reventless-core/commit/268c57b1620b6075d2259f3a312efd04ecd735d5))
* **gwt:** add `todo` binding for spec-less slice scaffolds ([c8ecf02](https://github.com/ReventlessDev/reventless-core/commit/c8ecf0255b324afc4d2bb7258f7e9fd2a4c820be))
* **gwt:** catch unreachable cross-entity reads in per-slice Behavior GWT ([9666033](https://github.com/ReventlessDev/reventless-core/commit/96660335e8b5642b0798fde2231fb0ddad8f90d7))
* verify category exists in AddProduct via cross-partition DCB read ([074d4fa](https://github.com/ReventlessDev/reventless-core/commit/074d4faecf694164f2e0c789c4d94cae402b03e1))


# 1.0.0-alpha.73 (2026-06-22)

### Bug Fixes

* **domain-graph:** route EP commands only with a real inbound protocol ([647d1fa](https://github.com/ReventlessDev/reventless-core/commit/647d1fa0194189f4d53cf5fca0f2ef4045b983f9))
* **reflection:** surface payload-less commands & events in the event graph ([71819cf](https://github.com/ReventlessDev/reventless-core/commit/71819cf71fc7b0b0e1fc64fb7dce23f84f69b38d))
### Features

* **domain-graph:** draw the commands reacting slices raise on their target ([b990be2](https://github.com/ReventlessDev/reventless-core/commit/b990be293305544385abf7c2093161fc9a75c78c))
* **gwt:** pin local platform to fixed ports via --ui-ports ([ee60259](https://github.com/ReventlessDev/reventless-core/commit/ee602590b37908747f6e41c718861720efac61a0))
* **structure:** mark API-exposed commands for the event-graph badge ([8cd6faa](https://github.com/ReventlessDev/reventless-core/commit/8cd6faa0a66c6cf1b4b5eea26df6f70c540b67a4))


# 1.0.0-alpha.72 (2026-06-21)

### Features

* **dcb:** cross-partition secondary-tag reads (Phase 7) ([9e1f8b3](https://github.com/ReventlessDev/reventless-core/commit/9e1f8b3595004b92148dd053aae380078baa42a3))


# 1.0.0-alpha.71 (2026-06-21)

**Note:** Version bump only for package @reventlessdev/reventless-gwt





# 1.0.0-alpha.70 (2026-06-21)

**Note:** Version bump only for package @reventlessdev/reventless-gwt





# 1.0.0-alpha.69 (2026-06-20)

### Features

* **dcb:** narrow query clauses to types that can carry each tag (Issue 14) ([6bceae6](https://github.com/ReventlessDev/reventless-core/commit/6bceae675b91154b5a1abf73a6aaca56533cbbe8))


# 1.0.0-alpha.68 (2026-06-20)

**Note:** Version bump only for package @reventlessdev/reventless-gwt





# 1.0.0-alpha.67 (2026-06-20)

### Bug Fixes

* **packaging:** publish rescript packages source-only via .npmignore ([e831c37](https://github.com/ReventlessDev/reventless-core/commit/e831c372b6347d997da1e876c12b6770414f5f41))


# 1.0.0-alpha.66 (2026-06-20)

**Note:** Version bump only for package @reventlessdev/reventless-gwt





# 1.0.0-alpha.65 (2026-06-20)

**Note:** Version bump only for package @reventlessdev/reventless-gwt





# 1.0.0-alpha.64 (2026-06-18)

### Features

* **domain-graph:** extension point routes to its delegate's commands ([8226b4b](https://github.com/ReventlessDev/reventless-core/commit/8226b4bbfb98a066cfc2fe200c890916af2306a3))
* **gwt:** clean-rebuild a package when a source module is relocated (Phase 12) ([e6a4843](https://github.com/ReventlessDev/reventless-core/commit/e6a4843af036f900f50ca4f16c82616cff06298f))


# 1.0.0-alpha.63 (2026-06-18)

**Note:** Version bump only for package @reventlessdev/reventless-gwt





# 1.0.0-alpha.62 (2026-06-18)

**Note:** Version bump only for package @reventlessdev/reventless-gwt





# 1.0.0-alpha.61 (2026-06-18)

### Bug Fixes

* **graph:** route extension edges to the commands they create ([31c8d50](https://github.com/ReventlessDev/reventless-core/commit/31c8d5031c87258d68af20e738d091f7011836b3))


# 1.0.0-alpha.60 (2026-06-17)

**Note:** Version bump only for package @reventlessdev/reventless-gwt





# 1.0.0-alpha.59 (2026-06-17)

### Bug Fixes

* **packaging:** executable ppx binaries + promote phantom deps for standalone installs ([9b6bea2](https://github.com/ReventlessDev/reventless-core/commit/9b6bea24570b0b0654c825d560ef781c0295512a))
* feat!: rename Call directive to HandleDirective for naming consistency ([3fdf84a](https://github.com/ReventlessDev/reventless-core/commit/3fdf84a503b8ee9b07d0774e34c911f5d90d45d0))
### Features

* **core:** carry emitted-event field schemas in pluginStructure (Phase 6.3) ([693d452](https://github.com/ReventlessDev/reventless-core/commit/693d4529ee4c66a2a4a4b0d4d7efb104cf94bcab))
* **gwt:** add Flow_GWT.AggregateCommandStep ([3be5afe](https://github.com/ReventlessDev/reventless-core/commit/3be5afe19458dbdf4a37b680f18870e2abc8bda5))
* **gwt:** add SideEffect_GWT for aggregate-style egress ([cb6e88d](https://github.com/ReventlessDev/reventless-core/commit/cb6e88dfa73c7772f7519b6fece9cd10771ff30a))
* **gwt:** assert handled directives in Delegate_GWT ([b4ca27e](https://github.com/ReventlessDev/reventless-core/commit/b4ca27e3aa0e2588610aefc62ad927da935a6a08))
* **gwt:** bidirectional Delegate_GWT drivers with direction-named verbs ([bb5de9e](https://github.com/ReventlessDev/reventless-core/commit/bb5de9eff2b06cedd72bc6c70747c8159937044e))
* **gwt:** cross-plugin AggregatesFlow_GWT + close hybrid-parity plan ([e223566](https://github.com/ReventlessDev/reventless-core/commit/e223566c54938ed6dcb8d8bd4570e0fd0f30ca07))
* **reventless-dev:** emit component definitions over the NDJSON protocol (Phase 6.3) ([a327084](https://github.com/ReventlessDev/reventless-core/commit/a327084d247d1600c4f9e92624f2b59e856913f7))

### BREAKING CHANGES

* out-of-tree plugins emitting Call(handler, msg) from
commandAction / eventAction / incomingCommandAction / outgoingCommandAction
must rename to HandleDirective(handler, directive). The callHandler<'msg>
type alias is now directiveHandler<'directive>.

Plan: docs/plans/done/directive-naming-consistency.md



# 1.0.0-alpha.58 (2026-06-12)

**Note:** Version bump only for package @reventlessdev/reventless-gwt





# 1.0.0-alpha.57 (2026-06-12)

### Features

* **vscode:** jump from event-graph nodes to source + show Internal components in the dev graph ([6a6e5e4](https://github.com/ReventlessDev/reventless-core/commit/6a6e5e466c6ea5c0c7315ccc37a538e0b496c99a))


# 1.0.0-alpha.56 (2026-06-11)

**Note:** Version bump only for package @reventlessdev/reventless-gwt





# 1.0.0-alpha.55 (2026-06-10)

### Bug Fixes

* **reventless-gwt,reventless-vscode:** clear stuck build-status spinner when a watcher dies or hangs ([1a6c1aa](https://github.com/ReventlessDev/reventless-core/commit/1a6c1aa624f5b740bd826a0b7d82bd8d58d4e342))
* **reventless-gwt,reventless-vscode:** render platform log in a Pseudoterminal (ANSI colors) ([b3a848f](https://github.com/ReventlessDev/reventless-core/commit/b3a848f457c7144a9d3156888e64fcfd8cf8b29d))
* **reventless-gwt:** adopt rescript watch (watch.lock) so the engine coexists with rescript-vscode ([464d127](https://github.com/ReventlessDev/reventless-core/commit/464d127c774a08bb6366aab10bb5772f427a890a))
* **reventless-gwt:** prune the GWT DSL modules in src/ from discovery ([849ea0a](https://github.com/ReventlessDev/reventless-core/commit/849ea0add03edd42b5f08f4e64d96468fe57058c))
* **reventless-gwt:** render inline-record variant payloads in GWT diffs ([fe78c9d](https://github.com/ReventlessDev/reventless-core/commit/fe78c9de6a50417ded5103c1cb1974ba0a80459e))
* **reventless-gwt:** strip ANSI from platform runner log lines ([28786d2](https://github.com/ReventlessDev/reventless-core/commit/28786d2062488dd71aba62eb40477774c4c73942))
* **reventless-gwt:** surface ReScript exception messages in test runner ([f73dbc3](https://github.com/ReventlessDev/reventless-core/commit/f73dbc3a721fb2671b4099ceb86e9bcf107703ff))
* **reventless-vscode:** repair cross-package genType bridge and verify the shared NDJSON contract end-to-end ([f9d2e15](https://github.com/ReventlessDev/reventless-core/commit/f9d2e15ec70ea3def88818cb3acd7a17ba2d240e))
### Features

* **reventless-core:** extension-point source events in pluginStructure ([9c47a0e](https://github.com/ReventlessDev/reventless-core/commit/9c47a0ea9a1643ac12fbe8dc1c43244e580de024))
* **reventless-gwt,reventless-vscode:** runner Phase 6 — Sqlite toggle, replay, export ([43356f7](https://github.com/ReventlessDev/reventless-core/commit/43356f7b453a9dd3ed03eced16cc95b8b70309e6))
* **reventless-gwt:** carry component source files on the components event ([64c7057](https://github.com/ReventlessDev/reventless-core/commit/64c705745a7f3606b64aa08f824ea58f7b539681))
* **reventless-gwt:** CLI-managed watch engine for zero-config editor testing ([4f6445f](https://github.com/ReventlessDev/reventless-core/commit/4f6445f6942972e62ee4e34a4ec4e98e9eb41a3e))
* **reventless-gwt:** component-aware discovery — component field + components inventory (protocol 2) ([564c583](https://github.com/ReventlessDev/reventless-core/commit/564c583c3707b82ce2538bd76dd9996e313cef8d))
* **reventless-gwt:** emit mismatch kind on testFail (protocol 3) ([8269878](https://github.com/ReventlessDev/reventless-core/commit/826987818d506a5fc1aac21e0b46d776c313395b))
* **reventless-gwt:** event-modeling graph event (Phase 6), protocol 6 ([a36d7f2](https://github.com/ReventlessDev/reventless-core/commit/a36d7f25e55c500164879ebbe0274d6989c8cf7e))
* **reventless-gwt:** local platform runner CLI (reventless-gwt platform) ([1be0be7](https://github.com/ReventlessDev/reventless-core/commit/1be0be7eca04acf4876d9e71e20d9ccdd049151c))
* **reventless-gwt:** local-host foundation + domain dead-code (Phases 4.5, 5) ([23c368a](https://github.com/ReventlessDev/reventless-core/commit/23c368a1b171dd14bc70d277d6d75bd2ac048a46))
* **reventless-gwt:** prune .gwtignore subtrees from discovery and component scan ([51ab8b1](https://github.com/ReventlessDev/reventless-core/commit/51ab8b180df9a6cb6a68b3c9203ab385d215b29d))
* **reventless-vscode:** port watchRegistry to ReScript + share the StreamEvent NDJSON contract with the CLI (Phase 3 + Stretch) ([9f9ee8d](https://github.com/ReventlessDev/reventless-core/commit/9f9ee8d73cf754863d364ddae3f899320fed46c0))
* **vscode:** scope views to an active app + continue local event numbering across restarts ([59336f3](https://github.com/ReventlessDev/reventless-core/commit/59336f3ccb30028e1702e29f7941468f67180ff3)), closes [#1](https://github.com/ReventlessDev/reventless-core/issues/1)


# 1.0.0-alpha.54 (2026-06-08)

**Note:** Version bump only for package @reventlessdev/reventless-gwt





# 1.0.0-alpha.53 (2026-06-08)

### Bug Fixes

* **reventless-vscode:** repair cross-package genType bridge and verify the shared NDJSON contract end-to-end ([71d5512](https://github.com/ReventlessDev/reventless-core/commit/71d5512c244739ced99c0cbe4083509174d3273e))


# 1.0.0-alpha.52 (2026-06-08)

### Features

* **reventless-vscode:** port watchRegistry to ReScript + share the StreamEvent NDJSON contract with the CLI (Phase 3 + Stretch) ([a7b0c31](https://github.com/ReventlessDev/reventless-core/commit/a7b0c31b9fc8f25af65aeafa51a0a0a3a9ea1f15))


# 1.0.0-alpha.51 (2026-06-08)

### Bug Fixes

* **reventless-gwt,reventless-vscode:** render platform log in a Pseudoterminal (ANSI colors) ([1838de5](https://github.com/ReventlessDev/reventless-core/commit/1838de58f23946c8ee99058e110f0d56acc590f8))
* **reventless-gwt:** strip ANSI from platform runner log lines ([99bbab4](https://github.com/ReventlessDev/reventless-core/commit/99bbab46b1b9a9c1b6bab634c8c6647323a2ba7d))
### Features

* **reventless-core:** extension-point source events in pluginStructure ([1e1d925](https://github.com/ReventlessDev/reventless-core/commit/1e1d9258b5a228b9fdfa003348a5367281573b3c))
* **reventless-gwt,reventless-vscode:** runner Phase 6 — Sqlite toggle, replay, export ([3c6e7c9](https://github.com/ReventlessDev/reventless-core/commit/3c6e7c93aa4e5ae8cd0a5d385362c1aaacb76587))
* **reventless-gwt:** event-modeling graph event (Phase 6), protocol 6 ([0a78913](https://github.com/ReventlessDev/reventless-core/commit/0a78913d21ad348660f1b190603e4c511dd292e6))
* **reventless-gwt:** local platform runner CLI (reventless-gwt platform) ([a5a8b6c](https://github.com/ReventlessDev/reventless-core/commit/a5a8b6c93b722e1c6249a538a64159af6ebfe6ad))


# 1.0.0-alpha.50 (2026-06-07)

### Bug Fixes

* **reventless-gwt,reventless-vscode:** clear stuck build-status spinner when a watcher dies or hangs ([3ee777e](https://github.com/ReventlessDev/reventless-core/commit/3ee777e03591443b81bbdfe423bf009d48c9d084))
### Features

* **reventless-gwt:** local-host foundation + domain dead-code (Phases 4.5, 5) ([1e5242a](https://github.com/ReventlessDev/reventless-core/commit/1e5242ae8c9cf60ce23342b2bdeb8be45667cee6))


# 1.0.0-alpha.49 (2026-06-06)

### Bug Fixes

* **reventless-gwt:** adopt rescript watch (watch.lock) so the engine coexists with rescript-vscode ([efbbbd2](https://github.com/ReventlessDev/reventless-core/commit/efbbbd2dd52ddf0df025e02dbbe9b7b87b3169ac))
* **reventless-gwt:** prune the GWT DSL modules in src/ from discovery ([494f244](https://github.com/ReventlessDev/reventless-core/commit/494f24442c2ceec01751faaa65b22730e6541983))
* **reventless-gwt:** render inline-record variant payloads in GWT diffs ([5fbcebd](https://github.com/ReventlessDev/reventless-core/commit/5fbcebd080c447836c719c6b0015af35b3c801cb))
* **reventless-gwt:** surface ReScript exception messages in test runner ([4e3faf9](https://github.com/ReventlessDev/reventless-core/commit/4e3faf942e98d7e6e968f993726a0214ea6c0a14))
### Features

* **reventless-gwt:** carry component source files on the components event ([0c7f794](https://github.com/ReventlessDev/reventless-core/commit/0c7f79405d24444ed8e35bde774965ab24829712))
* **reventless-gwt:** CLI-managed watch engine for zero-config editor testing ([706360c](https://github.com/ReventlessDev/reventless-core/commit/706360c0cfd80d8044e100fbd6480e4e4cc35d95))
* **reventless-gwt:** component-aware discovery — component field + components inventory (protocol 2) ([de427a1](https://github.com/ReventlessDev/reventless-core/commit/de427a132b4760b6c61c61413bb38cdbad74e519))
* **reventless-gwt:** emit mismatch kind on testFail (protocol 3) ([e248a6e](https://github.com/ReventlessDev/reventless-core/commit/e248a6e58a13529b911157cd76513e9f63ee5bac))
* **reventless-gwt:** prune .gwtignore subtrees from discovery and component scan ([e7194be](https://github.com/ReventlessDev/reventless-core/commit/e7194be826a92fd78d68928a7515ee4a2a58d175))


# 1.0.0-alpha.48 (2026-06-04)

**Note:** Version bump only for package @reventlessdev/reventless-gwt





# 1.0.0-alpha.47 (2026-06-04)

**Note:** Version bump only for package @reventlessdev/reventless-gwt





# 1.0.0-alpha.46 (2026-06-04)

**Note:** Version bump only for package @reventlessdev/reventless-gwt





# 1.0.0-alpha.45 (2026-06-04)

**Note:** Version bump only for package @reventlessdev/reventless-gwt





# 1.0.0-alpha.44 (2026-06-04)

**Note:** Version bump only for package @reventlessdev/reventless-gwt





# 1.0.0-alpha.43 (2026-05-28)

**Note:** Version bump only for package @reventlessdev/reventless-gwt





# 1.0.0-alpha.42 (2026-05-28)

**Note:** Version bump only for package @reventlessdev/reventless-gwt





# 1.0.0-alpha.41 (2026-05-27)

### Bug Fixes

* **framework:** wire plugin ExtensionPoints into EventCollector runtime context ([2ce8dff](https://github.com/ReventlessDev/reventless-core/commit/2ce8dff426b576811a28c012934d77ecba8a33c0))


# 1.0.0-alpha.40 (2026-05-27)

**Note:** Version bump only for package @reventlessdev/reventless-gwt





# 1.0.0-alpha.39 (2026-05-27)

**Note:** Version bump only for package @reventlessdev/reventless-gwt





# 1.0.0-alpha.38 (2026-05-27)

**Note:** Version bump only for package @reventlessdev/reventless-gwt





# 1.0.0-alpha.37 (2026-05-26)

**Note:** Version bump only for package @reventlessdev/reventless-gwt





# 1.0.0-alpha.36 (2026-05-26)

**Note:** Version bump only for package @reventlessdev/reventless-gwt





# 1.0.0-alpha.35 (2026-05-25)

**Note:** Version bump only for package @reventlessdev/reventless-gwt





# 1.0.0-alpha.34 (2026-05-25)

**Note:** Version bump only for package @reventlessdev/reventless-gwt





# 1.0.0-alpha.33 (2026-05-25)

**Note:** Version bump only for package @reventlessdev/reventless-gwt





# 1.0.0-alpha.32 (2026-05-21)

### Features

* **gwt:** add Delegate_GWT + Flow_GWT cross-slice/cross-plugin test kinds ([19f89a6](https://github.com/ReventlessDev/reventless-core/commit/19f89a6baba3acddb683c81952692fb1a695681d))


# 1.0.0-alpha.31 (2026-05-21)

**Note:** Version bump only for package @reventlessdev/reventless-gwt





# 1.0.0-alpha.30 (2026-05-21)

**Note:** Version bump only for package @reventlessdev/reventless-gwt





# 1.0.0-alpha.29 (2026-05-20)

**Note:** Version bump only for package @reventlessdev/reventless-gwt





# 1.0.0-alpha.28 (2026-05-20)

**Note:** Version bump only for package @reventlessdev/reventless-gwt





# 1.0.0-alpha.27 (2026-05-20)

**Note:** Version bump only for package @reventlessdev/reventless-gwt





# 1.0.0-alpha.26 (2026-05-19)

**Note:** Version bump only for package @reventlessdev/reventless-gwt





# 1.0.0-alpha.25 (2026-05-19)

**Note:** Version bump only for package @reventlessdev/reventless-gwt





# 1.0.0-alpha.24 (2026-05-19)

**Note:** Version bump only for package @reventlessdev/reventless-gwt





# 1.0.0-alpha.23 (2026-05-19)

**Note:** Version bump only for package @reventlessdev/reventless-gwt





# 1.0.0-alpha.22 (2026-05-18)

**Note:** Version bump only for package @reventlessdev/reventless-gwt





# 1.0.0-alpha.21 (2026-05-18)

**Note:** Version bump only for package @reventlessdev/reventless-gwt





# 1.0.0-alpha.20 (2026-05-17)

**Note:** Version bump only for package @reventlessdev/reventless-gwt





# 1.0.0-alpha.19 (2026-05-17)

### Bug Fixes

* **deps:** pin sury-ppx to 11.0.0-alpha.2 to prevent prerelease drift ([c9d05fe](https://github.com/ReventlessDev/reventless-core/commit/c9d05fe5118a9c0442ca3e071f2606b3a139fc81))


# 1.0.0-alpha.18 (2026-05-17)

**Note:** Version bump only for package @reventlessdev/reventless-gwt





# 1.0.0-alpha.17 (2026-05-17)

### Bug Fixes

* **deps:** pin sury to 11.0.0-alpha.4 to unblock Lambda Layer deploys ([643d925](https://github.com/ReventlessDev/reventless-core/commit/643d92527fa9d092da9bef8547591e39a4c609dd))


# 1.0.0-alpha.16 (2026-05-17)

**Note:** Version bump only for package @reventlessdev/reventless-gwt





# 1.0.0-alpha.15 (2026-05-17)

**Note:** Version bump only for package @reventlessdev/reventless-gwt





# 1.0.0-alpha.14 (2026-05-16)

**Note:** Version bump only for package @reventlessdev/reventless-gwt





# 1.0.0-alpha.13 (2026-05-16)

### Features

* **ppx:** add @[@reventless](https://github.com/reventless).visibility to hide components from AutoUI ([bd302cf](https://github.com/ReventlessDev/reventless-core/commit/bd302cfc5bd5d4dfe50c8e1bf8596ab67e36c74e))


# 1.0.0-alpha.12 (2026-05-16)

**Note:** Version bump only for package @reventlessdev/reventless-gwt





# 1.0.0-alpha.11 (2026-05-16)

**Note:** Version bump only for package @reventlessdev/reventless-gwt





# 1.0.0-alpha.10 (2026-05-14)

### Features

* **ppx:** inline-spec walk + Spec module types require authorization ([7db9ec0](https://github.com/ReventlessDev/reventless-core/commit/7db9ec0f186578ce0088973dba22da9257be6a61))


# 1.0.0-alpha.9 (2026-05-13)

* feat(spec)!: standardise event/command envelope (StoredEvent, optional meta, position, persisted DCB meta, causation) ([7ef3176](https://github.com/ReventlessDev/reventless-core/commit/7ef3176c6330810c817f43a52b881b5a0efee30e))

### BREAKING CHANGES

* meta.ip / meta.user go from required `string` to optional
record fields (`?: string`). Code that did `meta.user == "unknown"` to
detect system messages must check for field absence. Storage tables built
before this change are not migrated (greenfield — recreate the EventLog /
DcbEventLog tables; DynamoDB range key renamed from `seq` to `position`,
SQLite dcb_event gains meta and recorded_at columns).



# 1.0.0-alpha.8 (2026-05-10)

**Note:** Version bump only for package @reventlessdev/reventless-gwt





# 1.0.0-alpha.7 (2026-05-05)

**Note:** Version bump only for package @reventlessdev/reventless-gwt





# 1.0.0-alpha.6 (2026-05-04)

**Note:** Version bump only for package @reventlessdev/reventless-gwt





# 1.0.0-alpha.5 (2026-05-03)

**Note:** Version bump only for package @reventlessdev/reventless-gwt





# 1.0.0-alpha.4 (2026-05-03)

**Note:** Version bump only for package @reventlessdev/reventless-gwt





# 1.0.0-alpha.3 (2026-05-03)

### Bug Fixes

* three follow-ups from the GWT-coverage migration ([3be14a4](https://github.com/ReventlessDev/reventless-core/commit/3be14a4cab276a989ae4a93aa650a6086ec118cf))


# 1.0.0-alpha.2 (2026-04-28)

**Note:** Version bump only for package @reventlessdev/reventless-gwt





# 1.0.0-alpha.1 (2026-04-27)

**Note:** Version bump only for package @reventlessdev/reventless-gwt





# 1.0.0-alpha.0 (2026-04-26)

### Bug Fixes

* **gwt:** respect [@sub](https://github.com/sub)Id in StateViewSlice_GWT save function ([7173648](https://github.com/ReventlessDev/reventless-core/commit/71736483f84d6c66b24f3a5361aedad12e3135be))
* feat(gwt)!: rename slice GWT DSLs to short kind names ([4b2e457](https://github.com/ReventlessDev/reventless-core/commit/4b2e45743a777aa85898763db0c5042443b31c97))
### Features

* **spec:** split slice spec module types — Phase 1 of Spec-First series ([d3b1493](https://github.com/ReventlessDev/reventless-core/commit/d3b149300d09dbac45a5e316343cd79fe2a769e6))

### BREAKING CHANGES

* AutomationSlice_GWT, InboundTranslationSlice_GWT, and
OutboundTranslationSlice_GWT are renamed without deprecation shims.
Update explicit include ReventlessGwt.<Old>.Make(...) lines to the new
short names.



# 0.1.0-alpha.2 (2026-04-24)

### Features

* **ppx:** auto-open companion `<Stem>_Fixtures` in @[@reventless](https://github.com/reventless).gwt ([c429e43](https://github.com/ReventlessDev/reventless-core/commit/c429e43383360968cb70cd2c73316445d33c8bcc))
* **ppx:** infer external Spec from path in @[@reventless](https://github.com/reventless).gwt ([54735d1](https://github.com/ReventlessDev/reventless-core/commit/54735d1727932f3dff249a551d40b9861f3996ed))


# 0.1.0-alpha.1 (2026-04-24)

### Bug Fixes

* **gwt:** clear stale failed state in VS Code continuous run ([155f0ac](https://github.com/ReventlessDev/reventless-core/commit/155f0ac14dc60fad39f10d3dd700d7ff5a7ade40))
### Features

* **gwt:** add @[@reventless](https://github.com/reventless).gwt PPX annotation (Stage 9) ([f6c3a65](https://github.com/ReventlessDev/reventless-core/commit/f6c3a65e0906b4fa09688c3c9907245701dca3da))
* **gwt:** add 5 DCB slice DSLs and thread slice name into hints (Stage 3) ([62b59fd](https://github.com/ReventlessDev/reventless-core/commit/62b59fdaa745d7799209ec3c24c50a8d443670b5))
* **gwt:** add CLI runner with 5 output formats (Stage 7) ([e90a01a](https://github.com/ReventlessDev/reventless-core/commit/e90a01a46deeb955cedb343001a4a544ca8ff3b5))
* **gwt:** add Outcome algebra and JestBind adapter (Stage 2) ([4a2d783](https://github.com/ReventlessDev/reventless-core/commit/4a2d783bee3812743c0a3583869b69b27207125c))
* **gwt:** add Query_GWT for ReadModel + StateViewSlice queries (Stage 6) ([0f239f4](https://github.com/ReventlessDev/reventless-core/commit/0f239f4cad80f5a3f1f47135fa4599898d9214b8))
* **gwt:** add reventless-vscode extension (Stage 8) ([731008c](https://github.com/ReventlessDev/reventless-core/commit/731008c961f670aaa699fb53d74d6d5a41578942))
* **gwt:** add Stage 4 AppendConditionMismatch + Stage 5 Mapping_GWT ([24fa835](https://github.com/ReventlessDev/reventless-core/commit/24fa8353657329e73a04cfed8e0a390806ff3395))
* **gwt:** extract GWT test DSLs into @reventlessdev/reventless-gwt package ([dd64b4e](https://github.com/ReventlessDev/reventless-core/commit/dd64b4e1fd0bb203821d055b6743a52aec1836fb))
* **gwt:** resolve vscode test clicks to .res and add continuous run ([7409e76](https://github.com/ReventlessDev/reventless-core/commit/7409e7602da0e5faaf1232c356ab05c146bc24a6))
* **gwt:** shorten file labels in CLI human output and VS Code Testing panel ([b99e093](https://github.com/ReventlessDev/reventless-core/commit/b99e093e6179b67ef073ea8c3087b6de70cda246))
* **gwt:** silence CLI logs by default; add vscode testing guide ([9f124da](https://github.com/ReventlessDev/reventless-core/commit/9f124dac32a408ca88011d9b15e4de6bde624c74))
