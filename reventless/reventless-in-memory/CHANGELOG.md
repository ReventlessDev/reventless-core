# Change Log

All notable changes to this project will be documented in this file.
See [Conventional Commits](https://conventionalcommits.org) for commit guidelines.

# 3.0.0-alpha.84 (2026-06-04)

**Note:** Version bump only for package @reventlessdev/reventless-in-memory





# 3.0.0-alpha.83 (2026-06-04)

**Note:** Version bump only for package @reventlessdev/reventless-in-memory





# 3.0.0-alpha.82 (2026-06-04)

### Features

* **core:** richer command/state logging and working LOG_LEVEL control ([284e562](https://github.com/ReventlessDev/reventless-core/commit/284e56217b90e29c42421926e507258332f11e11))


# 3.0.0-alpha.81 (2026-06-04)

**Note:** Version bump only for package @reventlessdev/reventless-in-memory





# 3.0.0-alpha.80 (2026-05-28)

**Note:** Version bump only for package @reventlessdev/reventless-in-memory





# 3.0.0-alpha.79 (2026-05-28)

**Note:** Version bump only for package @reventlessdev/reventless-in-memory





# 3.0.0-alpha.78 (2026-05-27)

### Bug Fixes

* **framework:** wire plugin ExtensionPoints into EventCollector runtime context ([2ce8dff](https://github.com/ReventlessDev/reventless-core/commit/2ce8dff426b576811a28c012934d77ecba8a33c0))


# 3.0.0-alpha.77 (2026-05-27)

**Note:** Version bump only for package @reventlessdev/reventless-in-memory





# 3.0.0-alpha.76 (2026-05-27)

**Note:** Version bump only for package @reventlessdev/reventless-in-memory





# 3.0.0-alpha.75 (2026-05-27)

**Note:** Version bump only for package @reventlessdev/reventless-in-memory





# 3.0.0-alpha.74 (2026-05-26)

**Note:** Version bump only for package @reventlessdev/reventless-in-memory





# 3.0.0-alpha.73 (2026-05-26)

**Note:** Version bump only for package @reventlessdev/reventless-in-memory





# 3.0.0-alpha.72 (2026-05-25)

**Note:** Version bump only for package @reventlessdev/reventless-in-memory





# 3.0.0-alpha.71 (2026-05-25)

**Note:** Version bump only for package @reventlessdev/reventless-in-memory





# 3.0.0-alpha.70 (2026-05-25)

### Features

* **readmodel:** add ReadModelStream variant for live-updating read models ([3d816fb](https://github.com/ReventlessDev/reventless-core/commit/3d816fb50e0e66693ae4a0a626f4d5b4e496c3b1))


# 3.0.0-alpha.69 (2026-05-21)

**Note:** Version bump only for package @reventlessdev/reventless-in-memory





# 3.0.0-alpha.68 (2026-05-21)

**Note:** Version bump only for package @reventlessdev/reventless-in-memory





# 3.0.0-alpha.67 (2026-05-21)

* feat(admin)!: replace direct DynamoDB retire write with Retire/Retired event flow ([7f5f018](https://github.com/ReventlessDev/reventless-core/commit/7f5f018e714e247331d143c304c0d671c2ac7c84))

### BREAKING CHANGES

* Platform.deployPlugin no longer accepts ~version. Generated
Main.res files are regenerated; any direct caller must drop the arg.



# 3.0.0-alpha.66 (2026-05-20)

### Bug Fixes

* **admin:** name the platform Plugins read model in the plural ([afa11a8](https://github.com/ReventlessDev/reventless-core/commit/afa11a8b7314bad5681006c93aa44196eb7c122f))


# 3.0.0-alpha.65 (2026-05-20)

**Note:** Version bump only for package @reventlessdev/reventless-in-memory





# 3.0.0-alpha.64 (2026-05-20)

### Features

* **plugin:** wire dcbEventLog into pluginDefinition for cross-plugin DCB routing (Phase 4) ([07b78f3](https://github.com/ReventlessDev/reventless-core/commit/07b78f359f8f039992ec0ce7922085b165695537))


# 3.0.0-alpha.63 (2026-05-19)

**Note:** Version bump only for package @reventlessdev/reventless-in-memory





# 3.0.0-alpha.62 (2026-05-19)

**Note:** Version bump only for package @reventlessdev/reventless-in-memory





# 3.0.0-alpha.61 (2026-05-19)

### Features

* **api:** batched-by-ids query field for single-key projections ([d5d836d](https://github.com/ReventlessDev/reventless-core/commit/d5d836de52a478fb096965d7c83882d6ef302508))
* **in-memory:** publish change descriptors to match AWS StateTopic output ([d182986](https://github.com/ReventlessDev/reventless-core/commit/d182986d1452ca13fdcee7d3d53d6683065f9346))


# 3.0.0-alpha.60 (2026-05-19)

### Bug Fixes

* **aws:** emit __typename in CommandResult mutation response ([aa05fb5](https://github.com/ReventlessDev/reventless-core/commit/aa05fb54e25fd7232b46ec9150bdd3a0c93080a8))
### Features

* **api:** emit CommandResult! for aggregate-derived mutations ([5d0afb2](https://github.com/ReventlessDev/reventless-core/commit/5d0afb2e8c889a3ce20c37d66807f65b7196a6ff))
* **platform:** commandHandlerConfig for per-flavor Lambda tuning ([4154061](https://github.com/ReventlessDev/reventless-core/commit/4154061d9343f90ce61955992d9119d0f7a251e1))


# 3.0.0-alpha.59 (2026-05-18)

**Note:** Version bump only for package @reventlessdev/reventless-in-memory





# 3.0.0-alpha.58 (2026-05-18)

### Features

* **plugin:** wire end-to-end user-extension dispatch through plugin EventCollectors ([f616abe](https://github.com/ReventlessDev/reventless-core/commit/f616abe169289f836f8e538b5419cb82cda886d7))


# 3.0.0-alpha.57 (2026-05-17)

**Note:** Version bump only for package @reventlessdev/reventless-in-memory





# 3.0.0-alpha.56 (2026-05-17)

### Bug Fixes

* **deps:** pin sury-ppx to 11.0.0-alpha.2 to prevent prerelease drift ([c9d05fe](https://github.com/ReventlessDev/reventless-core/commit/c9d05fe5118a9c0442ca3e071f2606b3a139fc81))


# 3.0.0-alpha.55 (2026-05-17)

**Note:** Version bump only for package @reventlessdev/reventless-in-memory





# 3.0.0-alpha.54 (2026-05-17)

### Bug Fixes

* **deps:** pin sury to 11.0.0-alpha.4 to unblock Lambda Layer deploys ([643d925](https://github.com/ReventlessDev/reventless-core/commit/643d92527fa9d092da9bef8547591e39a4c609dd))


# 3.0.0-alpha.53 (2026-05-17)

### Features

* **admin:** strip plugin version at GraphQL boundary for UI-facing pluginIds ([a03f028](https://github.com/ReventlessDev/reventless-core/commit/a03f0283c020b38fae26bbef1fb702fa928af95b))


# 3.0.0-alpha.52 (2026-05-17)

**Note:** Version bump only for package @reventlessdev/reventless-in-memory





# 3.0.0-alpha.51 (2026-05-16)

**Note:** Version bump only for package @reventlessdev/reventless-in-memory





# 3.0.0-alpha.50 (2026-05-16)

### Bug Fixes

* **in-memory:** back PlatformEventGraph with seeded QueryDb so node.id resolves ([0ec207f](https://github.com/ReventlessDev/reventless-core/commit/0ec207f4f280573d0c2f3f7205ebfac8fe36af74))
### Features

* **ppx:** add @[@reventless](https://github.com/reventless).visibility to hide components from AutoUI ([bd302cf](https://github.com/ReventlessDev/reventless-core/commit/bd302cfc5bd5d4dfe50c8e1bf8596ab67e36c74e))


# 3.0.0-alpha.49 (2026-05-16)

**Note:** Version bump only for package @reventlessdev/reventless-in-memory





# 3.0.0-alpha.48 (2026-05-16)

### Bug Fixes

* **api:** match admin command variants by name not position ([8aabea3](https://github.com/ReventlessDev/reventless-core/commit/8aabea3704879b63b69ee184cf8fdd85cf0a1e55))
* **core:** restore payload-less filter for event-schema extraction ([664d88f](https://github.com/ReventlessDev/reventless-core/commit/664d88f24f19f967f9680694d947f766bd4bc263))
* **in-memory:** Plugin Activate emits Disconnected → Connected to mirror AWS ([966525c](https://github.com/ReventlessDev/reventless-core/commit/966525c5fa8338ea06c3e8acbc889b58a0e1a761))
* **ppx:** drop [@allowed](https://github.com/allowed)States witness; spec.status as option<string> ([cc0eed0](https://github.com/ReventlessDev/reventless-core/commit/cc0eed0e499c70009603619dd9f23a6bb2dd35df))
### Features

* add onPluginStatusChange subscription contract + in-memory emit ([1859dae](https://github.com/ReventlessDev/reventless-core/commit/1859daefec3e74ad4e0a87c11cc45b32f99f6962))
* **admin:** expose built-in Platform admin plugin in host shell Auto UI ([e9a8cb2](https://github.com/ReventlessDev/reventless-core/commit/e9a8cb20efb958e582738720ddb5812bdf950876))
* complete plugin status gate on both adapters with tiered error codes ([2a8309b](https://github.com/ReventlessDev/reventless-core/commit/2a8309bbf324b276dbcede1be85a5f90dedd82eb))
* **in-memory:** enforce admin group on Platform_* queries + mutations ([ac08b27](https://github.com/ReventlessDev/reventless-core/commit/ac08b2708c5e438f34b44c4bc75bcd2b44204661))
* **in-memory:** graphql-ws subscription transport on yoga server ([72ab80d](https://github.com/ReventlessDev/reventless-core/commit/72ab80da6bf6710895db89b2e6d3c8af314a2457))
* **in-memory:** pin token secret via REVENTLESS_INMEMORY_TOKEN_SECRET ([ebe13fb](https://github.com/ReventlessDev/reventless-core/commit/ebe13fb4c40018dc301732e42e4f673dc82880d6))
* wire admin Plugin aggregate through standard auto-resolver flow ([73a58d3](https://github.com/ReventlessDev/reventless-core/commit/73a58d3b93922989a51bc15724dd92baa15b7037))


# 3.0.0-alpha.47 (2026-05-14)

### Bug Fixes

* **admin:** drop UIFragments auto-query, keep flat Platform_UIFragments ([b615481](https://github.com/ReventlessDev/reventless-core/commit/b61548148cc998b65c696607022c5fa01935e491))
* **in-memory:** return 401 on invalid Bearer token ([be03111](https://github.com/ReventlessDev/reventless-core/commit/be031118063abded740a7a10dd3c80cbd9f31d6d))
### Features

* **admin:** add Platform_UIFragments GraphQL query ([cf1ae27](https://github.com/ReventlessDev/reventless-core/commit/cf1ae27d19bf396dfa71c2539fd59874c9118ca0))
* **auth:** enforce per-spec authorization at in-memory resolvers ([32c6552](https://github.com/ReventlessDev/reventless-core/commit/32c65522cf4afb61c7c56f8828a95af8db4a0ad4))
* **auth:** expose payload-less commands to GraphQL + per-constructor authz test ([7a55b27](https://github.com/ReventlessDev/reventless-core/commit/7a55b27ea04e84368909b24fc5ca29f415d108da))
* **auth:** in-memory Auth provider + graphql-yoga context factory ([fe70052](https://github.com/ReventlessDev/reventless-core/commit/fe7005204d7a4328b25e9371b3d342a7000be570))
* **auth:** Stage A4 — Login token issuance + YAML user store + HTTP endpoints ([fa7bbb5](https://github.com/ReventlessDev/reventless-core/commit/fa7bbb573efca52b0c6617dbb3313fd3d755bd84))
* **auth:** Stage C — Cognito UserPool provisioning + A4 hydration fixup ([08d98e0](https://github.com/ReventlessDev/reventless-core/commit/08d98e00fc18de019190d7e6e977b09375d8ff61))
* **platform-aws:** host the static host-shell SPA on the platform CDN ([529ae4f](https://github.com/ReventlessDev/reventless-core/commit/529ae4f4b54675d43f22bb6180186e88d240b744))
* **ppx:** @[@reventless](https://github.com/reventless).authorize file-level annotation + auto-inject defaults ([dd188ee](https://github.com/ReventlessDev/reventless-core/commit/dd188ee86999fbb8f47d4badec5e21894c982171))
* **ppx:** inline-spec walk + Spec module types require authorization ([7db9ec0](https://github.com/ReventlessDev/reventless-core/commit/7db9ec0f186578ce0088973dba22da9257be6a61))


# 3.0.0-alpha.46 (2026-05-13)

* feat(spec)!: standardise event/command envelope (StoredEvent, optional meta, position, persisted DCB meta, causation) ([7ef3176](https://github.com/ReventlessDev/reventless-core/commit/7ef3176c6330810c817f43a52b881b5a0efee30e))

### BREAKING CHANGES

* meta.ip / meta.user go from required `string` to optional
record fields (`?: string`). Code that did `meta.user == "unknown"` to
detect system messages must check for field absence. Storage tables built
before this change are not migrated (greenfield — recreate the EventLog /
DcbEventLog tables; DynamoDB range key renamed from `seq` to `position`,
SQLite dcb_event gains meta and recorded_at columns).



# 3.0.0-alpha.45 (2026-05-10)

### Bug Fixes

* **aggregate:** propagate decide-errors as Rejected outcomes ([7eb1d59](https://github.com/ReventlessDev/reventless-core/commit/7eb1d599dd7d02791bffa915c19c40479ce6e9da))


# 3.0.0-alpha.44 (2026-05-05)

**Note:** Version bump only for package @reventlessdev/reventless-in-memory





# 3.0.0-alpha.43 (2026-05-04)

### Bug Fixes

* **aws:** drop empty Config functor args; thread per-spec metadata as direct params ([17837a3](https://github.com/ReventlessDev/reventless-core/commit/17837a3fde52581a06516c69c80e6a1ea5689d9a))
* **dcb:** derive envelope id from command partition tag in makeGenerateCommand ([bf44d9e](https://github.com/ReventlessDev/reventless-core/commit/bf44d9e2da877200075efb40f35013417f6b6200))


# 3.0.0-alpha.42 (2026-05-03)

### Bug Fixes

* **in-memory:** accept raw localIds in QueryDb filter.ids ([b1d113b](https://github.com/ReventlessDev/reventless-core/commit/b1d113b751d1a5958d867b47f0ddfcd0349e4558))
* **in-memory:** drop duplicate Platform_UIDefinitions SDL registration ([3bf7997](https://github.com/ReventlessDev/reventless-core/commit/3bf799755ebf3718e345e5d3b785af4ba3371773))


# 3.0.0-alpha.41 (2026-05-03)

### Features

* **aws:** mirror Platform_UIDefinitions GraphQL query — Lambda DataSource backed by Plugin read model ([76e57cc](https://github.com/ReventlessDev/reventless-core/commit/76e57ccc681a66be4909bd94e131145978169c9c))


# 3.0.0-alpha.40 (2026-05-03)

### Bug Fixes

* **in-memory:** mkdir SQLite parent directory on openDb ([2c90016](https://github.com/ReventlessDev/reventless-core/commit/2c90016ae7f208456d2328bad36a39e7aea90c39))
* feat(ppx)!: add @@reventless.mappings/extension/task; collapse AutomationSlice.Make to 2 args ([c0268ac](https://github.com/ReventlessDev/reventless-core/commit/c0268ac42c1c887fe25467af61b412ab2e27a5a7))
### Features

* **in-memory:** expose Platform_PlatformEventGraph[s] admin queries from pluginStructuresStore ([a1655cc](https://github.com/ReventlessDev/reventless-core/commit/a1655ccd65d86d5f52f9fef78b0a676f28f29a33))

### BREAKING CHANGES

* Platform.AutomationSlice.Make is now 2-arg (Spec, Automation).
External callers must either rerun generate-plugin or merge their _Mappings
contents into _Automation (or add the same two-line bridge).

Verified: zero warnings, 1174/1175 tests pass — the single failing test
(OrderingE2ETest "after syncing missing product, PlaceOrder succeeds") was
confirmed pre-existing on alpha (the known testPromise concurrency race).



# 3.0.0-alpha.39 (2026-04-28)

### Features

* **api:** auto-derive Filter/OrderBy from state annotations ([320001f](https://github.com/ReventlessDev/reventless-core/commit/320001f69dfc1166974932014dcf85f872aaba62))
* **aws:** server-side filter/sort on connection list resolver ([baa3f4e](https://github.com/ReventlessDev/reventless-core/commit/baa3f4e7937ff14d8e6ad2b309dbae57a242cf47))
* **in-memory:** keyset pagination on connection list resolver ([6750cc6](https://github.com/ReventlessDev/reventless-core/commit/6750cc628a33517338125d15c8e7bbb27123cf38))
* **in-memory:** log active storage backend on platform startup ([deff1b8](https://github.com/ReventlessDev/reventless-core/commit/deff1b89b6e7c737cfaddc8b53ff35dd3899e4e2))
* **ppx:** add [@scan](https://github.com/scan) and [@scan](https://github.com/scan)Sort opt-in for server-side filter/sort ([534a4bf](https://github.com/ReventlessDev/reventless-core/commit/534a4bf2116ec6f597f87dadc785767c3dc54ace))


# 3.0.0-alpha.38 (2026-04-27)

### Bug Fixes

* **in-memory:** resolve extension wirings via Output chain and use firePlatformDeployedHook ([3037fc7](https://github.com/ReventlessDev/reventless-core/commit/3037fc7af05574163873eefdb227b5421118c323))


# 3.0.0-alpha.37 (2026-04-26)

* refactor(automation)!: drop tagSet and toTags from Mapping API ([c9cd7f2](https://github.com/ReventlessDev/reventless-core/commit/c9cd7f2a1c1758990cb3d83a6876348477fe89d6))
* feat!: mixed-source AutomationSlice — Plan 04 ([fae3fbf](https://github.com/ReventlessDev/reventless-core/commit/fae3fbf93b12ecf62d0883fe7335ed73c6f52d67))
### Features

* **core:** convert slice builders to two-arg (Spec, Impl) form — Phase 2 of Spec-First series ([4c994f3](https://github.com/ReventlessDev/reventless-core/commit/4c994f3d62003da26f5fc6a5b2a9fc9264dc241e))
* enable mixed-source ReadModel — Aggregate + DCB projections (Plan 03) ([2a5f9de](https://github.com/ReventlessDev/reventless-core/commit/2a5f9de1df23cac39fc292dbad23cf16ad0aece4))
* **spec:** split slice spec module types — Phase 1 of Spec-First series ([d3b1493](https://github.com/ReventlessDev/reventless-core/commit/d3b149300d09dbac45a5e316343cd79fe2a769e6))

### BREAKING CHANGES

* Mapping/MappingImpl no longer have `type tagSet`
or `let toTags`. Mappings declared in user code with `type tagSet`
or `let toTags` need those lines removed. Migrate any toTags
validation logic to `collect` (filter) or to `@s.matches` /
`@compositePartitionTag` annotations on the command schema.
* AutomationSlice.Spec drops consumedEvent;
AutomationSlice_Builder.Make takes Mappings as 3rd arg; make signature
swaps ~dcbEventLog for ~allEventTopics + ~context; Plugin_Builder.Spec
gains platformName. Existing slices need a sibling _Mappings.res file
and updated Plugin.res (regenerate via prebuild hook).

Tests: 362/362 pass. Build clean, zero warnings.

Plan: docs/plans/done/mixed-source-automationslice.md
Guide: docs/guides/mixed-source-automationslice.md



# 3.0.0-alpha.36 (2026-04-24)

**Note:** Version bump only for package @reventlessdev/reventless-in-memory





# 3.0.0-alpha.35 (2026-04-24)

### Bug Fixes

* **in-memory:** polyfill globalThis.crypto for uuid@13 in Jest 27 ([63e5cee](https://github.com/ReventlessDev/reventless-core/commit/63e5cee55ec3efda681351c8bf4bb259053f9684))
### Features

* **admin:** convert PlatformEventGraph from StateViewSlice to ReadModel ([df5746b](https://github.com/ReventlessDev/reventless-core/commit/df5746bbb419833361c2fb47ed607e2ab85ced47))
* **gwt:** add 5 DCB slice DSLs and thread slice name into hints (Stage 3) ([62b59fd](https://github.com/ReventlessDev/reventless-core/commit/62b59fdaa745d7799209ec3c24c50a8d443670b5))
* **gwt:** add Stage 4 AppendConditionMismatch + Stage 5 Mapping_GWT ([24fa835](https://github.com/ReventlessDev/reventless-core/commit/24fa8353657329e73a04cfed8e0a390806ff3395))
* **gwt:** extract GWT test DSLs into @reventlessdev/reventless-gwt package ([dd64b4e](https://github.com/ReventlessDev/reventless-core/commit/dd64b4e1fd0bb203821d055b6743a52aec1836fb))
* **in-memory:** add opt-in SQLite persistence backend ([1a74301](https://github.com/ReventlessDev/reventless-core/commit/1a7430191c8fb83b3eac066e488585af3f330bbf))


# 3.0.0-alpha.34 (2026-04-22)

### Bug Fixes

* register platformCrossPluginEdges in makePlatform before startServers ([d503158](https://github.com/ReventlessDev/reventless-core/commit/d50315824baeb16afc46790485daa0a3d09dcf01))
### Features

* add [@ref](https://github.com/ref) ppx annotation for explicit cross-entity field references ([079c732](https://github.com/ReventlessDev/reventless-core/commit/079c732e81b481e9b2836ea755e1610b13f828fc))
* **build:** migrate from npm to pnpm (hoisted layout) ([1de8b77](https://github.com/ReventlessDev/reventless-core/commit/1de8b7753b8f45c63ea3c8d9f64de2f27febd029))
* expose sourceNames on ReadModel.T for aggregate-to-read-model linking ([379f344](https://github.com/ReventlessDev/reventless-core/commit/379f3445cfd5d18b5d439dd9c6f3bd7d86bdc3d5))
* **spec:** add Message.variantNameOfJson helper ([a9efb5f](https://github.com/ReventlessDev/reventless-core/commit/a9efb5f1d3ac6180ea8e04dc3c1c2f183d15a984))
* surface labelField and searchableFields on Platform_UIReadSideDef ([fb7bff8](https://github.com/ReventlessDev/reventless-core/commit/fb7bff8f6fca51c2ed9261adbfedec0f45777d59))


# 3.0.0-alpha.33 (2026-04-20)

### Features

* add automationSlices, translation slices, and extensions to pluginStructure ([631e2f3](https://github.com/ReventlessDev/reventless-core/commit/631e2f3636f0a422e58712f70106c0df8effc1e9))
* cross-plugin edge assembly for Platform_EventGraph via query-time resolver ([6a2ba2b](https://github.com/ReventlessDev/reventless-core/commit/6a2ba2bccd7207dfccb81aec4b2c90e43c866f4d))
* expose level, aggregateIdField, linkedViews and consistencyRead in Platform_UIDefinitions GQL ([62092f6](https://github.com/ReventlessDev/reventless-core/commit/62092f6a803acb83c0d0afc378892bd33e8cd8e5))
* Platform_EventGraph StateViewSlice aggregating cross-plugin event graph ([718f0be](https://github.com/ReventlessDev/reventless-core/commit/718f0bed258da62c4ff5f2ab188e2d43b85e91b6))
* **plugin-structure:** add mutationField to commandDef ([80f2c8d](https://github.com/ReventlessDev/reventless-core/commit/80f2c8db6a61a705f8b05cb7429187a4b69ccf37))


# 3.0.0-alpha.32 (2026-04-19)

### Bug Fixes

* **tests:** update SplitApiTest fixtures for UIFragment query/mutation entries ([16577c0](https://github.com/ReventlessDev/reventless-core/commit/16577c0b26072a9743c1ee1a6118f6b69c114434))


# 3.0.0-alpha.31 (2026-04-18)

### Features

* **core:** AutoUI definition — makeAutoUIDefinition, Platform_UIDefinitions query, generator support ([513ca53](https://github.com/ReventlessDev/reventless-core/commit/513ca5399b0b6e5ae6a982fd15693de2ea208b8d))
* **core:** UI fragment registry — Phases 2–4 (lifecycle events, read model, subscription) ([ad62d0e](https://github.com/ReventlessDev/reventless-core/commit/ad62d0e1ae820f8fe4c2066b59db5363e6ca33a1))
* **core:** uiFragments manifest — Phase 1 implementation with generic types ([1e73f62](https://github.com/ReventlessDev/reventless-core/commit/1e73f623984118081d2b985c48521812e4f8417e))


# 3.0.0-alpha.30 (2026-04-18)

### Features

* **aws:** enable Source B state-change subscriptions (DynamoDB Stream → AppSync Events) ([960b203](https://github.com/ReventlessDev/reventless-core/commit/960b2035d843c2b97cf2014b05fb1a4f132e9984))


# 3.0.0-alpha.29 (2026-04-16)

### Bug Fixes

* **graphql:** emit input types for nested mutation args; pass dataSourceName on subs ([9dc7107](https://github.com/ReventlessDev/reventless-core/commit/9dc7107328327470396cfe6e1e775846fee98992))


# 3.0.0-alpha.28 (2026-04-16)

### Features

* **plugin-hooks:** implement Groups A-E of plugin-hook-metadata-and-schema-extensions ([4e95782](https://github.com/ReventlessDev/reventless-core/commit/4e957824d31666643a357873cba0403d52dd80b4))
* **subscriptions:** implement GraphQL subscriptions across AWS + in-memory ([a25a3b8](https://github.com/ReventlessDev/reventless-core/commit/a25a3b8928a465b7ba8de7b06e44425e206a1fcd))


# 3.0.0-alpha.27 (2026-04-15)

### Bug Fixes

* **platform:** split-API schema routing for Platform-target plugins ([6b4c58d](https://github.com/ReventlessDev/reventless-core/commit/6b4c58dfed15c40db0e70339f0148ff445eb5c6a))


# 3.0.0-alpha.26 (2026-04-15)

### Bug Fixes

* make onPluginDeployedHook async so Pulumi blocks on hook Promise ([b79def0](https://github.com/ReventlessDev/reventless-core/commit/b79def025dae4542f8c5c63b84e1b68999511ff6))
### Features

* zero-touch plugin assembly — generate Plugin.res from folder structure ([73ea654](https://github.com/ReventlessDev/reventless-core/commit/73ea654ab9a73f15ea7e18631e8194bfe0f4580f))


# 3.0.0-alpha.25 (2026-04-13)

### Bug Fixes

* **in-memory:** fix GraphQL schema and resolver bugs in platform servers ([0376941](https://github.com/ReventlessDev/reventless-core/commit/0376941af84501ab9f0b63f1a673e6f510fe3886))


# 3.0.0-alpha.24 (2026-04-13)

### Bug Fixes

* **aws:** route slice builder resolvers to correct API target ([7485159](https://github.com/ReventlessDev/reventless-core/commit/7485159f415d4720dd4e567d2ffef1335db432e6))


# 3.0.0-alpha.23 (2026-04-12)

### Features

* **api:** replace ByIdConnection with Relay-compatible Items query ([1bb7a8d](https://github.com/ReventlessDev/reventless-core/commit/1bb7a8d9e10b2db76714c61f9418cc55fd7ec2ae))
* **commands:** end-to-end CommandResult — synchronous business-rule errors reach the GraphQL client ([c241d74](https://github.com/ReventlessDev/reventless-core/commit/c241d7418205799bdc79472ebbd04f40b392f870))
* **commands:** extend CommandAccepted with entityId and eventCount ([747b85d](https://github.com/ReventlessDev/reventless-core/commit/747b85dc50042124f360627c5489321eea0d26e4))
* **platform:** MakeAsync opt-in for aggregates and DCB slices ([6970d88](https://github.com/ReventlessDev/reventless-core/commit/6970d889fa05e738dbda5d8e450a1dcf927b23b7))
* **platform:** rename admin fields to Platform_ prefix, fix dual-API registration ([95f011a](https://github.com/ReventlessDev/reventless-core/commit/95f011a8617b78d5c876f8e14a3ba5e0595d1cee))
* **platform:** symmetric domain/platform server architecture (Phase 6) ([4bbc88d](https://github.com/ReventlessDev/reventless-core/commit/4bbc88d2dac3b0d3a6099008f3814d6aedf03e29))


# 3.0.0-alpha.22 (2026-04-11)

### Features

* **platform:** add apiTarget routing for deployPlugin (Phase 4a-4d) ([b9b2d75](https://github.com/ReventlessDev/reventless-core/commit/b9b2d754c2fb61854fc5bca8761a0d0acfb89009))


# 3.0.0-alpha.21 (2026-04-10)

### Features

* **aws:** implement dual-API architecture (Phases 1–3) ([9e11efc](https://github.com/ReventlessDev/reventless-core/commit/9e11efc21bb012552fbe1c1b510664d372f84b96))


# 3.0.0-alpha.20 (2026-04-09)

### Features

* **platform:** add apiEndpoint to platformDeployedInfo, extract Plugin_BuiltHook ([d53cfc5](https://github.com/ReventlessDev/reventless-core/commit/d53cfc5bd33671d2ca539b4eeb45bbaa7b3979e3))


# 3.0.0-alpha.19 (2026-04-09)

### Bug Fixes

* **in-memory:** register ByIdConnection type definition in GraphQL schema ([6b13fde](https://github.com/ReventlessDev/reventless-core/commit/6b13fde0abb5eb12cba5b28511dfc5193e35f7d8))


# 3.0.0-alpha.18 (2026-04-07)

### Bug Fixes

* **reventless-in-memory:** add rescript-mcp-sdk to package.json dependencies ([fbf7522](https://github.com/ReventlessDev/reventless-core/commit/fbf752254ecc8f11fb70c10387df3bdfa53a19ee))


# 3.0.0-alpha.17 (2026-04-07)

### Features

* **ppx+querydb:** annotation-driven key design and sort key queries ([dee6de8](https://github.com/ReventlessDev/reventless-core/commit/dee6de84c2d2de5431d064f18ac7132bc8c23110))


# 3.0.0-alpha.16 (2026-04-07)

### Bug Fixes

* **in-memory:** queue commands and receive calls that arrive before handlers bind ([4566da3](https://github.com/ReventlessDev/reventless-core/commit/4566da3bf756dca5ea151e0bdb7ef46999cd3090))


# 3.0.0-alpha.15 (2026-04-06)

### Bug Fixes

* add package-specs to all rescript.json to prevent CJS .js output ([780f1e0](https://github.com/ReventlessDev/reventless-core/commit/780f1e035173b73b17b78466ad01fb69c7cca350))


# 3.0.0-alpha.14 (2026-04-06)

### Features

* implement [@composite](https://github.com/composite)PartitionTag PPX annotation for multi-field DCB partition keys ([cf26b15](https://github.com/ReventlessDev/reventless-core/commit/cf26b15f639d151451c9aa04d32603ef9d5df315))


# 3.0.0-alpha.13 (2026-04-05)

### Bug Fixes

* DCB command pipeline runtime fixes ([9646c97](https://github.com/ReventlessDev/reventless-core/commit/9646c97e7fd86f28d5035d77ff40af66f592e61e))


# 3.0.0-alpha.12 (2026-04-04)

### Bug Fixes

* DCB [@partition](https://github.com/partition)Tag runtime errors, GraphQL Node interface, and ESM config ([dc4c4e1](https://github.com/ReventlessDev/reventless-core/commit/dc4c4e10f1ef09aba840e7b359df453b122c6aa4))
* feat!: add reventless-ppx with @@reventless.spec, @@reventless.behavior, @@reventless.dcbTags ([cb203ec](https://github.com/ReventlessDev/reventless-core/commit/cb203ece5ea3a1b92ba7d1a57d9e12bb6c4c2487))
* feat!: Extension Blueprint pattern with auto-merge and plugin naming ([0856d4d](https://github.com/ReventlessDev/reventless-core/commit/0856d4d2a23b8d5175fd091f90110d4c44927191))
### Features

* add Relay server compliance to GraphQL API ([bd9245d](https://github.com/ReventlessDev/reventless-core/commit/bd9245da87023247643c5fa37cee21b0cde0f61e))
* make Relay connection spec the default for all list queries ([fa8d258](https://github.com/ReventlessDev/reventless-core/commit/fa8d258ddeb30bf02f97b1c1f3cc564e15632e94))

### BREAKING CHANGES

* Example spec files no longer export manual moduleUrl/name/Id
declarations — these are now PPX-generated. Downstream code referencing these
exports is unaffected (same values, different source).
* Platform.Extension.Make returns Extension.Blueprint
instead of Extension.T. Plugin.make ~extensions param type changes
accordingly. Make2/Make3/MakeMulti removed from Platform.T.



# 3.0.0-alpha.11 (2026-04-03)

* feat!: support multi-command returns in InboundTranslationSlice ([eaac621](https://github.com/ReventlessDev/reventless-core/commit/eaac6213829b876db508b6a98db081ee40dc3e95))

### BREAKING CHANGES

* All `translate` implementations must wrap returns in arrays.



# 3.0.0-alpha.10 (2026-04-02)

### Features

* add tags field to resource and resolvedResource records ([18911e6](https://github.com/ReventlessDev/reventless-core/commit/18911e66aa94e60d4a9b72ba1d1ca84dd3fb1a9f))


# 3.0.0-alpha.9 (2026-04-02)

* feat!: add deploy lifecycle hooks, enrich resource metadata, and add Adapter.make factory ([0a171f4](https://github.com/ReventlessDev/reventless-core/commit/0a171f4b8aec0ee47fd7ee5069adf5d5b194548e))

### BREAKING CHANGES

* Adapter.resource.info replaced with resourceInfo variant type.
Service field values now prefixed with provider namespace (e.g. "aws:DynamoDb").
New required fields on resource/resolvedResource: role, region, resourceType, configuration.



# 3.0.0-alpha.8 (2026-03-31)

### Features

* return Plugin.outputs from deployPlugin ([22e59f7](https://github.com/ReventlessDev/reventless-core/commit/22e59f730c5c87dd0e3e8d4cf225d401298759f8))


# [3.0.0-alpha.7](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-in-memory@3.0.0-alpha.6...@reventlessdev/reventless-in-memory@3.0.0-alpha.7) (2026-03-30)

### Features

* unified logging with structured output, colored levels, and CloudWatch detail ([7754cf1](https://github.com/ReventlessDev/reventless-core/commit/7754cf11037b17fce01ab65c2c906d9faf7ac4b6))


# [3.0.0-alpha.6](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-in-memory@3.0.0-alpha.5...@reventlessdev/reventless-in-memory@3.0.0-alpha.6) (2026-03-29)

### Features

* add query interceptor hook to QueryDb pipeline ([40c7f7e](https://github.com/ReventlessDev/reventless-core/commit/40c7f7ea9bc004bfb58be8ab52136ddea9481083))


# [3.0.0-alpha.5](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-in-memory@3.0.0-alpha.3...@reventlessdev/reventless-in-memory@3.0.0-alpha.5) (2026-03-28)

* feat!: flatten DcbSpec module type into direct Plugin.make parameters ([1c0bc57](https://github.com/ReventlessDev/reventless-core/commit/1c0bc576fcd88b92510900c16f5f117e864d9d7f))
### Features

* add identity propagation and interceptor hook to CommandGenerator pipeline ([37494a5](https://github.com/ReventlessDev/reventless-core/commit/37494a50fe70f8db7d6d35fd733a4fc75eade5bc))

### BREAKING CHANGES

* Plugin.make no longer accepts ~dcbSpec=module(DcbSpec).
Pass slice arrays directly instead. Empty arrays can be omitted.



# [3.0.0-alpha.4](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-in-memory@3.0.0-alpha.3...@reventlessdev/reventless-in-memory@3.0.0-alpha.4) (2026-03-27)

* feat!: flatten DcbSpec module type into direct Plugin.make parameters ([1c0bc57](https://github.com/ReventlessDev/reventless-core/commit/1c0bc576fcd88b92510900c16f5f117e864d9d7f))

### BREAKING CHANGES

* Plugin.make no longer accepts ~dcbSpec=module(DcbSpec).
Pass slice arrays directly instead. Empty arrays can be omitted.



# [3.0.0-alpha.3](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-in-memory@1.0.0-alpha.15...@reventlessdev/reventless-in-memory@3.0.0-alpha.3) (2026-03-27)

### Bug Fixes

* conditionally exclude ID parameter from StateViewSlice GraphQL queries ([43de4b6](https://github.com/ReventlessDev/reventless-core/commit/43de4b667d89235ea03b3e1584070515e10e71de))
* feat!: remove resolverConfig from Behavior module type ([6f54015](https://github.com/ReventlessDev/reventless-core/commit/6f54015e3abc1c5c05472c8f54645723a0f5ed28))
* feat!: decouple DCB slices from shared event log union type ([2a40e8d](https://github.com/ReventlessDev/reventless-core/commit/2a40e8dd9babfb88440fcaccde6fb667b60e0ba9))
* feat!: add structured Identity type and expand RequestContext with identity and claims ([a2396d4](https://github.com/ReventlessDev/reventless-core/commit/a2396d4dd350bb07924d45b64b99b3dc969ced89))

### BREAKING CHANGES

* Behavior.T no longer requires resolverConfig. Remove it
from all Behavior implementations.
* All DCB slice specs must use `producedEvent`/`consumedEvent`
instead of `module DcbEventLogSpec`. Plugin `DcbSpec` no longer has `type event`
or `with type dcbEvent` constraints.
* RequestContext.t now requires identity and claims fields.
Use RequestContext.test() for test contexts.



# [3.0.0-alpha.2](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-in-memory@1.0.0-alpha.15...@reventlessdev/reventless-in-memory@3.0.0-alpha.2) (2026-03-26)

### Bug Fixes

* conditionally exclude ID parameter from StateViewSlice GraphQL queries ([43de4b6](https://github.com/ReventlessDev/reventless-core/commit/43de4b667d89235ea03b3e1584070515e10e71de))
* feat!: add structured Identity type and expand RequestContext with identity and claims ([a2396d4](https://github.com/ReventlessDev/reventless-core/commit/a2396d4dd350bb07924d45b64b99b3dc969ced89))

### BREAKING CHANGES

* RequestContext.t now requires identity and claims fields.
Use RequestContext.test() for test contexts.



# [1.0.0-alpha.16](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-in-memory@1.0.0-alpha.15...@reventlessdev/reventless-in-memory@1.0.0-alpha.16) (2026-03-26)

### Bug Fixes

* conditionally exclude ID parameter from StateViewSlice GraphQL queries ([43de4b6](https://github.com/ReventlessDev/reventless-core/commit/43de4b667d89235ea03b3e1584070515e10e71de))
* feat!: add structured Identity type and expand RequestContext with identity and claims ([a2396d4](https://github.com/ReventlessDev/reventless-core/commit/a2396d4dd350bb07924d45b64b99b3dc969ced89))

### BREAKING CHANGES

* RequestContext.t now requires identity and claims fields.
Use RequestContext.test() for test contexts.



# [1.0.0-alpha.15](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-in-memory@1.0.0-alpha.14...@reventlessdev/reventless-in-memory@1.0.0-alpha.15) (2026-03-23)

* refactor!: streamline component function naming to unified two-function pattern ([06814fd](https://github.com/ReventlessDev/reventless-core/commit/06814fd8589cf05ce8a9f9654552e7d5cd9c6bf2))
* fix(reventless-aws)!: fix DcbEventLog DynamoDB stream event decoding and normalize field names ([c83d38a](https://github.com/ReventlessDev/reventless-core/commit/c83d38abbeb225cf68fdc22a0210da46f249a558))
* fix(reventless-aws)!: resolve DcbEventLogSpec undefined at runtime and add AppSync routing ([85138a3](https://github.com/ReventlessDev/reventless-core/commit/85138a39afe97047ea5f063508994e20544eb780))

### BREAKING CHANGES

* All component function signatures changed. Behavior.decide
now returns result<array<event>, error> instead of using errorHandler callback.
StateChangeSlice type decisionModel renamed to state. Projection.Mapping.map
renamed to project. StateViewSlice.project takes one argument instead of two.

* DynamoDB attribute names changed. Existing event log tables require migration.

* DcbEventLog.Spec now requires `let moduleUrl: string` field.
Add `let moduleUrl: string = %raw(\`import.meta.url\`)` to event log modules.
# [1.0.0-alpha.14](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-in-memory@1.0.0-alpha.12...@reventlessdev/reventless-in-memory@1.0.0-alpha.14) (2026-03-22)

### Bug Fixes

* **rescript-effect:** use deep imports to avoid loading effect barrel ([1823358](https://github.com/ReventlessDev/reventless-core/commit/18233588d3564d8b4d158b949e734cbb92720fcd))
* feat(reventless-aws)!: replace esbuild pipeline with compiled ReScript entry points ([6cb3133](https://github.com/ReventlessDev/reventless-core/commit/6cb313323c73a078d0922fa6b977466f61de74ea))

### BREAKING CHANGES

* esbuild removed from dependencies, `makeBundled` and
`makeBundledFromEntryPoint` removed from RuntimeEnvironment_Lambda,
`BundledEnvironment` module type removed from Runtime.
# [1.0.0-alpha.13](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-in-memory@1.0.0-alpha.12...@reventlessdev/reventless-in-memory@1.0.0-alpha.13) (2026-03-21)

### Bug Fixes

* **rescript-effect:** use deep imports to avoid loading effect barrel ([1823358](https://github.com/ReventlessDev/reventless-core/commit/18233588d3564d8b4d158b949e734cbb92720fcd))
# [1.0.0-alpha.12](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-in-memory@1.0.0-alpha.11...@reventlessdev/reventless-in-memory@1.0.0-alpha.12) (2026-03-20)

### Features

* **aws:** expose api/apiRole in Platform.T and remove unused MakeBundled modules ([a3be4cc](https://github.com/ReventlessDev/reventless-core/commit/a3be4cc5dc6041fb70c8e44a9e48f0a4f730242a))
# [1.0.0-alpha.11](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-in-memory@1.0.0-alpha.10...@reventlessdev/reventless-in-memory@1.0.0-alpha.11) (2026-03-17)

### Bug Fixes

* **reventless-in-memory:** implement admin Activate/Deactivate mutations ([b36948f](https://github.com/ReventlessDev/reventless-core/commit/b36948fc18d272f79271f42f234de7e1460c916b))
### Features

* **reventless-aws:** implement per-plugin deployment with runtime schema stitching ([f16714c](https://github.com/ReventlessDev/reventless-core/commit/f16714c5d2b3ad869863ac30dc55ef3e1570bf4f))
# [1.0.0-alpha.10](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-in-memory@1.0.0-alpha.9...@reventlessdev/reventless-in-memory@1.0.0-alpha.10) (2026-03-16)

* feat!: unify DCB and Aggregate command generation paths ([8c9bbad](https://github.com/ReventlessDev/reventless-core/commit/8c9bbad14082e7b696da35f5abb337520b1c8683))
* feat!: replace Core component with Platform_Admin, rename schema prefix Core_ → Admin_ ([940263d](https://github.com/ReventlessDev/reventless-core/commit/940263d8b39e28f4c874af3b0335ae81444928c4))
### Features

* differentiate ReadModel and StateViewSlice GraphQL query schemas ([62f6130](https://github.com/ReventlessDev/reventless-core/commit/62f6130d2ee34d65fe3eab1395d55c77c0309ddb))
* internalize scheduler, Core, and setup in Platform.makePlatform ([ce3e1b6](https://github.com/ReventlessDev/reventless-core/commit/ce3e1b60e8ffdbab1a6b5cd08d73f5e907726481))
* read version from package.json, make cloner opt-in, log platform version ([d8216a1](https://github.com/ReventlessDev/reventless-core/commit/d8216a1d569064ca14eff6e0c3be86923e5b84ad))

### BREAKING CHANGES

* DCB mutation return value changes from "ok" to a UUID.

* GraphQL/MCP field names change from Core_ to Admin_
prefix (e.g. Core_Plugin → Admin_Plugin). makePlatform no longer accepts
~extensionPoints, ~aggregates, ~readModels, ~dcbSpec parameters.
# [1.0.0-alpha.9](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-in-memory@1.0.0-alpha.8...@reventlessdev/reventless-in-memory@1.0.0-alpha.9) (2026-03-14)

### Bug Fixes

* eliminate Obj.magic from Platform DcbSpec boundaries ([135888b](https://github.com/ReventlessDev/reventless-core/commit/135888b226727d7ed8cc1e364e242b12071e107a))
### Features

* add optional DCB spec support to Core module and consolidate builder helpers ([06a5e6f](https://github.com/ReventlessDev/reventless-core/commit/06a5e6f2eeadbabd20fb7197318d760b91c34925))
* implement hybrid API/MCP schema split (core vs plugins) ([4f84866](https://github.com/ReventlessDev/reventless-core/commit/4f848667c0814533b2f3a294350c4310c61d9fc7))
# [1.0.0-alpha.8](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-in-memory@1.0.0-alpha.7...@reventlessdev/reventless-in-memory@1.0.0-alpha.8) (2026-03-12)

### Features

* capitalize and prefix Core_ on GraphQL/MCP queries and mutations ([769420b](https://github.com/ReventlessDev/reventless-core/commit/769420b47ce35aba46d248d1529f7c72c7df9c0e))
* unify schema generation pipeline across GraphQL and MCP protocols ([84e05ae](https://github.com/ReventlessDev/reventless-core/commit/84e05aeca8c13000040d1230502b07350ab5daeb))
# [1.0.0-alpha.7](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-in-memory@1.0.0-alpha.6...@reventlessdev/reventless-in-memory@1.0.0-alpha.7) (2026-03-12)

### Features

* **deps:** upgrade rescript to 12.2 and migrate Belt usages to stdlib ([eaa96ea](https://github.com/ReventlessDev/reventless-core/commit/eaa96ea61ca40d61573fb5fe2002a1f73d43ce3e))
# [1.0.0-alpha.6](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-in-memory@1.0.0-alpha.4...@reventlessdev/reventless-in-memory@1.0.0-alpha.6) (2026-03-08)

### Bug Fixes

* add aggregate instance ID parameter to MCP and GraphQL mutations ([7a83ca4](https://github.com/ReventlessDev/reventless-core/commit/7a83ca4e3140d7e25e2bf0c75ac515bde864198f))
* **deps:** deduplicate graphql package to resolve schema conflict ([c33b030](https://github.com/ReventlessDev/reventless-core/commit/c33b030c14993e27700c5f0ec44a8a6ebe582468))
* **graphql:** register DCB mutation resolvers and fix schema timing ([3e7da8d](https://github.com/ReventlessDev/reventless-core/commit/3e7da8df7efb20a0ff3dc7c82e10a807cb516182))
* MCP server CORS and stateless transport handling ([38d1dad](https://github.com/ReventlessDev/reventless-core/commit/38d1dadc100d96787f3d4072dc3b1bc23fa6d492))
* remove 26 Obj.magic usages, improve type safety across codebase ([ebb8925](https://github.com/ReventlessDev/reventless-core/commit/ebb8925b760a0f070b1aaf3ef2d4bf3fdc7282a3))
### Features

* add AutomationSlice component (TODO list pattern) ([4642688](https://github.com/ReventlessDev/reventless-core/commit/46426884727aff74db33b9289feca9878b0e3ed9))
* add AWS event history handlers and pagination for MCP resources ([33f6e39](https://github.com/ReventlessDev/reventless-core/commit/33f6e3910d50cfbe03c9d2d2ed2ea97b92ab7501))
* add effect-based handlers with Effect service injection at dispatch ([7ab3b3e](https://github.com/ReventlessDev/reventless-core/commit/7ab3b3e8a48890f2248b113328914755f604c07e))
* add MCP event history resources and fix QueryDb/MCP resource bugs ([3197d4f](https://github.com/ReventlessDev/reventless-core/commit/3197d4fb52a7b20bc68cd3088d9d6fac21a41f6f))
* add MCP server layer for AI-native access to Reventless ([4b288bc](https://github.com/ReventlessDev/reventless-core/commit/4b288bce2fc17c28c32c6778028becb0cde4c544))
* add TranslationSlice components with docs and webhook backlog plan ([7362a8f](https://github.com/ReventlessDev/reventless-core/commit/7362a8f26bca2eaad9d99488ec597c426635659d))
* auto-generate GraphQL mutations for InboundTranslationSlice ([7011fd2](https://github.com/ReventlessDev/reventless-core/commit/7011fd29f3029f001aa94fa78eb4f6b34d45451e))
* fix GraphQL SDL generation — correct naming, typed returns, and aggregate mutations ([ac93318](https://github.com/ReventlessDev/reventless-core/commit/ac933182dcd238b5f02ed98d1ddf03bb52b2c109))
* **graphql:** add GRAPHQL_DEBUG mode, schema inspector, and debugging guide ([61fcbee](https://github.com/ReventlessDev/reventless-core/commit/61fcbee6ee68337e95b5934a14279420e8ab8eca))
* harmonize error handling and retry with Effect across all AWS adapters ([a817bde](https://github.com/ReventlessDev/reventless-core/commit/a817bde2fbbda314ebdbc69aee17de717ee059ed))
* make Logger injectable at Platform level and replace Console.log in runtime builders ([5c5dd5b](https://github.com/ReventlessDev/reventless-core/commit/5c5dd5bc07c14c13a9fc5d857d26387e14d06dd6))
* migrate logging to Effect built-in logger and provide RequestContext ([e9ec682](https://github.com/ReventlessDev/reventless-core/commit/e9ec6822ea924fc1561bfd886e4232cb5e2a8250))
* replace explicit queryMode with automatic schema-driven DCB query construction ([8df4350](https://github.com/ReventlessDev/reventless-core/commit/8df4350c37f1f15678f4796f229647eaeb3e8222))
* replace timestamp-based sequenceNr with integer sequence numbers and optimistic locking ([50b7d3e](https://github.com/ReventlessDev/reventless-core/commit/50b7d3e9901daafc6dff8c9492a789bc700e9099))
# [1.0.0-alpha.5](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-in-memory@1.0.0-alpha.4...@reventlessdev/reventless-in-memory@1.0.0-alpha.5) (2026-03-08)

### Bug Fixes

* add aggregate instance ID parameter to MCP and GraphQL mutations ([7a83ca4](https://github.com/ReventlessDev/reventless-core/commit/7a83ca4e3140d7e25e2bf0c75ac515bde864198f))
* **deps:** deduplicate graphql package to resolve schema conflict ([c33b030](https://github.com/ReventlessDev/reventless-core/commit/c33b030c14993e27700c5f0ec44a8a6ebe582468))
* **graphql:** register DCB mutation resolvers and fix schema timing ([3e7da8d](https://github.com/ReventlessDev/reventless-core/commit/3e7da8df7efb20a0ff3dc7c82e10a807cb516182))
* MCP server CORS and stateless transport handling ([38d1dad](https://github.com/ReventlessDev/reventless-core/commit/38d1dadc100d96787f3d4072dc3b1bc23fa6d492))
* remove 26 Obj.magic usages, improve type safety across codebase ([ebb8925](https://github.com/ReventlessDev/reventless-core/commit/ebb8925b760a0f070b1aaf3ef2d4bf3fdc7282a3))
### Features

* add AutomationSlice component (TODO list pattern) ([4642688](https://github.com/ReventlessDev/reventless-core/commit/46426884727aff74db33b9289feca9878b0e3ed9))
* add AWS event history handlers and pagination for MCP resources ([33f6e39](https://github.com/ReventlessDev/reventless-core/commit/33f6e3910d50cfbe03c9d2d2ed2ea97b92ab7501))
* add effect-based handlers with Effect service injection at dispatch ([7ab3b3e](https://github.com/ReventlessDev/reventless-core/commit/7ab3b3e8a48890f2248b113328914755f604c07e))
* add MCP event history resources and fix QueryDb/MCP resource bugs ([3197d4f](https://github.com/ReventlessDev/reventless-core/commit/3197d4fb52a7b20bc68cd3088d9d6fac21a41f6f))
* add MCP server layer for AI-native access to Reventless ([4b288bc](https://github.com/ReventlessDev/reventless-core/commit/4b288bce2fc17c28c32c6778028becb0cde4c544))
* add TranslationSlice components with docs and webhook backlog plan ([7362a8f](https://github.com/ReventlessDev/reventless-core/commit/7362a8f26bca2eaad9d99488ec597c426635659d))
* auto-generate GraphQL mutations for InboundTranslationSlice ([7011fd2](https://github.com/ReventlessDev/reventless-core/commit/7011fd29f3029f001aa94fa78eb4f6b34d45451e))
* fix GraphQL SDL generation — correct naming, typed returns, and aggregate mutations ([ac93318](https://github.com/ReventlessDev/reventless-core/commit/ac933182dcd238b5f02ed98d1ddf03bb52b2c109))
* **graphql:** add GRAPHQL_DEBUG mode, schema inspector, and debugging guide ([61fcbee](https://github.com/ReventlessDev/reventless-core/commit/61fcbee6ee68337e95b5934a14279420e8ab8eca))
* harmonize error handling and retry with Effect across all AWS adapters ([a817bde](https://github.com/ReventlessDev/reventless-core/commit/a817bde2fbbda314ebdbc69aee17de717ee059ed))
* make Logger injectable at Platform level and replace Console.log in runtime builders ([5c5dd5b](https://github.com/ReventlessDev/reventless-core/commit/5c5dd5bc07c14c13a9fc5d857d26387e14d06dd6))
* migrate logging to Effect built-in logger and provide RequestContext ([e9ec682](https://github.com/ReventlessDev/reventless-core/commit/e9ec6822ea924fc1561bfd886e4232cb5e2a8250))
# [1.0.0-alpha.4](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-in-memory@1.0.0-alpha.3...@reventlessdev/reventless-in-memory@1.0.0-alpha.4) (2026-03-03)

### Features

* **api:** implement Api component with GraphQL fragment generation and schema stitching ([c882d3a](https://github.com/ReventlessDev/reventless-core/commit/c882d3aae8722cf6cbe9b4fbf9518d9f434ce06a))
* **platform:** expose Plugin, Core, makeScheduler, makePlatform via Platform.T ([0df4bf3](https://github.com/ReventlessDev/reventless-core/commit/0df4bf333ea4f9c0e51e96df1ad0da4ab471ffe8))
# [1.0.0-alpha.3](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-in-memory@1.0.0-alpha.2...@reventlessdev/reventless-in-memory@1.0.0-alpha.3) (2026-03-02)

**Note:** Version bump only for package @reventlessdev/reventless-in-memory

# 1.0.0-alpha.2 (2026-03-01)

### Bug Fixes

* **in-memory:** replace deprecated String.sliceToEnd with String.slice ([a9dfd00](https://github.com/ReventlessDev/reventless-core/commit/a9dfd00df1bff66adcd56a4b804b47d634b823c1))
* **reventless-in-memory:** expand AsyncTest include to avoid external [@send](https://github.com/send) binding errors ([a9f7b55](https://github.com/ReventlessDev/reventless-core/commit/a9f7b553226f23c7700c54ae00fc92ed315b1098))
* feat(reventless-spec)!: swap namespaces — spec→Reventless, core→ReventlessCore ([0fcf24e](https://github.com/ReventlessDev/reventless-core/commit/0fcf24e3fc1dcc88e9ee741dc99eb7bd726f9fd7))
* feat(reventless-core)!: rename package from @reventlessdev/reventless to @reventlessdev/reventless-core ([5e93146](https://github.com/ReventlessDev/reventless-core/commit/5e9314692b5b5d60beee187564ba94bc9fd46c05))
### Features

* **in-memory:** implement P0 GraphQL server for mutations and queries ([2627cdc](https://github.com/ReventlessDev/reventless-core/commit/2627cdc147b2deeb160e9642750bf26da8f95108))
* **in-memory:** implement P1/P2 gaps — QueryEngine, Counter, Scheduler ([faa2d52](https://github.com/ReventlessDev/reventless-core/commit/faa2d52e205f81d3c0d8a203a5b69dcaa19cf218))
* **in-memory:** implement P3 gap — HeartbeatRunner_InMemory ([9f188b5](https://github.com/ReventlessDev/reventless-core/commit/9f188b53d23eae1a768f96291ad75435a828b309))
* **rescript-effect:** Effect library bindings + stream-based framework handlers ([#30](https://github.com/ReventlessDev/reventless-core/issues/30)) ([f2ca5cf](https://github.com/ReventlessDev/reventless-core/commit/f2ca5cf3d56d66a9f4ab56b543d7bf82e48448dd))

### BREAKING CHANGES

* ReventlessSpec namespace renamed to Reventless; the reventless-core
package namespace renamed from Reventless to ReventlessCore.
All usages of ReventlessSpec.* must be updated to Reventless.*;
all usages of Reventless.* (core) in dependent packages must be updated to ReventlessCore.*

* package renamed for consistency with sibling packages
and the repository name. ReScript namespace "Reventless" is unchanged —
no source code updates required.

- git mv reventless/reventless → reventless/reventless-core
- package.json and rescript.json name updated to @reventlessdev/reventless-core
- reventless-aws and reventless-in-memory dependency references updated
- Root package.json and rescript.json renamed to "reventless-monorepo" to
  avoid name collision that caused ReScript to skip building the sub-package
- Updated recompiled .res.mjs output files with new relative import paths
