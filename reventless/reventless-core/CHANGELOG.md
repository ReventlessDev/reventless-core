# Change Log

All notable changes to this project will be documented in this file.
See [Conventional Commits](https://conventionalcommits.org) for commit guidelines.

# 3.0.0-alpha.125 (2026-06-20)

**Note:** Version bump only for package @reventlessdev/reventless-core





# 3.0.0-alpha.124 (2026-06-18)

**Note:** Version bump only for package @reventlessdev/reventless-core





# 3.0.0-alpha.123 (2026-06-18)

### Features

* **admin:** generate admin read-model query SDL from spec (parity) ([1545f77](https://github.com/ReventlessDev/reventless-core/commit/1545f77beec495cd8564be94a510fcf01903d28b))


# 3.0.0-alpha.122 (2026-06-18)

### Features

* **admin:** expose PluginHistory as a visible admin read model ([8a1d86e](https://github.com/ReventlessDev/reventless-core/commit/8a1d86ee30eddefe9a363eaf041e853c1d4e4af6))


# 3.0.0-alpha.121 (2026-06-18)

### Bug Fixes

* **aws:** reject mutations on Retired plugins in the runtime status gate ([0e9afdd](https://github.com/ReventlessDev/reventless-core/commit/0e9afdd30d15f537b54c9404ddc37a78d2219ee4))
* **core:** derive plugin module specifiers from @[@reventless](https://github.com/reventless).spec moduleUrl ([5bc47cb](https://github.com/ReventlessDev/reventless-core/commit/5bc47cbbcc83b7cb1bb8c2a3812a57c4d05b7fbb))
### Features

* **admin:** name-keyed plugin lifecycle aggregate + current view ([c6720d0](https://github.com/ReventlessDev/reventless-core/commit/c6720d089b71393803183600fde61dfa32d780b5))
* **admin:** PluginHistory lifecycle audit view (core + AWS) ([00402ca](https://github.com/ReventlessDev/reventless-core/commit/00402ca010e3e404928e9df5ed15f6a419924d46))


# 3.0.0-alpha.120 (2026-06-17)

### Bug Fixes

* **admin:** dedup plugin versions in UI manifest queries ([7a21ca3](https://github.com/ReventlessDev/reventless-core/commit/7a21ca30461622287a9d3f42fe54579fbdb75eb2))


# 3.0.0-alpha.119 (2026-06-17)

### Bug Fixes

* **packaging:** executable ppx binaries + promote phantom deps for standalone installs ([9b6bea2](https://github.com/ReventlessDev/reventless-core/commit/9b6bea24570b0b0654c825d560ef781c0295512a))
* feat!: rename Call directive to HandleDirective for naming consistency ([3fdf84a](https://github.com/ReventlessDev/reventless-core/commit/3fdf84a503b8ee9b07d0774e34c911f5d90d45d0))
* feat!: harmonize plugin make() across aggregate/DCB/hybrid; AutoUI default-on ([6f3b95e](https://github.com/ReventlessDev/reventless-core/commit/6f3b95e6aa8a136c6e837346c41a3a4dff0f9405))
### Features

* **core:** carry emitted-event field schemas in pluginStructure (Phase 6.3) ([693d452](https://github.com/ReventlessDev/reventless-core/commit/693d4529ee4c66a2a4a4b0d4d7efb104cf94bcab))

### BREAKING CHANGES

* out-of-tree plugins emitting Call(handler, msg) from
commandAction / eventAction / incomingCommandAction / outgoingCommandAction
must rename to HandleDirective(handler, directive). The callHandler<'msg>
type alias is now directiveHandler<'directive>.

Plan: docs/plans/done/directive-naming-consistency.md
* makeAutoUIManifest signature dropped ~aggregates and
~readModels; replaced with ~pluginStructure. Hand-written Plugin.res files
that pass ~uiBundleUrl to plugin.make must drop the arg and rely on the
generator-emitted env var read.



# 3.0.0-alpha.118 (2026-06-12)

**Note:** Version bump only for package @reventlessdev/reventless-core





# 3.0.0-alpha.117 (2026-06-12)

### Features

* **vscode:** jump from event-graph nodes to source + show Internal components in the dev graph ([6a6e5e4](https://github.com/ReventlessDev/reventless-core/commit/6a6e5e466c6ea5c0c7315ccc37a538e0b496c99a))


# 3.0.0-alpha.116 (2026-06-11)

**Note:** Version bump only for package @reventlessdev/reventless-core





# 3.0.0-alpha.115 (2026-06-10)

* refactor(reventless-local)!: rename reventless-in-memory to reventless-local ([f36e17c](https://github.com/ReventlessDev/reventless-core/commit/f36e17c407714ab9740393fac96865d6a5c143c9))
### Features

* **core:** richer command/state logging and working LOG_LEVEL control ([514901f](https://github.com/ReventlessDev/reventless-core/commit/514901f4b0324d55a65a8f7c07675238b908b2d4))
* **core:** richer StateChangeSlice command-handler logging ([4ed036b](https://github.com/ReventlessDev/reventless-core/commit/4ed036b7c1b4549d05102f3639eb16f76557140f))
* **logging:** operational hygiene — truncation, ISO time, service field, Insights guide (Tier 3) ([ed9f98e](https://github.com/ReventlessDev/reventless-core/commit/ed9f98e8d015213d04a9a546fe108a70e6bfcee8))
* **logging:** sink-aware ANSI formatting — clean JSON in non-TTY sinks (Tier 1) ([32ae533](https://github.com/ReventlessDev/reventless-core/commit/32ae5337a45ff9cbd26754b5b1c71c5c7070507b))
* **logging:** structured JSON fields + correlationId/requestId tracing (Tier 2) ([7335638](https://github.com/ReventlessDev/reventless-core/commit/7335638c7b7da376e2368dd829c3a26290114d5e))
* **reventless-core:** extension-point source events in pluginStructure ([9c47a0e](https://github.com/ReventlessDev/reventless-core/commit/9c47a0ea9a1643ac12fbe8dc1c43244e580de024))

### BREAKING CHANGES

* @reventlessdev/reventless-in-memory -> @reventlessdev/reventless-local;
namespace ReventlessInMemory -> ReventlessLocal.



# 3.0.0-alpha.114 (2026-06-08)

**Note:** Version bump only for package @reventlessdev/reventless-core





# 3.0.0-alpha.113 (2026-06-08)

### Features

* **logging:** operational hygiene — truncation, ISO time, service field, Insights guide (Tier 3) ([42f8d49](https://github.com/ReventlessDev/reventless-core/commit/42f8d49ebdb20beaf0ec20a0d2cc2561b4e11ab0))
* **logging:** sink-aware ANSI formatting — clean JSON in non-TTY sinks (Tier 1) ([7da6256](https://github.com/ReventlessDev/reventless-core/commit/7da62568eaa06c2bedf5d7ad6d10b1ec006a6b75))
* **logging:** structured JSON fields + correlationId/requestId tracing (Tier 2) ([49738c5](https://github.com/ReventlessDev/reventless-core/commit/49738c5e54f0707b4a9c6991c07c61abe41ccf64))


# 3.0.0-alpha.112 (2026-06-08)

### Features

* **reventless-core:** extension-point source events in pluginStructure ([1e1d925](https://github.com/ReventlessDev/reventless-core/commit/1e1d9258b5a228b9fdfa003348a5367281573b3c))


# 3.0.0-alpha.111 (2026-06-07)

**Note:** Version bump only for package @reventlessdev/reventless-core





# 3.0.0-alpha.110 (2026-06-06)

* refactor(reventless-local)!: rename reventless-in-memory to reventless-local ([966855f](https://github.com/ReventlessDev/reventless-core/commit/966855fd31e518d56a381bf40204735809cead15))

### BREAKING CHANGES

* @reventlessdev/reventless-in-memory -> @reventlessdev/reventless-local;
namespace ReventlessInMemory -> ReventlessLocal.



# 3.0.0-alpha.109 (2026-06-04)

**Note:** Version bump only for package @reventlessdev/reventless-core





# 3.0.0-alpha.108 (2026-06-04)

**Note:** Version bump only for package @reventlessdev/reventless-core





# 3.0.0-alpha.107 (2026-06-04)

**Note:** Version bump only for package @reventlessdev/reventless-core





# 3.0.0-alpha.106 (2026-06-04)

### Features

* **core:** richer command/state logging and working LOG_LEVEL control ([284e562](https://github.com/ReventlessDev/reventless-core/commit/284e56217b90e29c42421926e507258332f11e11))
* **core:** richer StateChangeSlice command-handler logging ([6fbab5c](https://github.com/ReventlessDev/reventless-core/commit/6fbab5c7a2248d919f656767f5c248811d1a6174))


# 3.0.0-alpha.105 (2026-06-04)

**Note:** Version bump only for package @reventlessdev/reventless-core





# 3.0.0-alpha.104 (2026-05-28)

### Bug Fixes

* **framework:** align DCB event tags with query tags and relax fence check when slice observed nothing ([de21635](https://github.com/ReventlessDev/reventless-core/commit/de21635bcb026d73cad0eef5561b6779df81fdc2))
* **framework:** wire user extensions with mapIncomingEvent-only to publish to their Delegate cmd-topic ([fb4644b](https://github.com/ReventlessDev/reventless-core/commit/fb4644be789b6271bebeaa1f5984f0278b45ec14))


# 3.0.0-alpha.103 (2026-05-28)

### Bug Fixes

* **framework:** normalise DcbEventLog meta.service before storage append ([4f6ec77](https://github.com/ReventlessDev/reventless-core/commit/4f6ec77ed0c943cfe83f8707fd926c19e57df3eb))


# 3.0.0-alpha.102 (2026-05-27)

### Bug Fixes

* **framework:** wire plugin ExtensionPoints into EventCollector runtime context ([2ce8dff](https://github.com/ReventlessDev/reventless-core/commit/2ce8dff426b576811a28c012934d77ecba8a33c0))


# 3.0.0-alpha.101 (2026-05-27)

**Note:** Version bump only for package @reventlessdev/reventless-core





# 3.0.0-alpha.100 (2026-05-27)

**Note:** Version bump only for package @reventlessdev/reventless-core





# 3.0.0-alpha.99 (2026-05-27)

**Note:** Version bump only for package @reventlessdev/reventless-core





# 3.0.0-alpha.98 (2026-05-26)

**Note:** Version bump only for package @reventlessdev/reventless-core





# 3.0.0-alpha.97 (2026-05-26)

**Note:** Version bump only for package @reventlessdev/reventless-core





# 3.0.0-alpha.96 (2026-05-25)

**Note:** Version bump only for package @reventlessdev/reventless-core





# 3.0.0-alpha.95 (2026-05-25)

**Note:** Version bump only for package @reventlessdev/reventless-core





# 3.0.0-alpha.94 (2026-05-25)

### Features

* **live-updates:** consolidate StateTopic Lambda + admin RMs live-update ([7b158c7](https://github.com/ReventlessDev/reventless-core/commit/7b158c71c97eb114d2453b81a1e8cf46e4f0bdb2))


# 3.0.0-alpha.93 (2026-05-21)

**Note:** Version bump only for package @reventlessdev/reventless-core





# 3.0.0-alpha.92 (2026-05-21)

### Bug Fixes

* **admin:** register admin queryFieldNames under read-model Spec.name ([f5c10f8](https://github.com/ReventlessDev/reventless-core/commit/f5c10f80068e45329533547203f5417029ea48b7))


# 3.0.0-alpha.91 (2026-05-21)

### Bug Fixes

* **admin:** close AppSync schema-push vs CreateDataSource race in admin barrier ([46b61f9](https://github.com/ReventlessDev/reventless-core/commit/46b61f9136fcc70c52cf18220a5b5945202631ce))
* feat(admin)!: replace direct DynamoDB retire write with Retire/Retired event flow ([7f5f018](https://github.com/ReventlessDev/reventless-core/commit/7f5f018e714e247331d143c304c0d671c2ac7c84))

### BREAKING CHANGES

* Platform.deployPlugin no longer accepts ~version. Generated
Main.res files are regenerated; any direct caller must drop the arg.



# 3.0.0-alpha.90 (2026-05-20)

### Bug Fixes

* **admin:** name the platform Plugins read model in the plural ([afa11a8](https://github.com/ReventlessDev/reventless-core/commit/afa11a8b7314bad5681006c93aa44196eb7c122f))


# 3.0.0-alpha.89 (2026-05-20)

### Bug Fixes

* **aws:** harden runtime AppSync schema update against transient clobber ([4d768e4](https://github.com/ReventlessDev/reventless-core/commit/4d768e434c28042242463e0341e1c543ddc12c63))


# 3.0.0-alpha.88 (2026-05-20)

### Bug Fixes

* **admin:** make cross-plugin SNS subscriptions actually wire (Phase 3 Step 4) ([8f727df](https://github.com/ReventlessDev/reventless-core/commit/8f727dfb20d137fc7fcc307c80c1007eab802a26))
### Features

* **plugin:** wire dcbEventLog into pluginDefinition for cross-plugin DCB routing (Phase 4) ([07b78f3](https://github.com/ReventlessDev/reventless-core/commit/07b78f359f8f039992ec0ce7922085b165695537))


# 3.0.0-alpha.87 (2026-05-19)

### Bug Fixes

* **aggregate:** preserve conflict detail in CommandRejected.errorDetail ([8ebf696](https://github.com/ReventlessDev/reventless-core/commit/8ebf69621f214c82bf38e91d2bfce2b4edd57ea7))
* **aggregate:** report non-conflict append errors via reportRejected ([b977d67](https://github.com/ReventlessDev/reventless-core/commit/b977d678bc5d963a868b55c444a67a71450a040c))
* **aws:** wrap TransactWriteCommand input via .make() before .send() ([a6d65b5](https://github.com/ReventlessDev/reventless-core/commit/a6d65b50986809fc06e8888b3374019bb28df281))


# 3.0.0-alpha.86 (2026-05-19)

### Bug Fixes

* **admin:** gate admin createResolvers on schema push to eliminate API-lock race ([cfd282a](https://github.com/ReventlessDev/reventless-core/commit/cfd282a65cea981c67d27309808471a4d7bfb5a3))


# 3.0.0-alpha.85 (2026-05-19)

### Bug Fixes

* **aws:** close AppSync resolver gaps for drift, inbound subs, slice query DBs ([8d10126](https://github.com/ReventlessDev/reventless-core/commit/8d10126168eade99e6dad19c8bac3f0dfa2240fa))
### Features

* **api:** batched-by-ids query field for single-key projections ([d5d836d](https://github.com/ReventlessDev/reventless-core/commit/d5d836de52a478fb096965d7c83882d6ef302508))


# 3.0.0-alpha.84 (2026-05-19)

### Bug Fixes

* **api:** align Source C subscription type with CommandResult mutation ([723882d](https://github.com/ReventlessDev/reventless-core/commit/723882df25d8544cf61a9ddb8fd9d423134e5fa1))
* **aws:** emit __typename in CommandResult mutation response ([aa05fb5](https://github.com/ReventlessDev/reventless-core/commit/aa05fb54e25fd7232b46ec9150bdd3a0c93080a8))
* refactor(aws)!: rename DCB Lambdas to <Plugin>StateChanges[Async] ([f2b20ca](https://github.com/ReventlessDev/reventless-core/commit/f2b20ca86c66cfd88d87696d89b745d70c5f156b))
### Features

* **api:** emit CommandResult! for aggregate-derived mutations ([5d0afb2](https://github.com/ReventlessDev/reventless-core/commit/5d0afb2e8c889a3ce20c37d66807f65b7196a6ff))
* **platform:** commandHandlerConfig for per-flavor Lambda tuning ([4154061](https://github.com/ReventlessDev/reventless-core/commit/4154061d9343f90ce61955992d9119d0f7a251e1))

### BREAKING CHANGES

* this is a Pulumi resource rename without `aliases`,
so `pulumi up` will destroy and recreate the DCB Lambda, its SQS
queue(s), the AppSync DataSource and resolvers, and associated IAM.
In-flight FIFO messages on async StateChangeSlices are lost. Plan a
maintenance window for stacks with sustained async DCB traffic.



# 3.0.0-alpha.83 (2026-05-18)

### Bug Fixes

* **dcb:** Dcb_Builder.dcbCommandTopicQueueUrl — drop Option.map wrapper that emitted BS_PRIVATE_NESTED_SOME_NONE into Lambda env vars ([8f058f9](https://github.com/ReventlessDev/reventless-core/commit/8f058f918346e28618b97ce03c7177232d395a1e))


# 3.0.0-alpha.82 (2026-05-18)

### Bug Fixes

* **admin:** give projection files their own moduleUrl so RM lambdas don't load Platform.res ([78ef5ec](https://github.com/ReventlessDev/reventless-core/commit/78ef5ece65575671d7fce877b0cf5adf578dfd05))
* **eventlog:** surface defects in append-failure msg via Cause.pretty ([b237f2a](https://github.com/ReventlessDev/reventless-core/commit/b237f2aac4800c8ac8c8ddc3fa16d4484e2c9c78))
* **plugin:** split Connect mapping out of _Builder so Lambda layer can load it ([937935a](https://github.com/ReventlessDev/reventless-core/commit/937935a2d65e3bc61b2b94623a2f9c5c1b7a46df))
* **spec:** restore payload-less filter in extractVariantNames; route acceptedTags through extractAllVariantNames ([208f644](https://github.com/ReventlessDev/reventless-core/commit/208f644cc0e21cb7c2ad3cf7bf43b5e7a99732f7))
### Features

* **admin:** cross-plugin SNS subscription manager in AdminEventCollector (Phase 3 Step 1) ([8f8544c](https://github.com/ReventlessDev/reventless-core/commit/8f8544c176c065b3cccb42e6eee4cdfd03b40d48))
* **plugin:** unblock admin → plugin Connect via Plugin_Callback at runtime ([4076ddf](https://github.com/ReventlessDev/reventless-core/commit/4076ddf8a5c8d6c323c9ea188774030ff535b8f9))
* **plugin:** wire end-to-end user-extension dispatch through plugin EventCollectors ([f616abe](https://github.com/ReventlessDev/reventless-core/commit/f616abe169289f836f8e538b5419cb82cda886d7))


# 3.0.0-alpha.81 (2026-05-17)

### Bug Fixes

* **aggregate:** surface DynamoDB append-failure cause to logs ([4169748](https://github.com/ReventlessDev/reventless-core/commit/4169748d64c627ea5075ac7a5127273c74a8c177))


# 3.0.0-alpha.80 (2026-05-17)

### Bug Fixes

* **deps:** pin sury-ppx to 11.0.0-alpha.2 to prevent prerelease drift ([c9d05fe](https://github.com/ReventlessDev/reventless-core/commit/c9d05fe5118a9c0442ca3e071f2606b3a139fc81))


# 3.0.0-alpha.79 (2026-05-17)

### Bug Fixes

* **aws:** wire schedulerRoleArn through admin registers; default heartbeat to 5 min ([f9580a2](https://github.com/ReventlessDev/reventless-core/commit/f9580a2fc7f85a67747ccaab87358f303bd90ab9))


# 3.0.0-alpha.78 (2026-05-17)

### Bug Fixes

* **deps:** pin sury to 11.0.0-alpha.4 to unblock Lambda Layer deploys ([643d925](https://github.com/ReventlessDev/reventless-core/commit/643d92527fa9d092da9bef8547591e39a4c609dd))


# 3.0.0-alpha.77 (2026-05-17)

### Bug Fixes

* **aws:** pass pluginId through onHeartbeatEpChannelAvailable so heartbeat Lambda has PLUGIN_ID ([cc983bf](https://github.com/ReventlessDev/reventless-core/commit/cc983bf5b737cf282f1bdeab7e2a3e95531d59ef))
### Features

* **admin:** strip plugin version at GraphQL boundary for UI-facing pluginIds ([a03f028](https://github.com/ReventlessDev/reventless-core/commit/a03f0283c020b38fae26bbef1fb702fa928af95b))


# 3.0.0-alpha.76 (2026-05-17)

### Bug Fixes

* **admin:** invoke resolversMaker for admin read models so Platform_Plugins gets an AppSync resolver ([3307e9b](https://github.com/ReventlessDev/reventless-core/commit/3307e9b59343e691e3930e235c266fb9056959b7))


# 3.0.0-alpha.75 (2026-05-16)

### Bug Fixes

* **admin:** attach AppSync resolvers to Platform_Plugin(s)/PlatformEventGraph(s) ([c2cd069](https://github.com/ReventlessDev/reventless-core/commit/c2cd069880f028296de5bb625984916e9e280fe6))


# 3.0.0-alpha.74 (2026-05-16)

### Bug Fixes

* also filter Internal queryables from pluginStructure ([abdf247](https://github.com/ReventlessDev/reventless-core/commit/abdf2472299e975f7d1aa4b31318ba7e9919a206))
### Features

* **ppx:** add @[@reventless](https://github.com/reventless).visibility to hide components from AutoUI ([bd302cf](https://github.com/ReventlessDev/reventless-core/commit/bd302cfc5bd5d4dfe50c8e1bf8596ab67e36c74e))


# 3.0.0-alpha.73 (2026-05-16)

### Bug Fixes

* **admin:** emit Source C subscription fields for admin Plugin mutations ([36b034e](https://github.com/ReventlessDev/reventless-core/commit/36b034ee5af687895745580427fb3f091a1c76fe))


# 3.0.0-alpha.72 (2026-05-16)

### Bug Fixes

* **api:** match admin command variants by name not position ([8aabea3](https://github.com/ReventlessDev/reventless-core/commit/8aabea3704879b63b69ee184cf8fdd85cf0a1e55))
* **core:** align Plugin RM UIDefinitions schema with SDL for AutoUI ([99dd7c0](https://github.com/ReventlessDev/reventless-core/commit/99dd7c0d9442f8b2ecd5e93989dc3116279bd70c))
* **core:** populate Plugin admin allowedStates + statusField for AutoUI filter ([2a7fe34](https://github.com/ReventlessDev/reventless-core/commit/2a7fe34393e1feece7b2de6bad535e8e0d4e1e91))
* **core:** restore payload-less filter for event-schema extraction ([664d88f](https://github.com/ReventlessDev/reventless-core/commit/664d88f24f19f967f9680694d947f766bd4bc263))
* **ppx:** drop [@allowed](https://github.com/allowed)States witness; spec.status as option<string> ([cc0eed0](https://github.com/ReventlessDev/reventless-core/commit/cc0eed0e499c70009603619dd9f23a6bb2dd35df))
### Features

* add onPluginStatusChange subscription contract + in-memory emit ([1859dae](https://github.com/ReventlessDev/reventless-core/commit/1859daefec3e74ad4e0a87c11cc45b32f99f6962))
* **admin:** expose built-in Platform admin plugin in host shell Auto UI ([e9a8cb2](https://github.com/ReventlessDev/reventless-core/commit/e9a8cb20efb958e582738720ddb5812bdf950876))
* complete plugin status gate on both adapters with tiered error codes ([2a8309b](https://github.com/ReventlessDev/reventless-core/commit/2a8309bbf324b276dbcede1be85a5f90dedd82eb))
* **ppx:** [@status](https://github.com/status) field annotation + [@allowed](https://github.com/allowed)States command annotation ([15f0478](https://github.com/ReventlessDev/reventless-core/commit/15f0478209dbb4e5d385332cf8cf320c694ac1c1))
* **spec:** allowedStates + statusField metadata for AutoUI command filtering ([b5d138b](https://github.com/ReventlessDev/reventless-core/commit/b5d138bb706515f7c6ba5daf7f4ef481cc35d024))
* wire admin Plugin aggregate through standard auto-resolver flow ([73a58d3](https://github.com/ReventlessDev/reventless-core/commit/73a58d3b93922989a51bc15724dd92baa15b7037))


# 3.0.0-alpha.71 (2026-05-14)

### Bug Fixes

* **admin:** drop UIFragments auto-query, keep flat Platform_UIFragments ([b615481](https://github.com/ReventlessDev/reventless-core/commit/b61548148cc998b65c696607022c5fa01935e491))
### Features

* **admin:** add Platform_UIFragments GraphQL query ([cf1ae27](https://github.com/ReventlessDev/reventless-core/commit/cf1ae27d19bf396dfa71c2539fd59874c9118ca0))
* **auth:** enforce per-spec authorization at in-memory resolvers ([32c6552](https://github.com/ReventlessDev/reventless-core/commit/32c65522cf4afb61c7c56f8828a95af8db4a0ad4))
* **auth:** expose payload-less commands to GraphQL + per-constructor authz test ([7a55b27](https://github.com/ReventlessDev/reventless-core/commit/7a55b27ea04e84368909b24fc5ca29f415d108da))
* **auth:** scaffold provider-agnostic auth abstraction ([a273c10](https://github.com/ReventlessDev/reventless-core/commit/a273c10d4598d9d2fdcc7428dde3278818aba9b8))
* **auth:** Stage E2 — lift spec-level Authorization.permission into [@aws](https://github.com/aws)_auth ([5f10fc9](https://github.com/ReventlessDev/reventless-core/commit/5f10fc94f501ad6e6f0d677f754acc3761281ab3))
* **ppx:** inline-spec walk + Spec module types require authorization ([7db9ec0](https://github.com/ReventlessDev/reventless-core/commit/7db9ec0f186578ce0088973dba22da9257be6a61))


# 3.0.0-alpha.70 (2026-05-13)

* feat(spec)!: standardise event/command envelope (StoredEvent, optional meta, position, persisted DCB meta, causation) ([7ef3176](https://github.com/ReventlessDev/reventless-core/commit/7ef3176c6330810c817f43a52b881b5a0efee30e))

### BREAKING CHANGES

* meta.ip / meta.user go from required `string` to optional
record fields (`?: string`). Code that did `meta.user == "unknown"` to
detect system messages must check for field absence. Storage tables built
before this change are not migrated (greenfield — recreate the EventLog /
DcbEventLog tables; DynamoDB range key renamed from `seq` to `position`,
SQLite dcb_event gains meta and recorded_at columns).



# 3.0.0-alpha.69 (2026-05-10)

### Bug Fixes

* **aggregate:** propagate decide-errors as Rejected outcomes ([7eb1d59](https://github.com/ReventlessDev/reventless-core/commit/7eb1d599dd7d02791bffa915c19c40479ce6e9da))


# 3.0.0-alpha.68 (2026-05-05)

### Features

* **dcb:** allow plural *Ids field names with shared singular tag key ([19a5167](https://github.com/ReventlessDev/reventless-core/commit/19a5167ed904c6152c137af738f869ee4d26287e))


# 3.0.0-alpha.67 (2026-05-04)

### Bug Fixes

* **aws:** drop empty Config functor args; thread per-spec metadata as direct params ([17837a3](https://github.com/ReventlessDev/reventless-core/commit/17837a3fde52581a06516c69c80e6a1ea5689d9a))
* **dcb:** derive envelope id from command partition tag in makeGenerateCommand ([bf44d9e](https://github.com/ReventlessDev/reventless-core/commit/bf44d9e2da877200075efb40f35013417f6b6200))


# 3.0.0-alpha.66 (2026-05-03)

### Bug Fixes

* **core:** canonical pluralization for read model query field names ([71312a3](https://github.com/ReventlessDev/reventless-core/commit/71312a3554359057e05abd9881fe2689dc97e73a))
* **core:** exclude *Id / *Ids fields from labelField inference ([01b2944](https://github.com/ReventlessDev/reventless-core/commit/01b29440b2f32de44aa4ce1e63d12c08c0737bd1))


# 3.0.0-alpha.65 (2026-05-03)

### Bug Fixes

* **tests:** drop redundant ReventlessCore prefix in Platform_UIDefinitionsApiTest ([4585564](https://github.com/ReventlessDev/reventless-core/commit/4585564a841642b72bacf72a4192167cb0a34ef9))
### Features

* **aws:** mirror Platform_UIDefinitions GraphQL query — Lambda DataSource backed by Plugin read model ([76e57cc](https://github.com/ReventlessDev/reventless-core/commit/76e57ccc681a66be4909bd94e131145978169c9c))


# 3.0.0-alpha.64 (2026-05-03)

### Bug Fixes

* **api:** wire deriveObjectSchema into Plugin_Structure queryable defs ([1a14ff6](https://github.com/ReventlessDev/reventless-core/commit/1a14ff6ad7652eb733a7197ef3b072fedf514f89))
* **automation-slice:** detach phase 2 from event-subscriber fiber ([ddaebfc](https://github.com/ReventlessDev/reventless-core/commit/ddaebfc2e13c3b0e9b3de1380ca4fa49c1c12630))
* **outbound-translation:** detach phase 2 from event-subscriber fiber ([ed1c10c](https://github.com/ReventlessDev/reventless-core/commit/ed1c10c9f0b42d7e0940274bd77f41da1f7de78d))
* **plugin:** silence false-positive own-DCB-eventlog warning + correct example Delegate.name ([df721b2](https://github.com/ReventlessDev/reventless-core/commit/df721b2ce716fd2952f80177999ca11798a08117))
* feat(ppx)!: add @@reventless.mappings/extension/task; collapse AutomationSlice.Make to 2 args ([c0268ac](https://github.com/ReventlessDev/reventless-core/commit/c0268ac42c1c887fe25467af61b412ab2e27a5a7))
### Features

* **admin:** emit AutomationSlice, InboundTranslation, and broader EventTypeMatch cross-plugin edges ([a3e16a9](https://github.com/ReventlessDev/reventless-core/commit/a3e16a958e76128f53c5e1e434220abc110e9fb7))
* **logger:** prefix plugin-component logs with stable-color [PluginName] bracket ([ed61eaf](https://github.com/ReventlessDev/reventless-core/commit/ed61eaf5cf84d8b8925c148050a2c51ddb65226a))

### BREAKING CHANGES

* Platform.AutomationSlice.Make is now 2-arg (Spec, Automation).
External callers must either rerun generate-plugin or merge their _Mappings
contents into _Automation (or add the same two-line bridge).

Verified: zero warnings, 1174/1175 tests pass — the single failing test
(OrderingE2ETest "after syncing missing product, PlaceOrder succeeds") was
confirmed pre-existing on alpha (the known testPromise concurrency race).



# 3.0.0-alpha.63 (2026-04-28)

### Bug Fixes

* **test:** polyfill globalThis.crypto for uuid v13 in Jest 27 VM context ([5bcdb96](https://github.com/ReventlessDev/reventless-core/commit/5bcdb967a23ae6488f2c89e565c98041880be96f))
### Features

* **api:** auto-derive Filter/OrderBy from state annotations ([320001f](https://github.com/ReventlessDev/reventless-core/commit/320001f69dfc1166974932014dcf85f872aaba62))
* **aws:** server-side filter/sort on connection list resolver ([baa3f4e](https://github.com/ReventlessDev/reventless-core/commit/baa3f4e7937ff14d8e6ad2b309dbae57a242cf47))
* **ppx:** add [@drill](https://github.com/drill)Target and [@collapsed](https://github.com/collapsed) rendering hints ([9de6499](https://github.com/ReventlessDev/reventless-core/commit/9de6499a458a1a29f51f67df03b607bdb46c707c))
* **ppx:** add [@hidden](https://github.com/hidden) and [@summary](https://github.com/summary) visibility annotations ([f26b05c](https://github.com/ReventlessDev/reventless-core/commit/f26b05cd561f1a879ed74135a3446f1faf29ad21))
* **ppx:** add [@scan](https://github.com/scan) and [@scan](https://github.com/scan)Sort opt-in for server-side filter/sort ([534a4bf](https://github.com/ReventlessDev/reventless-core/commit/534a4bf2116ec6f597f87dadc785767c3dc54ace))
* **ppx:** propagate state annotations to JSON Schema as x-reventless-* properties ([5ce39e4](https://github.com/ReventlessDev/reventless-core/commit/5ce39e4d22dca7d5ae3577b6210e40dd81cef4f5))


# 3.0.0-alpha.62 (2026-04-27)

### Bug Fixes

* **in-memory:** resolve extension wirings via Output chain and use firePlatformDeployedHook ([3037fc7](https://github.com/ReventlessDev/reventless-core/commit/3037fc7af05574163873eefdb227b5421118c323))


# 3.0.0-alpha.61 (2026-04-26)

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



# 3.0.0-alpha.60 (2026-04-24)

**Note:** Version bump only for package @reventlessdev/reventless-core





# 3.0.0-alpha.59 (2026-04-24)

### Bug Fixes

* **dcb:** guard hasDcb on StateChangeSlices only — prevent crash when admin has stateViewSlices but no producers ([198f14a](https://github.com/ReventlessDev/reventless-core/commit/198f14ae4b75a01ac7d10b77cd4d7c3a48f4e7b0))
* **deps:** add uuid as direct dependency of reventless-core ([87bf8cc](https://github.com/ReventlessDev/reventless-core/commit/87bf8cca3b8ee8637a27567f77017ee3103bf445))
### Features

* **admin:** convert PlatformEventGraph from StateViewSlice to ReadModel ([df5746b](https://github.com/ReventlessDev/reventless-core/commit/df5746bbb419833361c2fb47ed607e2ab85ced47))
* **gwt:** extract GWT test DSLs into @reventlessdev/reventless-gwt package ([dd64b4e](https://github.com/ReventlessDev/reventless-core/commit/dd64b4e1fd0bb203821d055b6743a52aec1836fb))
* **gwt:** silence CLI logs by default; add vscode testing guide ([9f124da](https://github.com/ReventlessDev/reventless-core/commit/9f124dac32a408ca88011d9b15e4de6bde624c74))


# 3.0.0-alpha.58 (2026-04-22)

### Bug Fixes

* **core:** correct plugin structure graph and dcb event publishing ([a61a9d0](https://github.com/ReventlessDev/reventless-core/commit/a61a9d024cffdf36faafc6bec8b8c04221ca3db2))
* **core:** suppress Plugin_Callback log for unhandled events ([8df817d](https://github.com/ReventlessDev/reventless-core/commit/8df817d79fa24ea0c0229cfd3c11b0cded9b8280))
* **infra:** harmonize extension and extension-point logging ([ba01793](https://github.com/ReventlessDev/reventless-core/commit/ba0179311c4a5ac66dfa960ed819b1c70492549f))
* preserve ANSI codes in EffectLogger Array message branch ([d1444b6](https://github.com/ReventlessDev/reventless-core/commit/d1444b666595e9bf5f43d75f6fae47434c6ef7b6))
* wire DCB cross-plugin event routing and AutoUI command linking ([8baabad](https://github.com/ReventlessDev/reventless-core/commit/8baabad8bce02ab0954a0eeefffb4cf5f448e1e7))
### Features

* add composite [@display](https://github.com/display)Name annotation with projected displayName column ([115f550](https://github.com/ReventlessDev/reventless-core/commit/115f5506231f635e261d977da0ca32bdabef817f))
* **api:** type *Id/*Ids fields as ID in GraphQL schema by naming convention ([9d5f6c4](https://github.com/ReventlessDev/reventless-core/commit/9d5f6c489a60a4b1108bdc7cb824f8f2d56d644a))
* **build:** migrate from npm to pnpm (hoisted layout) ([1de8b77](https://github.com/ReventlessDev/reventless-core/commit/1de8b7753b8f45c63ea3c8d9f64de2f27febd029))
* expose sourceNames on ReadModel.T for aggregate-to-read-model linking ([379f344](https://github.com/ReventlessDev/reventless-core/commit/379f3445cfd5d18b5d439dd9c6f3bd7d86bdc3d5))
* **logs:** bold event and command names in log output ([3b09f41](https://github.com/ReventlessDev/reventless-core/commit/3b09f41299bc1f851e15cfb7b8c4a8433f499c7d))
* **spec:** add Message.variantNameOfJson helper ([a9efb5f](https://github.com/ReventlessDev/reventless-core/commit/a9efb5f1d3ac6180ea8e04dc3c1c2f183d15a984))
* surface labelField and searchableFields on Platform_UIReadSideDef ([fb7bff8](https://github.com/ReventlessDev/reventless-core/commit/fb7bff8f6fca51c2ed9261adbfedec0f45777d59))


# 3.0.0-alpha.57 (2026-04-20)

### Bug Fixes

* **aws:** Source B push chain end-to-end ([d2b5cef](https://github.com/ReventlessDev/reventless-core/commit/d2b5cef2ff1dde197879461551e71d04e91962ac))
### Features

* add automationSlices, translation slices, and extensions to pluginStructure ([631e2f3](https://github.com/ReventlessDev/reventless-core/commit/631e2f3636f0a422e58712f70106c0df8effc1e9))
* cross-plugin edge assembly for Platform_EventGraph via query-time resolver ([6a2ba2b](https://github.com/ReventlessDev/reventless-core/commit/6a2ba2bccd7207dfccb81aec4b2c90e43c866f4d))
* enrich MCP tool descriptions with linkedViews and consistencyRead from pluginStructure ([221aad4](https://github.com/ReventlessDev/reventless-core/commit/221aad40ae096d01a066d955be397bb29fc18c59))
* Platform_EventGraph StateViewSlice aggregating cross-plugin event graph ([718f0be](https://github.com/ReventlessDev/reventless-core/commit/718f0bed258da62c4ff5f2ab188e2d43b85e91b6))
* **plugin-structure:** add mutationField to commandDef ([80f2c8d](https://github.com/ReventlessDev/reventless-core/commit/80f2c8db6a61a705f8b05cb7429187a4b69ccf37))


# 3.0.0-alpha.56 (2026-04-19)

### Dependency Updates

* **@reventlessdev/reventless-infra** updated to `^3.0.0-alpha.38`
* **@reventlessdev/reventless-spec** updated to `^3.0.0-alpha.29`


# 3.0.0-alpha.55 (2026-04-18)

### Features

* **core:** AutoUI definition — makeAutoUIDefinition, Platform_UIDefinitions query, generator support ([513ca53](https://github.com/ReventlessDev/reventless-core/commit/513ca5399b0b6e5ae6a982fd15693de2ea208b8d))
* **core:** UI fragment registry — Phases 2–4 (lifecycle events, read model, subscription) ([ad62d0e](https://github.com/ReventlessDev/reventless-core/commit/ad62d0e1ae820f8fe4c2066b59db5363e6ca33a1))
* **core:** uiFragments manifest — Phase 1 implementation with generic types ([1e73f62](https://github.com/ReventlessDev/reventless-core/commit/1e73f623984118081d2b985c48521812e4f8417e))


# 3.0.0-alpha.54 (2026-04-18)

### Bug Fixes

* **subscriptions:** [@aws](https://github.com/aws)_subscribe injected into arg list when command has String! args ([b592b48](https://github.com/ReventlessDev/reventless-core/commit/b592b483d791387cbc73ba4e1779af3095512b25))
* **subscriptions:** limit Source C subscription args to one to stay within AppSync 5-arg cap ([d945548](https://github.com/ReventlessDev/reventless-core/commit/d9455482bca450f79fc719e75c05d5434a3fb8d6))
### Features

* **aws:** enable Source B state-change subscriptions (DynamoDB Stream → AppSync Events) ([960b203](https://github.com/ReventlessDev/reventless-core/commit/960b2035d843c2b97cf2014b05fb1a4f132e9984))


# 3.0.0-alpha.53 (2026-04-16)

### Bug Fixes

* **core:** extract resolver error hook to keep runtime free of Pulumi ([aa82c95](https://github.com/ReventlessDev/reventless-core/commit/aa82c95710a185847d6eef3298dd45d451862d3c))
* **graphql:** emit input types for nested mutation args; pass dataSourceName on subs ([9dc7107](https://github.com/ReventlessDev/reventless-core/commit/9dc7107328327470396cfe6e1e775846fee98992))


# 3.0.0-alpha.52 (2026-04-16)

### Bug Fixes

* **tests:** fix CommandGeneratorCallback test suite and update DCB tag assertion ([539419c](https://github.com/ReventlessDev/reventless-core/commit/539419ca1bd3e9ab12342415e6dd0bd0899b9928))
### Features

* **plugin-hooks:** implement Groups A-E of plugin-hook-metadata-and-schema-extensions ([4e95782](https://github.com/ReventlessDev/reventless-core/commit/4e957824d31666643a357873cba0403d52dd80b4))
* **subscriptions:** implement GraphQL subscriptions across AWS + in-memory ([a25a3b8](https://github.com/ReventlessDev/reventless-core/commit/a25a3b8928a465b7ba8de7b06e44425e206a1fcd))


# 3.0.0-alpha.51 (2026-04-16)

### Bug Fixes

* **graphql:** include subId field as required arg in single-item query schema ([cc1a924](https://github.com/ReventlessDev/reventless-core/commit/cc1a9249deb8d89d24db2d3e05dd0adf5698822c))


# 3.0.0-alpha.50 (2026-04-15)

### Bug Fixes

* **schema:** make pluginDefinition.apiTarget JSON-safe for union variant payloads ([556457f](https://github.com/ReventlessDev/reventless-core/commit/556457fd2f09f3ae572fc18aefb3262d80582524))


# 3.0.0-alpha.49 (2026-04-15)

### Bug Fixes

* **platform:** split-API schema routing for Platform-target plugins ([6b4c58d](https://github.com/ReventlessDev/reventless-core/commit/6b4c58dfed15c40db0e70339f0148ff445eb5c6a))


# 3.0.0-alpha.48 (2026-04-15)

### Bug Fixes

* make onPluginDeployedHook async so Pulumi blocks on hook Promise ([b79def0](https://github.com/ReventlessDev/reventless-core/commit/b79def025dae4542f8c5c63b84e1b68999511ff6))


# 3.0.0-alpha.47 (2026-04-13)

### Bug Fixes

* **aws:** route slice builder resolvers to correct API target ([7485159](https://github.com/ReventlessDev/reventless-core/commit/7485159f415d4720dd4e567d2ffef1335db432e6))
### Features

* **api:** generate By{Index} query fields in SDL for GSI resolvers ([46681b3](https://github.com/ReventlessDev/reventless-core/commit/46681b3ecf2877a1cb6b8459547e014cba0c1f41))


# 3.0.0-alpha.46 (2026-04-12)

### Bug Fixes

* **dcb:** enable id param for StateViewSlice singular queries ([3ed7ca9](https://github.com/ReventlessDev/reventless-core/commit/3ed7ca963e3c2d82ae50598f92a4292a6b2b5eb6))
### Features

* **api:** replace ByIdConnection with Relay-compatible Items query ([1bb7a8d](https://github.com/ReventlessDev/reventless-core/commit/1bb7a8d9e10b2db76714c61f9418cc55fd7ec2ae))
* **commands:** end-to-end CommandResult — synchronous business-rule errors reach the GraphQL client ([c241d74](https://github.com/ReventlessDev/reventless-core/commit/c241d7418205799bdc79472ebbd04f40b392f870))
* **commands:** extend CommandAccepted with entityId and eventCount ([747b85d](https://github.com/ReventlessDev/reventless-core/commit/747b85dc50042124f360627c5489321eea0d26e4))
* **platform:** MakeAsync opt-in for aggregates and DCB slices ([6970d88](https://github.com/ReventlessDev/reventless-core/commit/6970d889fa05e738dbda5d8e450a1dcf927b23b7))
* **platform:** rename admin fields to Platform_ prefix, fix dual-API registration ([95f011a](https://github.com/ReventlessDev/reventless-core/commit/95f011a8617b78d5c876f8e14a3ba5e0595d1cee))


# 3.0.0-alpha.45 (2026-04-11)

### Dependency Updates

* **@reventlessdev/reventless-infra** updated to `^3.0.0-alpha.30`


# 3.0.0-alpha.44 (2026-04-10)

### Features

* **aws:** implement dual-API architecture (Phases 1–3) ([9e11efc](https://github.com/ReventlessDev/reventless-core/commit/9e11efc21bb012552fbe1c1b510664d372f84b96))


# 3.0.0-alpha.43 (2026-04-09)

### Features

* **platform:** add apiEndpoint to platformDeployedInfo, extract Plugin_BuiltHook ([d53cfc5](https://github.com/ReventlessDev/reventless-core/commit/d53cfc5bd33671d2ca539b4eeb45bbaa7b3979e3))


# 3.0.0-alpha.42 (2026-04-09)

### Bug Fixes

* **inbound-translation:** serialize audit row input as JSON string ([e4d5485](https://github.com/ReventlessDev/reventless-core/commit/e4d5485e8af484617036c981fbebca2d40a96f28))
### Features

* **ppx:** implement [@no](https://github.com/no)Api to exclude commands from GraphQL/MCP exposure ([079b686](https://github.com/ReventlessDev/reventless-core/commit/079b68693976a53f8094f1233ebf8b67a86a65c0))


# 3.0.0-alpha.41 (2026-04-07)

### Dependency Updates

* **@reventlessdev/reventless-infra** updated to `^3.0.0-alpha.28`
* **@reventlessdev/reventless-spec** updated to `^3.0.0-alpha.23`


# 3.0.0-alpha.40 (2026-04-07)

### Features

* **ppx+querydb:** annotation-driven key design and sort key queries ([dee6de8](https://github.com/ReventlessDev/reventless-core/commit/dee6de84c2d2de5431d064f18ac7132bc8c23110))


# 3.0.0-alpha.39 (2026-04-07)

### Bug Fixes

* replace S.reverseConvertToJsonOrThrow with JSON.stringifyAny round-trip ([406acee](https://github.com/ReventlessDev/reventless-core/commit/406acee7bf98eb517419db23791b8ecb3668ada7))


# 3.0.0-alpha.38 (2026-04-06)

### Bug Fixes

* add package-specs to all rescript.json to prevent CJS .js output ([780f1e0](https://github.com/ReventlessDev/reventless-core/commit/780f1e035173b73b17b78466ad01fb69c7cca350))
* **api:** treat sury Undefined as nullable in SDL schema type derivation ([fda88aa](https://github.com/ReventlessDev/reventless-core/commit/fda88aaf6c047d3a3dd0bd20cb85f3f34be6aadc))


# 3.0.0-alpha.37 (2026-04-06)

### Bug Fixes

* DCB runtime — empty tags fallback, tag_composite GSI, stream meta ([4c3a6ad](https://github.com/ReventlessDev/reventless-core/commit/4c3a6ad9f0e1a9fa357a7230d7151ba34a0c116b))
* wire DCB EventCollector and StateViewSlice Lambda pipeline ([846228f](https://github.com/ReventlessDev/reventless-core/commit/846228fc9193a4c344399ecae924241e7944204f))
### Features

* implement [@composite](https://github.com/composite)PartitionTag PPX annotation for multi-field DCB partition keys ([cf26b15](https://github.com/ReventlessDev/reventless-core/commit/cf26b15f639d151451c9aa04d32603ef9d5df315))


# 3.0.0-alpha.36 (2026-04-05)

### Bug Fixes

* DCB runtime — empty tags fallback, tag_composite GSI, stream meta ([4c3a6ad](https://github.com/ReventlessDev/reventless-core/commit/4c3a6ad9f0e1a9fa357a7230d7151ba34a0c116b))
* wire DCB EventCollector and StateViewSlice Lambda pipeline ([846228f](https://github.com/ReventlessDev/reventless-core/commit/846228fc9193a4c344399ecae924241e7944204f))


# 3.0.0-alpha.35 (2026-04-05)

### Bug Fixes

* DCB command pipeline runtime fixes ([9646c97](https://github.com/ReventlessDev/reventless-core/commit/9646c97e7fd86f28d5035d77ff40af66f592e61e))


# 3.0.0-alpha.34 (2026-04-04)

### Bug Fixes

* create AppSync resolvers for DCB QueryDbs and migrate to APPSYNC_JS runtime ([9fcf4f1](https://github.com/ReventlessDev/reventless-core/commit/9fcf4f10bc6c90d26f27ec309597b0fba9327c5a))
* DCB [@partition](https://github.com/partition)Tag runtime errors, GraphQL Node interface, and ESM config ([dc4c4e1](https://github.com/ReventlessDev/reventless-core/commit/dc4c4e10f1ef09aba840e7b359df453b122c6aa4))
* resolve all compiler warnings ([39803fe](https://github.com/ReventlessDev/reventless-core/commit/39803feb5cc3598c8616f16dbe8344712029b9a6))
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



# 3.0.0-alpha.33 (2026-04-03)

### Bug Fixes

* map empty Object schemas to Unknown in GraphQL SDL generation ([6fc5c19](https://github.com/ReventlessDev/reventless-core/commit/6fc5c192e7a92ee67634ddbccab7e4bc83caf76a))
* feat!: support multi-command returns in InboundTranslationSlice ([eaac621](https://github.com/ReventlessDev/reventless-core/commit/eaac6213829b876db508b6a98db081ee40dc3e95))

### BREAKING CHANGES

* All `translate` implementations must wrap returns in arrays.



# 3.0.0-alpha.32 (2026-04-02)

### Features

* add tags field to resource and resolvedResource records ([18911e6](https://github.com/ReventlessDev/reventless-core/commit/18911e66aa94e60d4a9b72ba1d1ca84dd3fb1a9f))


# 3.0.0-alpha.31 (2026-04-02)

* feat!: add deploy lifecycle hooks, enrich resource metadata, and add Adapter.make factory ([0a171f4](https://github.com/ReventlessDev/reventless-core/commit/0a171f4b8aec0ee47fd7ee5069adf5d5b194548e))

### BREAKING CHANGES

* Adapter.resource.info replaced with resourceInfo variant type.
Service field values now prefixed with provider namespace (e.g. "aws:DynamoDb").
New required fields on resource/resolvedResource: role, region, resourceType, configuration.



# 3.0.0-alpha.30 (2026-04-02)

### Features

* add onPluginBuilt callback hook for deploy-time plugin metadata observation ([fbbb336](https://github.com/ReventlessDev/reventless-core/commit/fbbb336143e4a35d20abf8a8fedb05e8b78fac0b))
* add register/clear API for callback hooks ([b5442a0](https://github.com/ReventlessDev/reventless-core/commit/b5442a0e3faec0f60ffcd3c33870862e5beded88))


# 3.0.0-alpha.29 (2026-03-31)

### Bug Fixes

* include summary prefix in legacy log format functions ([9bb4d4d](https://github.com/ReventlessDev/reventless-core/commit/9bb4d4de82fd2fedd470f5324a884c7d509a8807))
* migrate remaining Console.log calls to unified Logger/EffectLogger ([0216b0d](https://github.com/ReventlessDev/reventless-core/commit/0216b0dde5597b2bc539a960ac86a18071777815))


# 3.0.0-alpha.28 (2026-03-30)

### Features

* add event publish hooks and AWS query interceptor support ([5c4ec59](https://github.com/ReventlessDev/reventless-core/commit/5c4ec598f6cc7115255b4b18c9decf8007630f15))


# [3.0.0-alpha.27](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-core@3.0.0-alpha.26...@reventlessdev/reventless-core@3.0.0-alpha.27) (2026-03-30)

### Features

* unified logging with structured output, colored levels, and CloudWatch detail ([7754cf1](https://github.com/ReventlessDev/reventless-core/commit/7754cf11037b17fce01ab65c2c906d9faf7ac4b6))


# [3.0.0-alpha.26](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-core@3.0.0-alpha.25...@reventlessdev/reventless-core@3.0.0-alpha.26) (2026-03-29)

### Features

* add query interceptor hook to QueryDb pipeline ([40c7f7e](https://github.com/ReventlessDev/reventless-core/commit/40c7f7ea9bc004bfb58be8ab52136ddea9481083))


# [3.0.0-alpha.25](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-core@3.0.0-alpha.23...@reventlessdev/reventless-core@3.0.0-alpha.25) (2026-03-28)

* feat!: flatten DcbSpec module type into direct Plugin.make parameters ([1c0bc57](https://github.com/ReventlessDev/reventless-core/commit/1c0bc576fcd88b92510900c16f5f117e864d9d7f))
### Features

* add identity propagation and interceptor hook to CommandGenerator pipeline ([37494a5](https://github.com/ReventlessDev/reventless-core/commit/37494a50fe70f8db7d6d35fd733a4fc75eade5bc))

### BREAKING CHANGES

* Plugin.make no longer accepts ~dcbSpec=module(DcbSpec).
Pass slice arrays directly instead. Empty arrays can be omitted.



# [3.0.0-alpha.24](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-core@3.0.0-alpha.23...@reventlessdev/reventless-core@3.0.0-alpha.24) (2026-03-27)

* feat!: flatten DcbSpec module type into direct Plugin.make parameters ([1c0bc57](https://github.com/ReventlessDev/reventless-core/commit/1c0bc576fcd88b92510900c16f5f117e864d9d7f))

### BREAKING CHANGES

* Plugin.make no longer accepts ~dcbSpec=module(DcbSpec).
Pass slice arrays directly instead. Empty arrays can be omitted.



# [3.0.0-alpha.23](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-core@3.0.0-alpha.20...@reventlessdev/reventless-core@3.0.0-alpha.23) (2026-03-27)

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



# [3.0.0-alpha.22](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-core@3.0.0-alpha.20...@reventlessdev/reventless-core@3.0.0-alpha.22) (2026-03-26)

* feat!: add structured Identity type and expand RequestContext with identity and claims ([a2396d4](https://github.com/ReventlessDev/reventless-core/commit/a2396d4dd350bb07924d45b64b99b3dc969ced89))

### BREAKING CHANGES

* RequestContext.t now requires identity and claims fields.
Use RequestContext.test() for test contexts.



# [3.0.0-alpha.21](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-core@3.0.0-alpha.20...@reventlessdev/reventless-core@3.0.0-alpha.21) (2026-03-26)

* feat!: add structured Identity type and expand RequestContext with identity and claims ([a2396d4](https://github.com/ReventlessDev/reventless-core/commit/a2396d4dd350bb07924d45b64b99b3dc969ced89))

### BREAKING CHANGES

* RequestContext.t now requires identity and claims fields.
Use RequestContext.test() for test contexts.



# [3.0.0-alpha.20](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-core@3.0.0-alpha.19...@reventlessdev/reventless-core@3.0.0-alpha.20) (2026-03-23)

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
# [3.0.0-alpha.19](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-core@3.0.0-alpha.17...@reventlessdev/reventless-core@3.0.0-alpha.19) (2026-03-22)

### Bug Fixes

* **rescript-effect:** use deep imports to avoid loading effect barrel ([1823358](https://github.com/ReventlessDev/reventless-core/commit/18233588d3564d8b4d158b949e734cbb92720fcd))
* feat(reventless-aws)!: replace esbuild pipeline with compiled ReScript entry points ([6cb3133](https://github.com/ReventlessDev/reventless-core/commit/6cb313323c73a078d0922fa6b977466f61de74ea))

### BREAKING CHANGES

* esbuild removed from dependencies, `makeBundled` and
`makeBundledFromEntryPoint` removed from RuntimeEnvironment_Lambda,
`BundledEnvironment` module type removed from Runtime.
# [3.0.0-alpha.18](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-core@3.0.0-alpha.17...@reventlessdev/reventless-core@3.0.0-alpha.18) (2026-03-21)

### Bug Fixes

* **rescript-effect:** use deep imports to avoid loading effect barrel ([1823358](https://github.com/ReventlessDev/reventless-core/commit/18233588d3564d8b4d158b949e734cbb92720fcd))
# [3.0.0-alpha.17](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-core@3.0.0-alpha.16...@reventlessdev/reventless-core@3.0.0-alpha.17) (2026-03-20)

### Features

* **aws:** export platform component outputs and build admin Plugin aggregate/read model ([fabc069](https://github.com/ReventlessDev/reventless-core/commit/fabc069233dcf07c4eba8934868117bfe92ad59a))
* **aws:** implement bundled DCB CommandTopic, Heartbeat, and EP fix ([4ae72ec](https://github.com/ReventlessDev/reventless-core/commit/4ae72ec20d7ea1941e9b02dc7f06461c5fff06c4))
* **aws:** implement split API and fix bundled handler issues ([a3dfa79](https://github.com/ReventlessDev/reventless-core/commit/a3dfa79612eca4c4f57fabac7768f7bbda511eae))
* **aws:** replace CallbackFunction with bundled Lambda handlers ([6f6200b](https://github.com/ReventlessDev/reventless-core/commit/6f6200b0796e5f414493f50fd2f13dd6c7871ef4))
* **interop:** add component-level resolved output types and export plugin outputs from deployPlugin ([b502cbf](https://github.com/ReventlessDev/reventless-core/commit/b502cbf189f024f8bb3fd19a75bf5d76c7de2236))
# [3.0.0-alpha.16](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-core@3.0.0-alpha.15...@reventlessdev/reventless-core@3.0.0-alpha.16) (2026-03-17)

### Features

* **reventless-aws:** implement per-plugin deployment with runtime schema stitching ([f16714c](https://github.com/ReventlessDev/reventless-core/commit/f16714c5d2b3ad869863ac30dc55ef3e1570bf4f))
# [3.0.0-alpha.15](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-core@3.0.0-alpha.14...@reventlessdev/reventless-core@3.0.0-alpha.15) (2026-03-16)

* feat!: auto-detect plugin version from package.json via V8 stack trace ([e172673](https://github.com/ReventlessDev/reventless-core/commit/e17267390c197fa34052cef8325c579bb781419f))
* feat!: unify DCB and Aggregate command generation paths ([8c9bbad](https://github.com/ReventlessDev/reventless-core/commit/8c9bbad14082e7b696da35f5abb337520b1c8683))
* feat!: replace Core component with Platform_Admin, rename schema prefix Core_ → Admin_ ([940263d](https://github.com/ReventlessDev/reventless-core/commit/940263d8b39e28f4c874af3b0335ae81444928c4))
### Features

* differentiate ReadModel and StateViewSlice GraphQL query schemas ([62f6130](https://github.com/ReventlessDev/reventless-core/commit/62f6130d2ee34d65fe3eab1395d55c77c0309ddb))
* read version from package.json, make cloner opt-in, log platform version ([d8216a1](https://github.com/ReventlessDev/reventless-core/commit/d8216a1d569064ca14eff6e0c3be86923e5b84ad))

### BREAKING CHANGES

* Plugin.make no longer accepts ~version.

* DCB mutation return value changes from "ok" to a UUID.

* GraphQL/MCP field names change from Core_ to Admin_
prefix (e.g. Core_Plugin → Admin_Plugin). makePlatform no longer accepts
~extensionPoints, ~aggregates, ~readModels, ~dcbSpec parameters.
# [3.0.0-alpha.14](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-core@3.0.0-alpha.13...@reventlessdev/reventless-core@3.0.0-alpha.14) (2026-03-14)

### Bug Fixes

* eliminate Obj.magic from Platform DcbSpec boundaries ([135888b](https://github.com/ReventlessDev/reventless-core/commit/135888b226727d7ed8cc1e364e242b12071e107a))
### Features

* add optional DCB spec support to Core module and consolidate builder helpers ([06a5e6f](https://github.com/ReventlessDev/reventless-core/commit/06a5e6f2eeadbabd20fb7197318d760b91c34925))
* implement hybrid API/MCP schema split (core vs plugins) ([4f84866](https://github.com/ReventlessDev/reventless-core/commit/4f848667c0814533b2f3a294350c4310c61d9fc7))
# [3.0.0-alpha.13](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-core@3.0.0-alpha.12...@reventlessdev/reventless-core@3.0.0-alpha.13) (2026-03-12)

### Features

* capitalize and prefix Core_ on GraphQL/MCP queries and mutations ([769420b](https://github.com/ReventlessDev/reventless-core/commit/769420b47ce35aba46d248d1529f7c72c7df9c0e))
* unify schema generation pipeline across GraphQL and MCP protocols ([84e05ae](https://github.com/ReventlessDev/reventless-core/commit/84e05aeca8c13000040d1230502b07350ab5daeb))
# [3.0.0-alpha.12](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-core@3.0.0-alpha.11...@reventlessdev/reventless-core@3.0.0-alpha.12) (2026-03-12)

### Features

* **deps:** upgrade rescript to 12.2 and migrate Belt usages to stdlib ([eaa96ea](https://github.com/ReventlessDev/reventless-core/commit/eaa96ea61ca40d61573fb5fe2002a1f73d43ce3e))
# [3.0.0-alpha.11](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-core@3.0.0-alpha.9...@reventlessdev/reventless-core@3.0.0-alpha.11) (2026-03-08)

### Bug Fixes

* add aggregate instance ID parameter to MCP and GraphQL mutations ([7a83ca4](https://github.com/ReventlessDev/reventless-core/commit/7a83ca4e3140d7e25e2bf0c75ac515bde864198f))
* **graphql:** register DCB mutation resolvers and fix schema timing ([3e7da8d](https://github.com/ReventlessDev/reventless-core/commit/3e7da8df7efb20a0ff3dc7c82e10a807cb516182))
* remove 26 Obj.magic usages, improve type safety across codebase ([ebb8925](https://github.com/ReventlessDev/reventless-core/commit/ebb8925b760a0f070b1aaf3ef2d4bf3fdc7282a3))
* support payload-less variant serialization in splitMessage/combineMessage ([507badf](https://github.com/ReventlessDev/reventless-core/commit/507badf2f8755015fdc239b16e875529be734295))
### Features

* add AutomationSlice component (TODO list pattern) ([4642688](https://github.com/ReventlessDev/reventless-core/commit/46426884727aff74db33b9289feca9878b0e3ed9))
* add effect-based handlers with Effect service injection at dispatch ([7ab3b3e](https://github.com/ReventlessDev/reventless-core/commit/7ab3b3e8a48890f2248b113328914755f604c07e))
* add MCP event history resources and fix QueryDb/MCP resource bugs ([3197d4f](https://github.com/ReventlessDev/reventless-core/commit/3197d4fb52a7b20bc68cd3088d9d6fac21a41f6f))
* add MCP server layer for AI-native access to Reventless ([4b288bc](https://github.com/ReventlessDev/reventless-core/commit/4b288bce2fc17c28c32c6778028becb0cde4c544))
* add TranslationSlice components with docs and webhook backlog plan ([7362a8f](https://github.com/ReventlessDev/reventless-core/commit/7362a8f26bca2eaad9d99488ec597c426635659d))
* auto-generate GraphQL mutations for InboundTranslationSlice ([7011fd2](https://github.com/ReventlessDev/reventless-core/commit/7011fd29f3029f001aa94fa78eb4f6b34d45451e))
* **examples:** add example-dcb package with self-assembling DCB plugins ([889a072](https://github.com/ReventlessDev/reventless-core/commit/889a072492967439f9d4692ba9b58cf1bcb01c9d))
* fix GraphQL SDL generation — correct naming, typed returns, and aggregate mutations ([ac93318](https://github.com/ReventlessDev/reventless-core/commit/ac933182dcd238b5f02ed98d1ddf03bb52b2c109))
* **graphql:** add GRAPHQL_DEBUG mode, schema inspector, and debugging guide ([61fcbee](https://github.com/ReventlessDev/reventless-core/commit/61fcbee6ee68337e95b5934a14279420e8ab8eca))
* harmonize error handling and retry with Effect across all AWS adapters ([a817bde](https://github.com/ReventlessDev/reventless-core/commit/a817bde2fbbda314ebdbc69aee17de717ee059ed))
* make Logger injectable at Platform level and replace Console.log in runtime builders ([5c5dd5b](https://github.com/ReventlessDev/reventless-core/commit/5c5dd5bc07c14c13a9fc5d857d26387e14d06dd6))
* migrate logging to Effect built-in logger and provide RequestContext ([e9ec682](https://github.com/ReventlessDev/reventless-core/commit/e9ec6822ea924fc1561bfd886e4232cb5e2a8250))
* replace explicit queryMode with automatic schema-driven DCB query construction ([8df4350](https://github.com/ReventlessDev/reventless-core/commit/8df4350c37f1f15678f4796f229647eaeb3e8222))
* replace timestamp-based sequenceNr with integer sequence numbers and optimistic locking ([50b7d3e](https://github.com/ReventlessDev/reventless-core/commit/50b7d3e9901daafc6dff8c9492a789bc700e9099))
* restructure callbacks into pure Effect pipelines ([357865c](https://github.com/ReventlessDev/reventless-core/commit/357865c0fb46043e616fccbeef0b7c39add8217b))
# [3.0.0-alpha.10](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-core@3.0.0-alpha.9...@reventlessdev/reventless-core@3.0.0-alpha.10) (2026-03-08)

### Bug Fixes

* add aggregate instance ID parameter to MCP and GraphQL mutations ([7a83ca4](https://github.com/ReventlessDev/reventless-core/commit/7a83ca4e3140d7e25e2bf0c75ac515bde864198f))
* **graphql:** register DCB mutation resolvers and fix schema timing ([3e7da8d](https://github.com/ReventlessDev/reventless-core/commit/3e7da8df7efb20a0ff3dc7c82e10a807cb516182))
* remove 26 Obj.magic usages, improve type safety across codebase ([ebb8925](https://github.com/ReventlessDev/reventless-core/commit/ebb8925b760a0f070b1aaf3ef2d4bf3fdc7282a3))
* support payload-less variant serialization in splitMessage/combineMessage ([507badf](https://github.com/ReventlessDev/reventless-core/commit/507badf2f8755015fdc239b16e875529be734295))
### Features

* add AutomationSlice component (TODO list pattern) ([4642688](https://github.com/ReventlessDev/reventless-core/commit/46426884727aff74db33b9289feca9878b0e3ed9))
* add effect-based handlers with Effect service injection at dispatch ([7ab3b3e](https://github.com/ReventlessDev/reventless-core/commit/7ab3b3e8a48890f2248b113328914755f604c07e))
* add MCP event history resources and fix QueryDb/MCP resource bugs ([3197d4f](https://github.com/ReventlessDev/reventless-core/commit/3197d4fb52a7b20bc68cd3088d9d6fac21a41f6f))
* add MCP server layer for AI-native access to Reventless ([4b288bc](https://github.com/ReventlessDev/reventless-core/commit/4b288bce2fc17c28c32c6778028becb0cde4c544))
* add TranslationSlice components with docs and webhook backlog plan ([7362a8f](https://github.com/ReventlessDev/reventless-core/commit/7362a8f26bca2eaad9d99488ec597c426635659d))
* auto-generate GraphQL mutations for InboundTranslationSlice ([7011fd2](https://github.com/ReventlessDev/reventless-core/commit/7011fd29f3029f001aa94fa78eb4f6b34d45451e))
* **examples:** add example-dcb package with self-assembling DCB plugins ([889a072](https://github.com/ReventlessDev/reventless-core/commit/889a072492967439f9d4692ba9b58cf1bcb01c9d))
* fix GraphQL SDL generation — correct naming, typed returns, and aggregate mutations ([ac93318](https://github.com/ReventlessDev/reventless-core/commit/ac933182dcd238b5f02ed98d1ddf03bb52b2c109))
* **graphql:** add GRAPHQL_DEBUG mode, schema inspector, and debugging guide ([61fcbee](https://github.com/ReventlessDev/reventless-core/commit/61fcbee6ee68337e95b5934a14279420e8ab8eca))
* harmonize error handling and retry with Effect across all AWS adapters ([a817bde](https://github.com/ReventlessDev/reventless-core/commit/a817bde2fbbda314ebdbc69aee17de717ee059ed))
* make Logger injectable at Platform level and replace Console.log in runtime builders ([5c5dd5b](https://github.com/ReventlessDev/reventless-core/commit/5c5dd5bc07c14c13a9fc5d857d26387e14d06dd6))
* migrate logging to Effect built-in logger and provide RequestContext ([e9ec682](https://github.com/ReventlessDev/reventless-core/commit/e9ec6822ea924fc1561bfd886e4232cb5e2a8250))
* restructure callbacks into pure Effect pipelines ([357865c](https://github.com/ReventlessDev/reventless-core/commit/357865c0fb46043e616fccbeef0b7c39add8217b))
# [3.0.0-alpha.9](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-core@3.0.0-alpha.8...@reventlessdev/reventless-core@3.0.0-alpha.9) (2026-03-03)

### Features

* **api:** implement Api component with GraphQL fragment generation and schema stitching ([c882d3a](https://github.com/ReventlessDev/reventless-core/commit/c882d3aae8722cf6cbe9b4fbf9518d9f434ce06a))
* **platform:** expose Plugin, Core, makeScheduler, makePlatform via Platform.T ([0df4bf3](https://github.com/ReventlessDev/reventless-core/commit/0df4bf333ea4f9c0e51e96df1ad0da4ab471ffe8))
# [3.0.0-alpha.8](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-core@3.0.0-alpha.7...@reventlessdev/reventless-core@3.0.0-alpha.8) (2026-03-02)

**Note:** Version bump only for package @reventlessdev/reventless-core

# [3.0.0-alpha.7](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-core@3.0.0-alpha.6...@reventlessdev/reventless-core@3.0.0-alpha.7) (2026-03-02)

**Note:** Version bump only for package @reventlessdev/reventless-core

# 3.0.0-alpha.6 (2026-03-01)

* feat(reventless-spec)!: swap namespaces — spec→Reventless, core→ReventlessCore ([0fcf24e](https://github.com/ReventlessDev/reventless-core/commit/0fcf24e3fc1dcc88e9ee741dc99eb7bd726f9fd7))
* feat(reventless-core)!: rename package from @reventlessdev/reventless to @reventlessdev/reventless-core ([5e93146](https://github.com/ReventlessDev/reventless-core/commit/5e9314692b5b5d60beee187564ba94bc9fd46c05))
### Features

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
- reventless-aws and reventless-local dependency references updated
- Root package.json and rescript.json renamed to "reventless-monorepo" to
  avoid name collision that caused ReScript to skip building the sub-package
- Updated recompiled .res.mjs output files with new relative import paths
# [3.0.0-alpha.5](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless@3.0.0-alpha.4...@reventlessdev/reventless@3.0.0-alpha.5) (2026-02-18)

### Bug Fixes

* **dcb:** update js file and update uuid dependency ([b6e68e7](https://github.com/ReventlessDev/reventless-core/commit/b6e68e7c05d1c763ab2ccee3269e05c5362a82b6))
### Features

* add DCB (Dynamic Consistency Boundary) support ([be648da](https://github.com/ReventlessDev/reventless-core/commit/be648da2d8361285822f96f215bd07a39e41b261))
* **dcb:** add DynamoDB adapter with dynamic GSI generation ([820aa82](https://github.com/ReventlessDev/reventless-core/commit/820aa82e116774c77bf3abdb2228232e67cfa4c3))
* **dcb:** integrate DCB into Plugin component ([f44c2bf](https://github.com/ReventlessDev/reventless-core/commit/f44c2bf21d13a22c64e1b49829d04ebe34aece71))
* **dcb:** shared event log and schema-based command routing per plugin ([2464ae4](https://github.com/ReventlessDev/reventless-core/commit/2464ae41f589cc0a224de2f81e186091700d91ee))
* implement StateViewSlice component ([d9a9a99](https://github.com/ReventlessDev/reventless-core/commit/d9a9a996729405d0e282502571b4e8a148e9980c))
# [3.0.0-alpha.4](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless@3.0.0-alpha.3...@reventlessdev/reventless@3.0.0-alpha.4) (2026-02-14)

**Note:** Version bump only for package @reventlessdev/reventless

# [3.0.0-alpha.3](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless@3.0.0-alpha.2...@reventlessdev/reventless@3.0.0-alpha.3) (2026-02-13)

* refactor!: remove AWS dependencies from reventless core package ([bc2c4af](https://github.com/ReventlessDev/reventless-core/commit/bc2c4aff85af4f83b9d131584845260b060db647))

### BREAKING CHANGES

* Builder functions now require explicit resourceNaming and runtimeOps parameters
# [3.0.0-alpha.2](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless@3.0.0-alpha.1...@reventlessdev/reventless@3.0.0-alpha.2) (2026-02-12)
### Bug Fixes

* remove all ReScript compiler warnings across packages ([a943a21](https://github.com/ReventlessDev/reventless-core/commit/a943a2107aac1a2b27a72ffe3aab9bd15e61b6c0))

# [3.0.0-alpha.1](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless@3.0.0-alpha.0...@reventlessdev/reventless@3.0.0-alpha.1) (2026-02-12)
### Bug Fixes

* exclude private packages from versioning and automate doc CHANGELOG updates ([7581d78](https://github.com/ReventlessDev/reventless-core/commit/7581d78e9825fa6d837da8a136b361dee821660f))

# 3.0.0-alpha.0 (2026-02-12)
### Bug Fixes

* **logging:** correct index offsets in logger tag capture ([6d78858](https://github.com/ReventlessDev/reventless-core/commit/6d78858bfd87dc771ac386823448d3ada9a41d36))
* **publish:** add publishConfig to packages for GitHub Package Registry ([987a00a](https://github.com/ReventlessDev/reventless-core/commit/987a00af049fed112aa91fd53d8fad719cd80c94))
### Code Refactoring

* rename Behaviour to Behavior (British to American spelling) ([6575f44](https://github.com/ReventlessDev/reventless-core/commit/6575f4415fa0fb27472f3520038f158dd624da03))
### Reverts

* Revert "reventless: try to avoid race condition" ([0689fdd](https://github.com/ReventlessDev/reventless-core/commit/0689fdd2110d2504c7819304be6d8f0d702fb6a4))
* Revert "reventless: EventLog: try to fix deployment function serialization issue - desperate experiment #1" ([817db0e](https://github.com/ReventlessDev/reventless-core/commit/817db0e7e9e176eefe3a7d0fb889f50040602196)), closes [#1](https://github.com/ReventlessDev/reventless-core/issues/1)
* Revert "reventless & reventless-aws: add lambdas to component resources array (#101)" ([ee1e03f](https://github.com/ReventlessDev/reventless-core/commit/ee1e03fed9c95a055f22814f545e0046fc2fa044)), closes [#101](https://github.com/ReventlessDev/reventless-core/issues/101)
* Revert "reventless: remove Adapter.stackRefResourceToResource to avoid Pulumi import" ([0fb32a3](https://github.com/ReventlessDev/reventless-core/commit/0fb32a32fc64fe926a2100b04e3327acc9c29276))
* Revert "wrap Lambda.CallbackFunction param policies into Pulumi.Input" ([b023c23](https://github.com/ReventlessDev/reventless-core/commit/b023c23ef8f252b00796a062826daabd519f7cac))
* Revert "reventless: add func resource to CommandGenerator, CommandTopic, Counter, EventCollector adapters & add it to resources" ([b674889](https://github.com/ReventlessDev/reventless-core/commit/b6748893ff71df2c544e7d10a31e8f5644d49bf9))
* Revert "reventless: add func to outputs of CommandGenerator, CommandTopic, Counter, EventCollector" ([130da78](https://github.com/ReventlessDev/reventless-core/commit/130da78bf83ee5b95becbb682ba3ea3d61f5b2c4))
* Revert "reventless: CommandGenerator: uncomment setOutputs \" ([f22c886](https://github.com/ReventlessDev/reventless-core/commit/f22c886c95cd03d5ce905a804a115d1242732b27))
### BREAKING CHANGES

* All references to Behaviour module must be updated to Behavior
