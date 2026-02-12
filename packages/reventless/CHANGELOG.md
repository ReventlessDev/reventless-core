# Change Log

All notable changes to this project will be documented in this file.
See [Conventional Commits](https://conventionalcommits.org) for commit guidelines.

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
