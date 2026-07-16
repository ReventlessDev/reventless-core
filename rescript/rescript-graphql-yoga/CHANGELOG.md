# Change Log

All notable changes to this project will be documented in this file.
See [Conventional Commits](https://conventionalcommits.org) for commit guidelines.

# 1.0.0-alpha.23 (2026-07-16)

**Note:** Version bump only for package @reventlessdev/rescript-graphql-yoga





# 1.0.0-alpha.22 (2026-07-14)

### Features

* surface masked GraphQL resolver errors server-side (local + AWS) ([b3bca51](https://github.com/ReventlessDev/reventless-core/commit/b3bca51b539e40c604b3db338d570de6215ea837))


# 1.0.0-alpha.21 (2026-07-14)

### Features

* **local:** plugin=subgraph composition — per-plugin subschemas merged at start (Phase 6, plan complete) ([40f44c5](https://github.com/ReventlessDev/reventless-core/commit/40f44c5c6aa32fbbd64f362841cf41ba4e2fc2e0))


# 1.0.0-alpha.20 (2026-07-11)

**Note:** Version bump only for package @reventlessdev/rescript-graphql-yoga





# 1.0.0-alpha.19 (2026-07-11)

### Features

* **graphql-server:** promote reusable GraphQL server runtime into shared package ([53dd0d5](https://github.com/ReventlessDev/reventless-core/commit/53dd0d54585dcc10d75322a76050aa8c06cec4fb))


# 1.0.0-alpha.18 (2026-07-06)

### Features

* **reventless-aws:** classic EventLog Postgres deploy-time wiring + relay (B1 vertical) ([8235ba4](https://github.com/ReventlessDev/reventless-core/commit/8235ba44e506f7094d17251405c6a05c39789805))


# 1.0.0-alpha.17 (2026-06-27)

**Note:** Version bump only for package @reventlessdev/rescript-graphql-yoga





# 1.0.0-alpha.16 (2026-06-20)

### Bug Fixes

* **packaging:** publish rescript packages source-only via .npmignore ([e831c37](https://github.com/ReventlessDev/reventless-core/commit/e831c372b6347d997da1e876c12b6770414f5f41))


# 1.0.0-alpha.15 (2026-06-10)

* refactor(reventless-local)!: rename reventless-in-memory to reventless-local ([f36e17c](https://github.com/ReventlessDev/reventless-core/commit/f36e17c407714ab9740393fac96865d6a5c143c9))

### BREAKING CHANGES

* @reventlessdev/reventless-in-memory -> @reventlessdev/reventless-local;
namespace ReventlessInMemory -> ReventlessLocal.



# 1.0.0-alpha.14 (2026-06-06)

* refactor(reventless-local)!: rename reventless-in-memory to reventless-local ([966855f](https://github.com/ReventlessDev/reventless-core/commit/966855fd31e518d56a381bf40204735809cead15))

### BREAKING CHANGES

* @reventlessdev/reventless-in-memory -> @reventlessdev/reventless-local;
namespace ReventlessInMemory -> ReventlessLocal.



# 1.0.0-alpha.13 (2026-06-04)

**Note:** Version bump only for package @reventlessdev/rescript-graphql-yoga





# 1.0.0-alpha.12 (2026-05-25)

**Note:** Version bump only for package @reventlessdev/rescript-graphql-yoga





# 1.0.0-alpha.11 (2026-05-14)

### Features

* **auth:** in-memory Auth provider + graphql-yoga context factory ([fe70052](https://github.com/ReventlessDev/reventless-core/commit/fe7005204d7a4328b25e9371b3d342a7000be570))


# 1.0.0-alpha.10 (2026-04-22)

### Features

* **build:** migrate from npm to pnpm (hoisted layout) ([1de8b77](https://github.com/ReventlessDev/reventless-core/commit/1de8b7753b8f45c63ea3c8d9f64de2f27febd029))


# 1.0.0-alpha.9 (2026-04-16)

### Features

* **subscriptions:** implement GraphQL subscriptions across AWS + in-memory ([a25a3b8](https://github.com/ReventlessDev/reventless-core/commit/a25a3b8928a465b7ba8de7b06e44425e206a1fcd))


# 1.0.0-alpha.8 (2026-04-06)

### Bug Fixes

* add package-specs to all rescript.json to prevent CJS .js output ([780f1e0](https://github.com/ReventlessDev/reventless-core/commit/780f1e035173b73b17b78466ad01fb69c7cca350))


# [1.0.0-alpha.7](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/rescript-graphql-yoga@1.0.0-alpha.4...@reventlessdev/rescript-graphql-yoga@1.0.0-alpha.7) (2026-03-27)

* feat!: decouple DCB slices from shared event log union type ([2a40e8d](https://github.com/ReventlessDev/reventless-core/commit/2a40e8dd9babfb88440fcaccde6fb667b60e0ba9))
* feat!: add structured Identity type and expand RequestContext with identity and claims ([a2396d4](https://github.com/ReventlessDev/reventless-core/commit/a2396d4dd350bb07924d45b64b99b3dc969ced89))

### BREAKING CHANGES

* All DCB slice specs must use `producedEvent`/`consumedEvent`
instead of `module DcbEventLogSpec`. Plugin `DcbSpec` no longer has `type event`
or `with type dcbEvent` constraints.
* RequestContext.t now requires identity and claims fields.
Use RequestContext.test() for test contexts.



# [1.0.0-alpha.6](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/rescript-graphql-yoga@1.0.0-alpha.4...@reventlessdev/rescript-graphql-yoga@1.0.0-alpha.6) (2026-03-26)

* feat!: add structured Identity type and expand RequestContext with identity and claims ([a2396d4](https://github.com/ReventlessDev/reventless-core/commit/a2396d4dd350bb07924d45b64b99b3dc969ced89))

### BREAKING CHANGES

* RequestContext.t now requires identity and claims fields.
Use RequestContext.test() for test contexts.



# [1.0.0-alpha.5](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/rescript-graphql-yoga@1.0.0-alpha.4...@reventlessdev/rescript-graphql-yoga@1.0.0-alpha.5) (2026-03-26)

* feat!: add structured Identity type and expand RequestContext with identity and claims ([a2396d4](https://github.com/ReventlessDev/reventless-core/commit/a2396d4dd350bb07924d45b64b99b3dc969ced89))

### BREAKING CHANGES

* RequestContext.t now requires identity and claims fields.
Use RequestContext.test() for test contexts.



# [1.0.0-alpha.4](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/rescript-graphql-yoga@1.0.0-alpha.2...@reventlessdev/rescript-graphql-yoga@1.0.0-alpha.4) (2026-03-12)

### Bug Fixes

* **deps:** deduplicate graphql package to resolve schema conflict ([c33b030](https://github.com/ReventlessDev/reventless-core/commit/c33b030c14993e27700c5f0ec44a8a6ebe582468))
### Features

* **deps:** upgrade rescript to 12.2 and migrate Belt usages to stdlib ([eaa96ea](https://github.com/ReventlessDev/reventless-core/commit/eaa96ea61ca40d61573fb5fe2002a1f73d43ce3e))
* **graphql:** add GRAPHQL_DEBUG mode, schema inspector, and debugging guide ([61fcbee](https://github.com/ReventlessDev/reventless-core/commit/61fcbee6ee68337e95b5934a14279420e8ab8eca))
# [1.0.0-alpha.3](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/rescript-graphql-yoga@1.0.0-alpha.2...@reventlessdev/rescript-graphql-yoga@1.0.0-alpha.3) (2026-03-08)

### Bug Fixes

* **deps:** deduplicate graphql package to resolve schema conflict ([c33b030](https://github.com/ReventlessDev/reventless-core/commit/c33b030c14993e27700c5f0ec44a8a6ebe582468))
### Features

* **graphql:** add GRAPHQL_DEBUG mode, schema inspector, and debugging guide ([61fcbee](https://github.com/ReventlessDev/reventless-core/commit/61fcbee6ee68337e95b5934a14279420e8ab8eca))
# [1.0.0-alpha.2](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/rescript-graphql-yoga@1.0.0-alpha.1...@reventlessdev/rescript-graphql-yoga@1.0.0-alpha.2) (2026-03-02)

### Bug Fixes

* **rescript:** stable .res.mjs output for all rescript binding packages ([6d8f8cb](https://github.com/ReventlessDev/reventless-core/commit/6d8f8cbd6ca5152a29bfe1a598a193e4c92549b1))
# 1.0.0-alpha.1 (2026-03-01)

### Features

* **in-memory:** implement P0 GraphQL server for mutations and queries ([2627cdc](https://github.com/ReventlessDev/reventless-core/commit/2627cdc147b2deeb160e9642750bf26da8f95108))
* **rescript:** add rescript-graphql-yoga bindings package ([8e7532a](https://github.com/ReventlessDev/reventless-core/commit/8e7532a6c77a83cddf35873e52fb2d52c05d942e))
