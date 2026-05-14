# Change Log

All notable changes to this project will be documented in this file.
See [Conventional Commits](https://conventionalcommits.org) for commit guidelines.

# 1.0.0-alpha.15 (2026-05-14)

### Features

* **ppx:** @[@reventless](https://github.com/reventless).authorize file-level annotation + auto-inject defaults ([dd188ee](https://github.com/ReventlessDev/reventless-core/commit/dd188ee86999fbb8f47d4badec5e21894c982171))
* **ppx:** inline-spec walk + Spec module types require authorization ([7db9ec0](https://github.com/ReventlessDev/reventless-core/commit/7db9ec0f186578ce0088973dba22da9257be6a61))
* **ppx:** per-constructor [@authorize](https://github.com/authorize) annotation → switch lambda ([f5cd3bf](https://github.com/ReventlessDev/reventless-core/commit/f5cd3bf0676d087ca02607f5b2fedd420f10cf8d))


# 1.0.0-alpha.14 (2026-05-05)

### Features

* **dcb:** allow plural *Ids field names with shared singular tag key ([19a5167](https://github.com/ReventlessDev/reventless-core/commit/19a5167ed904c6152c137af738f869ee4d26287e))


# 1.0.0-alpha.13 (2026-05-03)

* feat(ppx,codegen)!: retire @reventless.projections; add spec-stem-uniqueness lint ([a6fa11f](https://github.com/ReventlessDev/reventless-core/commit/a6fa11fa26086fd356e16b01b6f15b819630534e))
* refactor(examples)!: migrate online-shop-aggregates to new naming + adopt new PPX ([9dac635](https://github.com/ReventlessDev/reventless-core/commit/9dac6353b88e6c6bba88d1ce9d4a0594be976f62))
* feat(ppx)!: add @@reventless.mappings/extension/task; collapse AutomationSlice.Make to 2 args ([c0268ac](https://github.com/ReventlessDev/reventless-core/commit/c0268ac42c1c887fe25467af61b412ab2e27a5a7))
### Features

* **ppx,examples:** full GWT coverage for example plugins ([9331744](https://github.com/ReventlessDev/reventless-core/commit/9331744d232802d996f3897d7eca6e8c6b735f68))

### BREAKING CHANGES

* any user code applying @reventless.projections to
an inline wrapper module inside Plugin.res fails to compile with a
clear migration message. Move the per-source Mapping.Make modules
and the let mappings array into the slice-local
<Plural>_Projections.res file (in ReadModel/) and add
@@reventless.mappings at the top. Auto-generated Plugin.res then
references the projections module directly.
* external code consuming the
`@reventlessdev/online-shop-aggregates-*` packages must update module name
references (e.g., `CategoriesReadModel` → `Categories`,
`ProductsExtensionPoint` → `Products_ExtensionPoint`, `CategoryBehavior` →
`Category_Behavior`).

Verified: zero warnings, 1174/1175 tests pass — same single pre-existing
testPromise race in OrderingE2ETest as PR1/PR2.
* Platform.AutomationSlice.Make is now 2-arg (Spec, Automation).
External callers must either rerun generate-plugin or merge their _Mappings
contents into _Automation (or add the same two-line bridge).

Verified: zero warnings, 1174/1175 tests pass — the single failing test
(OrderingE2ETest "after syncing missing product, PlaceOrder succeeds") was
confirmed pre-existing on alpha (the known testPromise concurrency race).



# 1.0.0-alpha.12 (2026-04-28)

### Features

* **ppx:** add [@drill](https://github.com/drill)Target and [@collapsed](https://github.com/collapsed) rendering hints ([9de6499](https://github.com/ReventlessDev/reventless-core/commit/9de6499a458a1a29f51f67df03b607bdb46c707c))
* **ppx:** add [@hidden](https://github.com/hidden) and [@summary](https://github.com/summary) visibility annotations ([f26b05c](https://github.com/ReventlessDev/reventless-core/commit/f26b05cd561f1a879ed74135a3446f1faf29ad21))
* **ppx:** add [@scan](https://github.com/scan) and [@scan](https://github.com/scan)Sort opt-in for server-side filter/sort ([534a4bf](https://github.com/ReventlessDev/reventless-core/commit/534a4bf2116ec6f597f87dadc785767c3dc54ace))
* **ppx:** propagate state annotations to JSON Schema as x-reventless-* properties ([5ce39e4](https://github.com/ReventlessDev/reventless-core/commit/5ce39e4d22dca7d5ae3577b6210e40dd81cef4f5))


# 1.0.0-alpha.11 (2026-04-26)

* feat(gwt)!: rename slice GWT DSLs to short kind names ([4b2e457](https://github.com/ReventlessDev/reventless-core/commit/4b2e45743a777aa85898763db0c5042443b31c97))
### Features

* **ppx:** add @[@reventless](https://github.com/reventless).projection / .automation / .translation — Phase 3a of Spec-First series ([d193ae6](https://github.com/ReventlessDev/reventless-core/commit/d193ae64cff93aae2867182641489f17ce4e88d6))

### BREAKING CHANGES

* AutomationSlice_GWT, InboundTranslationSlice_GWT, and
OutboundTranslationSlice_GWT are renamed without deprecation shims.
Update explicit include ReventlessGwt.<Old>.Make(...) lines to the new
short names.



# 1.0.0-alpha.10 (2026-04-24)

### Features

* **ppx:** auto-open companion `<Stem>_Fixtures` in @[@reventless](https://github.com/reventless).gwt ([c429e43](https://github.com/ReventlessDev/reventless-core/commit/c429e43383360968cb70cd2c73316445d33c8bcc))
* **ppx:** infer external Spec from path in @[@reventless](https://github.com/reventless).gwt ([54735d1](https://github.com/ReventlessDev/reventless-core/commit/54735d1727932f3dff249a551d40b9861f3996ed))


# 1.0.0-alpha.9 (2026-04-24)

### Features

* **gwt:** add @[@reventless](https://github.com/reventless).gwt PPX annotation (Stage 9) ([f6c3a65](https://github.com/ReventlessDev/reventless-core/commit/f6c3a65e0906b4fa09688c3c9907245701dca3da))


# 1.0.0-alpha.8 (2026-04-22)

### Bug Fixes

* **ci:** remove -as-ppx flag from Linux ppx invocation ([b9c2cca](https://github.com/ReventlessDev/reventless-core/commit/b9c2cca71f5673c7d38e02c3154269635fe7f6f8))
### Features

* add [@ref](https://github.com/ref) ppx annotation for explicit cross-entity field references ([079c732](https://github.com/ReventlessDev/reventless-core/commit/079c732e81b481e9b2836ea755e1610b13f828fc))
* add composite [@display](https://github.com/display)Name annotation with projected displayName column ([115f550](https://github.com/ReventlessDev/reventless-core/commit/115f5506231f635e261d977da0ca32bdabef817f))


# 1.0.0-alpha.7 (2026-04-09)

### Bug Fixes

* **ppx:** add -as-ppx for Linux binaries and fix Dockerfile to use bin.exe ([6016b82](https://github.com/ReventlessDev/reventless-core/commit/6016b82f5e9b79690202b36992cffb6c6ff7331e))
* **ppx:** remove erroneous -as-ppx flag from bin wrapper ([6457895](https://github.com/ReventlessDev/reventless-core/commit/64578959808781d54ab6728f052bb470c47cad1e))


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
