# Change Log

All notable changes to this project will be documented in this file.
See [Conventional Commits](https://conventionalcommits.org) for commit guidelines.

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
