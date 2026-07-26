# Change Log

All notable changes to this project will be documented in this file.
See [Conventional Commits](https://conventionalcommits.org) for commit guidelines.

# 3.0.0-alpha.25 (2026-07-26)

**Note:** Version bump only for package @reventlessdev/reventless-layer-builder





# 3.0.0-alpha.24 (2026-07-17)

**Note:** Version bump only for package @reventlessdev/reventless-layer-builder





# 3.0.0-alpha.23 (2026-07-16)

**Note:** Version bump only for package @reventlessdev/reventless-layer-builder





# 3.0.0-alpha.22 (2026-07-11)

**Note:** Version bump only for package @reventlessdev/reventless-layer-builder





# 3.0.0-alpha.21 (2026-07-06)

**Note:** Version bump only for package @reventlessdev/reventless-layer-builder





# 3.0.0-alpha.20 (2026-07-03)

**Note:** Version bump only for package @reventlessdev/reventless-layer-builder





# 3.0.0-alpha.19 (2026-07-02)

### Bug Fixes

* **spec,interop,layer-builder:** generator/protocol/build failure modes (plan A8,A9) ([66d7a54](https://github.com/ReventlessDev/reventless-core/commit/66d7a54e3a0afdbfe3ea2975f517d1d64d52c180))


# 3.0.0-alpha.18 (2026-06-27)

### Bug Fixes

* **layer-builder:** retry npmjs registry reads through CDN propagation lag ([4117a3b](https://github.com/ReventlessDev/reventless-core/commit/4117a3bc2f77fe4a863b8c7811dbc4452d722f2b))


# 3.0.0-alpha.17 (2026-06-27)

**Note:** Version bump only for package @reventlessdev/reventless-layer-builder





# 3.0.0-alpha.16 (2026-06-10)

**Note:** Version bump only for package @reventlessdev/reventless-layer-builder





# 3.0.0-alpha.15 (2026-06-06)

**Note:** Version bump only for package @reventlessdev/reventless-layer-builder





# 3.0.0-alpha.14 (2026-05-25)

**Note:** Version bump only for package @reventlessdev/reventless-layer-builder





# 3.0.0-alpha.13 (2026-05-25)

**Note:** Version bump only for package @reventlessdev/reventless-layer-builder





# 3.0.0-alpha.12 (2026-05-14)

**Note:** Version bump only for package @reventlessdev/reventless-layer-builder





# 3.0.0-alpha.11 (2026-04-06)

### Bug Fixes

* add package-specs to all rescript.json to prevent CJS .js output ([780f1e0](https://github.com/ReventlessDev/reventless-core/commit/780f1e035173b73b17b78466ad01fb69c7cca350))


# 3.0.0-alpha.10 (2026-04-06)

### Bug Fixes

* wire DCB EventCollector and StateViewSlice Lambda pipeline ([846228f](https://github.com/ReventlessDev/reventless-core/commit/846228fc9193a4c344399ecae924241e7944204f))


# 3.0.0-alpha.9 (2026-04-05)

### Bug Fixes

* wire DCB EventCollector and StateViewSlice Lambda pipeline ([846228f](https://github.com/ReventlessDev/reventless-core/commit/846228fc9193a4c344399ecae924241e7944204f))


# [3.0.0-alpha.8](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-layer-builder@3.0.0-alpha.6...@reventlessdev/reventless-layer-builder@3.0.0-alpha.8) (2026-03-28)

* refactor!: migrate Lambda entry points from ReScript to plain ESM ([2c1ea8f](https://github.com/ReventlessDev/reventless-core/commit/2c1ea8f1601e2142690b11f8bb0ffc2fd45c7f51))

### BREAKING CHANGES

* Lambda Layer entry point paths changed from
*EntryPoint.res.mjs to *EntryPoint.mjs — requires layer rebuild.



# [3.0.0-alpha.7](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-layer-builder@3.0.0-alpha.6...@reventlessdev/reventless-layer-builder@3.0.0-alpha.7) (2026-03-27)

* refactor!: migrate Lambda entry points from ReScript to plain ESM ([2c1ea8f](https://github.com/ReventlessDev/reventless-core/commit/2c1ea8f1601e2142690b11f8bb0ffc2fd45c7f51))

### BREAKING CHANGES

* Lambda Layer entry point paths changed from
*EntryPoint.res.mjs to *EntryPoint.mjs — requires layer rebuild.



# [3.0.0-alpha.6](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-layer-builder@3.0.0-alpha.3...@reventlessdev/reventless-layer-builder@3.0.0-alpha.6) (2026-03-27)

### Bug Fixes

* **reventless-layer-builder:** remove unnecessary packages and deploy-time files from Lambda layer ([bbd77e1](https://github.com/ReventlessDev/reventless-core/commit/bbd77e121921631edd330da24d1c59d2866509fe))


# [3.0.0-alpha.5](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-layer-builder@3.0.0-alpha.3...@reventlessdev/reventless-layer-builder@3.0.0-alpha.5) (2026-03-26)

### Bug Fixes

* **reventless-layer-builder:** remove unnecessary packages and deploy-time files from Lambda layer ([bbd77e1](https://github.com/ReventlessDev/reventless-core/commit/bbd77e121921631edd330da24d1c59d2866509fe))


# [3.0.0-alpha.4](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-layer-builder@3.0.0-alpha.3...@reventlessdev/reventless-layer-builder@3.0.0-alpha.4) (2026-03-26)

### Bug Fixes

* **reventless-layer-builder:** remove unnecessary packages and deploy-time files from Lambda layer ([bbd77e1](https://github.com/ReventlessDev/reventless-core/commit/bbd77e121921631edd330da24d1c59d2866509fe))


# [3.0.0-alpha.3](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-layer-builder@0.2.0-alpha.2...@reventlessdev/reventless-layer-builder@3.0.0-alpha.3) (2026-03-22)

### Bug Fixes

* **layer-builder:** fix CJS-via-ESM imports for pacote and treeverse ([03f92c4](https://github.com/ReventlessDev/reventless-core/commit/03f92c406735b117e701e009066db68b6024cfe4))
* **layer-builder:** include @rescript/runtime in Lambda layer ([292db94](https://github.com/ReventlessDev/reventless-core/commit/292db9477d0d67a814915a995efe388035f1413c))
* **rescript-effect:** use deep imports to avoid loading effect barrel ([1823358](https://github.com/ReventlessDev/reventless-core/commit/18233588d3564d8b4d158b949e734cbb92720fcd))
* **reventless-aws:** use package specifiers for layer-provided modules ([7fdf04b](https://github.com/ReventlessDev/reventless-core/commit/7fdf04b6757a7006d3e425c881212c15a932f469))
* **reventless-layer-builder:** include [@smithy](https://github.com/smithy) in layer for ESM resolution ([ff7f4ab](https://github.com/ReventlessDev/reventless-core/commit/ff7f4ab4cbcd2fdd203432a48603ee766b662b9e))
# [3.0.0-alpha.2](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-layer-builder@0.2.0-alpha.2...@reventlessdev/reventless-layer-builder@3.0.0-alpha.2) (2026-03-21)

### Bug Fixes

* **layer-builder:** fix CJS-via-ESM imports for pacote and treeverse ([03f92c4](https://github.com/ReventlessDev/reventless-core/commit/03f92c406735b117e701e009066db68b6024cfe4))
* **layer-builder:** include @rescript/runtime in Lambda layer ([292db94](https://github.com/ReventlessDev/reventless-core/commit/292db9477d0d67a814915a995efe388035f1413c))
* **rescript-effect:** use deep imports to avoid loading effect barrel ([1823358](https://github.com/ReventlessDev/reventless-core/commit/18233588d3564d8b4d158b949e734cbb92720fcd))
* **reventless-aws:** use package specifiers for layer-provided modules ([7fdf04b](https://github.com/ReventlessDev/reventless-core/commit/7fdf04b6757a7006d3e425c881212c15a932f469))
# [0.2.0-alpha.2](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-layer-builder@0.2.0-alpha.1...@reventlessdev/reventless-layer-builder@0.2.0-alpha.2) (2026-03-20)

### Bug Fixes

* **aws:** reduce Lambda bundle size by externalizing layer packages ([c1a042a](https://github.com/ReventlessDev/reventless-core/commit/c1a042a8304bd303a4e0018954b239e9ec38d2bf))
* **layer:** exclude fast-check from Lambda layer ([aafe38d](https://github.com/ReventlessDev/reventless-core/commit/aafe38d603b1a9b54dac321fac3da959333a9afb))
### Features

* **layer-builder:** migrate Lambda layer builder from JS to ReScript ([f6e6f93](https://github.com/ReventlessDev/reventless-core/commit/f6e6f93ab2c311b5ba363403dd3e770f4adb8b4d))
# [0.2.0-alpha.1](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-layer-builder@0.2.0-alpha.0...@reventlessdev/reventless-layer-builder@0.2.0-alpha.1) (2026-03-08)

### Bug Fixes

* **deps:** add missing arborist and pacote dependencies to layer builder ([93bafa0](https://github.com/ReventlessDev/reventless-core/commit/93bafa099bbb477cca31dc41ced04f3361e4a785))
# 0.2.0-alpha.0 (2026-03-08)

### Features

* automate Lambda layer build, move to reventless/ ([381650d](https://github.com/ReventlessDev/reventless-core/commit/381650d1e080c030730d5736e01c4c535c42deb3))
## [0.1.1-alpha.5](https://github.com/ReventlessDev/reventless-core/compare/aws-lambda-layer@0.1.1-alpha.3...aws-lambda-layer@0.1.1-alpha.5) (2026-03-01)

**Note:** Version bump only for package aws-lambda-layer

## [0.1.1-alpha.4](https://github.com/ReventlessDev/reventless-core/compare/aws-lambda-layer@0.1.1-alpha.3...aws-lambda-layer@0.1.1-alpha.4) (2026-02-19)

**Note:** Version bump only for package aws-lambda-layer

## [0.1.1-alpha.3](https://github.com/ReventlessDev/reventless-core/compare/aws-lambda-layer@0.1.1-alpha.2...aws-lambda-layer@0.1.1-alpha.3) (2026-02-14)

**Note:** Version bump only for package aws-lambda-layer

## [0.1.1-alpha.2](https://github.com/ReventlessDev/reventless-core/compare/aws-lambda-layer@0.1.1-alpha.1...aws-lambda-layer@0.1.1-alpha.2) (2026-02-13)

**Note:** Version bump only for package aws-lambda-layer

## 0.1.1-alpha.1 (2026-02-12)
### Bug Fixes

* exclude private packages from versioning and automate doc CHANGELOG updates ([7581d78](https://github.com/ReventlessDev/reventless-core/commit/7581d78e9825fa6d837da8a136b361dee821660f))
