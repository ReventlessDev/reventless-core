# Change Log

All notable changes to this project will be documented in this file.
See [Conventional Commits](https://conventionalcommits.org) for commit guidelines.

# 1.0.0-alpha.6 (2026-04-09)

### Bug Fixes

* **ppx:** add -as-ppx flag to bin wrapper for OCaml 5.x ppxlib compatibility ([628fa80](https://github.com/ReventlessDev/reventless-core/commit/628fa8029a78882631bd28b08ac5fa62b937510c))
* **ppx:** rebuild Linux binary with OCaml 5.2 to match ReScript 12.2 PPX protocol ([c566399](https://github.com/ReventlessDev/reventless-core/commit/c56639926d434566df62b112a02c3c528cb7a9f2))
* **ppx:** stop install.cjs from overwriting bin shell wrapper on Linux/macOS ([34023e1](https://github.com/ReventlessDev/reventless-core/commit/34023e1d31969d6f569b7baf536bd283e88bcbb3))
### Features

* **ppx:** implement [@no](https://github.com/no)Api to exclude commands from GraphQL/MCP exposure ([079b686](https://github.com/ReventlessDev/reventless-core/commit/079b68693976a53f8094f1233ebf8b67a86a65c0))


# 1.0.0-alpha.5 (2026-04-07)

### Features

* **ppx+querydb:** annotation-driven key design and sort key queries ([dee6de8](https://github.com/ReventlessDev/reventless-core/commit/dee6de84c2d2de5431d064f18ac7132bc8c23110))
* **ppx:** auto-inject open Reventless.Projection for StateViewSlice files ([ad15b25](https://github.com/ReventlessDev/reventless-core/commit/ad15b253f2645ff2fa790d557734c3ccacb33936))


# 1.0.0-alpha.4 (2026-04-06)

### Bug Fixes

* **ppx:** only strip top-level suffixes outside slice folders ([c87da58](https://github.com/ReventlessDev/reventless-core/commit/c87da580dac03fb279cd34f68cc87f19b44752e2))
* **ppx:** preserve full entity name for files in slice folders ([5471b3f](https://github.com/ReventlessDev/reventless-core/commit/5471b3f2a64e5dbc85441ae22bfa53c194f84689))
* **ppx:** restore bin as platform-dispatching shell wrapper ([be8defd](https://github.com/ReventlessDev/reventless-core/commit/be8defdeab835f157da3e4f69ebcb5eb34b211fc))


# 1.0.0-alpha.3 (2026-04-06)

### Features

* implement [@composite](https://github.com/composite)PartitionTag PPX annotation for multi-field DCB partition keys ([cf26b15](https://github.com/ReventlessDev/reventless-core/commit/cf26b15f639d151451c9aa04d32603ef9d5df315))


# 1.0.0-alpha.2 (2026-04-04)

### Bug Fixes

* **ci:** resolve PPX "Exec format error" on Linux ([0f2e014](https://github.com/ReventlessDev/reventless-core/commit/0f2e014929eaee522ac270ca8d3797fe6efe2db7))
* DCB [@partition](https://github.com/partition)Tag runtime errors, GraphQL Node interface, and ESM config ([dc4c4e1](https://github.com/ReventlessDev/reventless-core/commit/dc4c4e10f1ef09aba840e7b359df453b122c6aa4))
* **ppx:** add prebuilt Linux x64 binary ([8fb4dfc](https://github.com/ReventlessDev/reventless-core/commit/8fb4dfcb72a47fa01cfe175c14bef36fafe3130a))
* **ppx:** replace bin with platform-dispatching shell wrapper ([90ca700](https://github.com/ReventlessDev/reventless-core/commit/90ca700dcd63d139d590724f9f5cdba104529793))
* feat!: add reventless-ppx with @@reventless.spec, @@reventless.behavior, @@reventless.dcbTags ([cb203ec](https://github.com/ReventlessDev/reventless-core/commit/cb203ece5ea3a1b92ba7d1a57d9e12bb6c4c2487))
### Features

* reventless-ppx — [@partition](https://github.com/partition)Tag, [@no](https://github.com/no)Tag, [@dcb](https://github.com/dcb)Tag field annotations ([64646b8](https://github.com/ReventlessDev/reventless-core/commit/64646b8813ba8c55febb3383bc40a78c5b09147e))

### BREAKING CHANGES

* Example spec files no longer export manual moduleUrl/name/Id
declarations — these are now PPX-generated. Downstream code referencing these
exports is unaffected (same values, different source).
