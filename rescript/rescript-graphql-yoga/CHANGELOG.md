# Change Log

All notable changes to this project will be documented in this file.
See [Conventional Commits](https://conventionalcommits.org) for commit guidelines.

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
