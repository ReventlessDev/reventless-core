# Change Log

All notable changes to this project will be documented in this file.
See [Conventional Commits](https://conventionalcommits.org) for commit guidelines.

# 1.0.0-alpha.18 (2026-07-11)

### Bug Fixes

* **vscode-protocol:** tolerate pre-v11 lowercase edge kinds in slice boxing ([afb2439](https://github.com/ReventlessDev/reventless-core/commit/afb2439fd870ba5bc3224a6039020d26f342079b))


# 1.0.0-alpha.17 (2026-07-07)

### Features

* **vscode-protocol:** shared D2 renderer moves in beside GraphOps ([672f1a1](https://github.com/ReventlessDev/reventless-core/commit/672f1a14f058db5a32c339dee1d577af366f7e01))
* **vscode-protocol:** toD2 class overrides for comparison overlays ([9983464](https://github.com/ReventlessDev/reventless-core/commit/9983464a5293f35fd6348a547aabedaf5dd0830f))


# 1.0.0-alpha.16 (2026-07-07)

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



# 1.0.0-alpha.15 (2026-07-06)

### Features

* **vscode-protocol:** add GraphOps — pure domain-graph operations ([8c67c08](https://github.com/ReventlessDev/reventless-core/commit/8c67c080ef229a51d429807aca15a7eba9675182))
* **vscode-protocol:** focus/neighbourhood scoping moves into GraphOps ([eab1bfd](https://github.com/ReventlessDev/reventless-core/commit/eab1bfd2d0181bc052253385b191db311aa2b8dd))


# 1.0.0-alpha.14 (2026-07-06)

### Bug Fixes

* **vscode-protocol:** exclude test sources + jest dep from consumers ([d4e7b11](https://github.com/ReventlessDev/reventless-core/commit/d4e7b11d2a332eac9726029c3c8309066bb0f85a))


# 1.0.0-alpha.13 (2026-07-06)

### Features

* **vscode-protocol:** domain-graph edges gain via + implicit provenance ([8a89931](https://github.com/ReventlessDev/reventless-core/commit/8a89931e887bd4944f0144a4b078037f32205eed))


# 1.0.0-alpha.12 (2026-07-06)

**Note:** Version bump only for package @reventlessdev/reventless-vscode-protocol





# 1.0.0-alpha.11 (2026-07-04)

**Note:** Version bump only for package @reventlessdev/reventless-vscode-protocol





# 1.0.0-alpha.10 (2026-07-03)

**Note:** Version bump only for package @reventlessdev/reventless-vscode-protocol





# 1.0.0-alpha.9 (2026-06-29)

### Features

* external-system boxes for translation slices (Event Graph data) ([3f8ad39](https://github.com/ReventlessDev/reventless-core/commit/3f8ad39b78a3cb1182d59a0e1fb203b7dcb7379b))


# 1.0.0-alpha.8 (2026-06-27)

**Note:** Version bump only for package @reventlessdev/reventless-vscode-protocol





# 1.0.0-alpha.7 (2026-06-20)

### Bug Fixes

* **packaging:** publish rescript packages source-only via .npmignore ([e831c37](https://github.com/ReventlessDev/reventless-core/commit/e831c372b6347d997da1e876c12b6770414f5f41))


# 1.0.0-alpha.6 (2026-06-17)

### Features

* **reventless-dev:** emit component definitions over the NDJSON protocol (Phase 6.3) ([a327084](https://github.com/ReventlessDev/reventless-core/commit/a327084d247d1600c4f9e92624f2b59e856913f7))
* **vscode-protocol:** publish @reventlessdev/reventless-vscode-protocol ([0bdfa4a](https://github.com/ReventlessDev/reventless-core/commit/0bdfa4a7c408e6a58a5a22995f4cfe0cc604500f))


# 1.0.0-alpha.5 (2026-06-10)

### Bug Fixes

* **reventless-vscode:** repair cross-package genType bridge and verify the shared NDJSON contract end-to-end ([f9d2e15](https://github.com/ReventlessDev/reventless-core/commit/f9d2e15ec70ea3def88818cb3acd7a17ba2d240e))
### Features

* **reventless-vscode:** port watchRegistry to ReScript + share the StreamEvent NDJSON contract with the CLI (Phase 3 + Stretch) ([9f9ee8d](https://github.com/ReventlessDev/reventless-core/commit/9f9ee8d73cf754863d364ddae3f899320fed46c0))
* **vscode:** scope views to an active app + continue local event numbering across restarts ([59336f3](https://github.com/ReventlessDev/reventless-core/commit/59336f3ccb30028e1702e29f7941468f67180ff3)), closes [#1](https://github.com/ReventlessDev/reventless-core/issues/1)


# 1.0.0-alpha.4 (2026-06-08)

### Bug Fixes

* **reventless-vscode:** repair cross-package genType bridge and verify the shared NDJSON contract end-to-end ([71d5512](https://github.com/ReventlessDev/reventless-core/commit/71d5512c244739ced99c0cbe4083509174d3273e))


# 1.0.0-alpha.3 (2026-06-08)

### Features

* **reventless-vscode:** port watchRegistry to ReScript + share the StreamEvent NDJSON contract with the CLI (Phase 3 + Stretch) ([a7b0c31](https://github.com/ReventlessDev/reventless-core/commit/a7b0c31b9fc8f25af65aeafa51a0a0a3a9ea1f15))
