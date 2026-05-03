# Change Log

All notable changes to this project will be documented in this file.
See [Conventional Commits](https://conventionalcommits.org) for commit guidelines.

# 2.4.0-alpha.23 (2026-05-03)

### Bug Fixes

* **appsync:** rewrite per-page sort to satisfy APPSYNC_JS 1.0.0 ([a285d2b](https://github.com/ReventlessDev/reventless-core/commit/a285d2b9f3da7cc4a30442969a23dfaad4ebca42))


# 2.4.0-alpha.22 (2026-05-03)

### Features

* **aws:** makeUiBundleDistribution uploads assets and supports SPA history fallback ([79ee054](https://github.com/ReventlessDev/reventless-core/commit/79ee054b78d2d0ecf91d5c87e888d8bb11e83067))


# 2.4.0-alpha.21 (2026-05-03)

### Bug Fixes

* **rescript-pulumi-aws:** inline jest config so pnpm -r test finds the suite ([9eb55eb](https://github.com/ReventlessDev/reventless-core/commit/9eb55eb81cf63ed4fa05b1108f69f5f41f55dc82))


# 2.4.0-alpha.20 (2026-04-28)

### Features

* **aws:** server-side filter/sort on connection list resolver ([baa3f4e](https://github.com/ReventlessDev/reventless-core/commit/baa3f4e7937ff14d8e6ad2b309dbae57a242cf47))


# 2.4.0-alpha.19 (2026-04-22)

### Features

* **build:** migrate from npm to pnpm (hoisted layout) ([1de8b77](https://github.com/ReventlessDev/reventless-core/commit/1de8b7753b8f45c63ea3c8d9f64de2f27febd029))


# 2.4.0-alpha.18 (2026-04-18)

### Features

* **core:** UI fragment registry — Phase 5 (CDN bundle hosting) ([949eba4](https://github.com/ReventlessDev/reventless-core/commit/949eba497139f705db1ce0b3993a4e0f051965b4))


# 2.4.0-alpha.17 (2026-04-17)

### Bug Fixes

* **rescript-pulumi-aws:** only add #sk to ExpressionAttributeNames when sort condition is used ([e95d1f7](https://github.com/ReventlessDev/reventless-core/commit/e95d1f7639f09c26631e325dd0f27350d03a4357))


# 2.4.0-alpha.16 (2026-04-16)

### Features

* **subscriptions:** implement GraphQL subscriptions across AWS + in-memory ([a25a3b8](https://github.com/ReventlessDev/reventless-core/commit/a25a3b8928a465b7ba8de7b06e44425e206a1fcd))


# 2.4.0-alpha.15 (2026-04-13)

### Dependency Updates

* **@reventlessdev/rescript-aws-sdk** updated to `^2.2.0-alpha.8`


# 2.4.0-alpha.14 (2026-04-13)

### Bug Fixes

* **aws:** correct API routing for DCB/inbound resolvers and AppSync JS runtime compat ([6ef9260](https://github.com/ReventlessDev/reventless-core/commit/6ef926087404a013b0c6e166fa35aa497a3b3050))
* **aws:** fall back to .github/layer-arn[-{stack}].txt when REVENTLESS_LAYER_ARN is unset ([98ba46a](https://github.com/ReventlessDev/reventless-core/commit/98ba46a28427b390d81380b069bcf1eec066c1a0))
### Features

* **api:** use aws-native AppSync Resolver to fix schema propagation race ([7009a65](https://github.com/ReventlessDev/reventless-core/commit/7009a65f115c1dd549c49cf33461537407fecbb6))


# 2.4.0-alpha.13 (2026-04-12)

### Features

* **api:** replace ByIdConnection with Relay-compatible Items query ([1bb7a8d](https://github.com/ReventlessDev/reventless-core/commit/1bb7a8d9e10b2db76714c61f9418cc55fd7ec2ae))


# 2.4.0-alpha.12 (2026-04-09)

### Bug Fixes

* **AppSync:** handle null ctx.result in listAllItemsConnection ([48ae647](https://github.com/ReventlessDev/reventless-core/commit/48ae6470c53896239295917a24ffd698ec79689c))


# 2.4.0-alpha.11 (2026-04-07)

### Features

* **ppx+querydb:** annotation-driven key design and sort key queries ([dee6de8](https://github.com/ReventlessDev/reventless-core/commit/dee6de84c2d2de5431d064f18ac7132bc8c23110))


# 2.4.0-alpha.10 (2026-04-06)

### Bug Fixes

* add package-specs to all rescript.json to prevent CJS .js output ([780f1e0](https://github.com/ReventlessDev/reventless-core/commit/780f1e035173b73b17b78466ad01fb69c7cca350))
* **aws:** safe claims access and GSI IAM permission for AppSync/Lambda ([f0d8324](https://github.com/ReventlessDev/reventless-core/commit/f0d8324693924314a90ad7c79d0837a923fc3197))


# 2.4.0-alpha.9 (2026-04-05)

### Bug Fixes

* DCB command pipeline runtime fixes ([9646c97](https://github.com/ReventlessDev/reventless-core/commit/9646c97e7fd86f28d5035d77ff40af66f592e61e))


# 2.4.0-alpha.8 (2026-04-04)

### Bug Fixes

* create AppSync resolvers for DCB QueryDbs and migrate to APPSYNC_JS runtime ([9fcf4f1](https://github.com/ReventlessDev/reventless-core/commit/9fcf4f10bc6c90d26f27ec309597b0fba9327c5a))
### Features

* add Relay server compliance to GraphQL API ([bd9245d](https://github.com/ReventlessDev/reventless-core/commit/bd9245da87023247643c5fa37cee21b0cde0f61e))


# 2.4.0-alpha.7 (2026-04-03)

### Features

* migrate AppSync resolvers from VTL to APPSYNC_JS runtime ([22f8c15](https://github.com/ReventlessDev/reventless-core/commit/22f8c15cee7d99859a56e5a6fbc11f9e9ff566c9))


# 2.4.0-alpha.6 (2026-04-02)

### Bug Fixes

* always set deleteBeforeReplace on AppSync Resolvers ([cb372ec](https://github.com/ReventlessDev/reventless-core/commit/cb372ec3a1eb793522264c001288a936dd2d0635))


# [2.4.0-alpha.5](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/rescript-pulumi-aws@2.4.0-alpha.2...@reventlessdev/rescript-pulumi-aws@2.4.0-alpha.5) (2026-03-27)

**Note:** Version bump only for package @reventlessdev/rescript-pulumi-aws





# [2.4.0-alpha.4](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/rescript-pulumi-aws@2.4.0-alpha.2...@reventlessdev/rescript-pulumi-aws@2.4.0-alpha.4) (2026-03-26)

**Note:** Version bump only for package @reventlessdev/rescript-pulumi-aws





# [2.4.0-alpha.3](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/rescript-pulumi-aws@2.4.0-alpha.2...@reventlessdev/rescript-pulumi-aws@2.4.0-alpha.3) (2026-03-26)

**Note:** Version bump only for package @reventlessdev/rescript-pulumi-aws





# [2.4.0-alpha.2](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/rescript-pulumi-aws@2.4.0-alpha.1...@reventlessdev/rescript-pulumi-aws@2.4.0-alpha.2) (2026-03-20)

### Bug Fixes

* **aws:** make Lambda bundling deterministic to prevent unnecessary redeploys ([049abcd](https://github.com/ReventlessDev/reventless-core/commit/049abcd07e1dd5bc7270a6dd376d57963a2ce841))
### Features

* **aws:** add Lambda FunctionUrl bindings and AWS split-api integration tests ([07c7cbe](https://github.com/ReventlessDev/reventless-core/commit/07c7cbeb688cfa8e48d92d7ff37738312493b00a))
* **aws:** replace CallbackFunction with bundled Lambda handlers ([6f6200b](https://github.com/ReventlessDev/reventless-core/commit/6f6200b0796e5f414493f50fd2f13dd6c7871ef4))
# [2.4.0-alpha.1](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/rescript-pulumi-aws@2.4.0-alpha.0...@reventlessdev/rescript-pulumi-aws@2.4.0-alpha.1) (2026-03-17)

**Note:** Version bump only for package @reventlessdev/rescript-pulumi-aws

# [2.4.0-alpha.0](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/rescript-pulumi-aws@2.3.1-alpha.7...@reventlessdev/rescript-pulumi-aws@2.4.0-alpha.0) (2026-03-12)

### Features

* **deps:** upgrade rescript to 12.2 and migrate Belt usages to stdlib ([eaa96ea](https://github.com/ReventlessDev/reventless-core/commit/eaa96ea61ca40d61573fb5fe2002a1f73d43ce3e))
## [2.3.1-alpha.7](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/rescript-pulumi-aws@2.3.1-alpha.6...@reventlessdev/rescript-pulumi-aws@2.3.1-alpha.7) (2026-03-08)

**Note:** Version bump only for package @reventlessdev/rescript-pulumi-aws

## [2.3.1-alpha.6](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/rescript-pulumi-aws@2.3.1-alpha.5...@reventlessdev/rescript-pulumi-aws@2.3.1-alpha.6) (2026-03-02)

### Bug Fixes

* **rescript:** stable .res.mjs output for all rescript binding packages ([6d8f8cb](https://github.com/ReventlessDev/reventless-core/commit/6d8f8cbd6ca5152a29bfe1a598a193e4c92549b1))
## [2.3.1-alpha.5](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/rescript-pulumi-aws@2.3.1-alpha.4...@reventlessdev/rescript-pulumi-aws@2.3.1-alpha.5) (2026-03-01)

**Note:** Version bump only for package @reventlessdev/rescript-pulumi-aws

## [2.3.1-alpha.4](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/rescript-pulumi-aws@2.3.1-alpha.3...@reventlessdev/rescript-pulumi-aws@2.3.1-alpha.4) (2026-02-14)

**Note:** Version bump only for package @reventlessdev/rescript-pulumi-aws

## [2.3.1-alpha.3](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/rescript-pulumi-aws@2.3.1-alpha.2...@reventlessdev/rescript-pulumi-aws@2.3.1-alpha.3) (2026-02-13)

**Note:** Version bump only for package @reventlessdev/rescript-pulumi-aws

## [2.3.1-alpha.2](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/rescript-pulumi-aws@2.3.1-alpha.1...@reventlessdev/rescript-pulumi-aws@2.3.1-alpha.2) (2026-02-12)

**Note:** Version bump only for package @reventlessdev/rescript-pulumi-aws

## [2.3.1-alpha.1](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/rescript-pulumi-aws@2.3.1-alpha.0...@reventlessdev/rescript-pulumi-aws@2.3.1-alpha.1) (2026-02-12)
### Bug Fixes

* exclude private packages from versioning and automate doc CHANGELOG updates ([7581d78](https://github.com/ReventlessDev/reventless-core/commit/7581d78e9825fa6d837da8a136b361dee821660f))

## 2.3.1-alpha.0 (2026-02-12)
### Bug Fixes

* **publish:** add publishConfig to packages for GitHub Package Registry ([987a00a](https://github.com/ReventlessDev/reventless-core/commit/987a00af049fed112aa91fd53d8fad719cd80c94))
