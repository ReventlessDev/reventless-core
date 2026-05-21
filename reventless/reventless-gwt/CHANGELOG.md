# Change Log

All notable changes to this project will be documented in this file.
See [Conventional Commits](https://conventionalcommits.org) for commit guidelines.

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
