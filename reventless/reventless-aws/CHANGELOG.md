# Change Log

All notable changes to this project will be documented in this file.
See [Conventional Commits](https://conventionalcommits.org) for commit guidelines.

# [3.0.0-alpha.5](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-aws@3.0.0-alpha.4...@reventlessdev/reventless-aws@3.0.0-alpha.5) (2026-02-18)

### Bug Fixes

* **dcb:** update js file and update uuid dependency ([b6e68e7](https://github.com/ReventlessDev/reventless-core/commit/b6e68e7c05d1c763ab2ccee3269e05c5362a82b6))
### Features

* **dcb:** add DynamoDB adapter with dynamic GSI generation ([820aa82](https://github.com/ReventlessDev/reventless-core/commit/820aa82e116774c77bf3abdb2228232e67cfa4c3))
* **dcb:** integrate DCB into Plugin component ([f44c2bf](https://github.com/ReventlessDev/reventless-core/commit/f44c2bf21d13a22c64e1b49829d04ebe34aece71))
* **dcb:** shared event log and schema-based command routing per plugin ([2464ae4](https://github.com/ReventlessDev/reventless-core/commit/2464ae41f589cc0a224de2f81e186091700d91ee))


# [3.0.0-alpha.4](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-aws@3.0.0-alpha.3...@reventlessdev/reventless-aws@3.0.0-alpha.4) (2026-02-14)

**Note:** Version bump only for package @reventlessdev/reventless-aws





# [3.0.0-alpha.3](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-aws@3.0.0-alpha.2...@reventlessdev/reventless-aws@3.0.0-alpha.3) (2026-02-13)

* refactor!: remove AWS dependencies from reventless core package ([bc2c4af](https://github.com/ReventlessDev/reventless-core/commit/bc2c4aff85af4f83b9d131584845260b060db647))

### BREAKING CHANGES

* Builder functions now require explicit resourceNaming and runtimeOps parameters

Co-Authored-By: Claude Sonnet 4.5 <noreply@anthropic.com>



# [3.0.0-alpha.2](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-aws@3.0.0-alpha.1...@reventlessdev/reventless-aws@3.0.0-alpha.2) (2026-02-12)


### Bug Fixes

* remove all ReScript compiler warnings across packages ([a943a21](https://github.com/ReventlessDev/reventless-core/commit/a943a2107aac1a2b27a72ffe3aab9bd15e61b6c0))





# [3.0.0-alpha.1](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-aws@3.0.0-alpha.0...@reventlessdev/reventless-aws@3.0.0-alpha.1) (2026-02-12)


### Bug Fixes

* exclude private packages from versioning and automate doc CHANGELOG updates ([7581d78](https://github.com/ReventlessDev/reventless-core/commit/7581d78e9825fa6d837da8a136b361dee821660f))





# 3.0.0-alpha.0 (2026-02-12)


### Bug Fixes

* **publish:** add publishConfig to packages for GitHub Package Registry ([987a00a](https://github.com/ReventlessDev/reventless-core/commit/987a00af049fed112aa91fd53d8fad719cd80c94))


### Code Refactoring

* rename Behaviour to Behavior (British to American spelling) ([6575f44](https://github.com/ReventlessDev/reventless-core/commit/6575f4415fa0fb27472f3520038f158dd624da03))


### Reverts

* Revert "reventless-aws: configure QueryEngine_DynamoDb to use ConsistentRead" ([9bd8457](https://github.com/ReventlessDev/reventless-core/commit/9bd84579973a5ff5cf0e3a8902dbd341c696c1fd))
* Revert "reventless & reventless-aws: add lambdas to component resources array (#101)" ([ee1e03f](https://github.com/ReventlessDev/reventless-core/commit/ee1e03fed9c95a055f22814f545e0046fc2fa044)), closes [#101](https://github.com/ReventlessDev/reventless-core/issues/101)
* Revert "wrap Lambda.CallbackFunction param policies into Pulumi.Input" ([b023c23](https://github.com/ReventlessDev/reventless-core/commit/b023c23ef8f252b00796a062826daabd519f7cac))
* Revert "reventless-aws: add func resource to CommandGenerator, CommandTopic, Counter, EventCollector adapters" ([2b287ba](https://github.com/ReventlessDev/reventless-core/commit/2b287ba446dabfa9d78c3bcd8de49abfea84b0ba))


### BREAKING CHANGES

* All references to Behaviour module must be updated to Behavior
