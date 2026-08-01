# Change Log

All notable changes to this project will be documented in this file.
See [Conventional Commits](https://conventionalcommits.org) for commit guidelines.

# 1.0.0-alpha.87 (2026-08-01)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-catalog-spec





# 1.0.0-alpha.86 (2026-08-01)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-catalog-spec





# 1.0.0-alpha.85 (2026-08-01)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-catalog-spec





# 1.0.0-alpha.84 (2026-07-31)

### Features

* **spec:** add Money and a closed ISO 4217 Currency ([d4852ab](https://github.com/ReventlessDev/reventless-core/commit/d4852ab63e823e39fac793c4fa5ac31470db9655))


# 1.0.0-alpha.83 (2026-07-30)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-catalog-spec





# 1.0.0-alpha.82 (2026-07-30)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-catalog-spec





# 1.0.0-alpha.81 (2026-07-30)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-catalog-spec





# 1.0.0-alpha.80 (2026-07-30)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-catalog-spec





# 1.0.0-alpha.79 (2026-07-29)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-catalog-spec





# 1.0.0-alpha.78 (2026-07-28)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-catalog-spec





# 1.0.0-alpha.77 (2026-07-28)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-catalog-spec





# 1.0.0-alpha.76 (2026-07-28)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-catalog-spec





# 1.0.0-alpha.75 (2026-07-28)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-catalog-spec





# 1.0.0-alpha.74 (2026-07-26)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-catalog-spec





# 1.0.0-alpha.73 (2026-07-22)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-catalog-spec





# 1.0.0-alpha.72 (2026-07-17)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-catalog-spec





# 1.0.0-alpha.71 (2026-07-16)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-catalog-spec





# 1.0.0-alpha.70 (2026-07-15)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-catalog-spec





# 1.0.0-alpha.69 (2026-07-12)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-catalog-spec





# 1.0.0-alpha.68 (2026-07-11)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-catalog-spec





# 1.0.0-alpha.67 (2026-07-11)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-catalog-spec





# 1.0.0-alpha.66 (2026-07-11)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-catalog-spec





# 1.0.0-alpha.65 (2026-07-10)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-catalog-spec





# 1.0.0-alpha.64 (2026-07-10)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-catalog-spec





# 1.0.0-alpha.63 (2026-07-10)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-catalog-spec





# 1.0.0-alpha.62 (2026-07-08)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-catalog-spec





# 1.0.0-alpha.61 (2026-07-07)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-catalog-spec





# 1.0.0-alpha.60 (2026-07-06)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-catalog-spec





# 1.0.0-alpha.59 (2026-07-05)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-catalog-spec





# 1.0.0-alpha.58 (2026-07-05)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-catalog-spec





# 1.0.0-alpha.57 (2026-07-03)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-catalog-spec





# 1.0.0-alpha.56 (2026-07-02)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-catalog-spec





# 1.0.0-alpha.55 (2026-06-29)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-catalog-spec





# 1.0.0-alpha.54 (2026-06-27)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-catalog-spec





# 1.0.0-alpha.53 (2026-06-22)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-catalog-spec





# 1.0.0-alpha.52 (2026-06-21)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-catalog-spec





# 1.0.0-alpha.51 (2026-06-21)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-catalog-spec





# 1.0.0-alpha.50 (2026-06-20)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-catalog-spec





# 1.0.0-alpha.49 (2026-06-20)

### Bug Fixes

* **packaging:** publish online-shop-hybrid examples source-only via .npmignore ([a2b3cbf](https://github.com/ReventlessDev/reventless-core/commit/a2b3cbf6067b006647aefee2bf1f4daf182c98e9))


# 1.0.0-alpha.48 (2026-06-17)

* feat(example)!: type the directive channel in the hybrid example ([7ee7527](https://github.com/ReventlessDev/reventless-core/commit/7ee75275a01808c83df3e5c4f309c1be851bcffb))

### BREAKING CHANGES

* `Products_ExtensionPoint.directive` and
`Orders_ExtensionPoint.directive` are no longer `unit`. Out-of-tree
consumers that declared `type directive = unit` and then referenced it
in code need a one-line rename. In-repo callers are updated.



# 1.0.0-alpha.47 (2026-06-12)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-catalog-spec





# 1.0.0-alpha.46 (2026-06-11)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-catalog-spec





# 1.0.0-alpha.45 (2026-06-10)

### Bug Fixes

* **examples:** restore publishing of online-shop-hybrid packages ([8fa95d3](https://github.com/ReventlessDev/reventless-core/commit/8fa95d3e6de4f10284afdde4aa24a10dcffe202b))


# 1.0.0-alpha.44 (2026-06-08)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-catalog-spec





# 1.0.0-alpha.43 (2026-06-08)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-catalog-spec





# 1.0.0-alpha.42 (2026-06-06)

### Bug Fixes

* **examples:** restore publishing of online-shop-hybrid packages ([8cc6b9d](https://github.com/ReventlessDev/reventless-core/commit/8cc6b9d934cc96e0841f4f2802399f7f75e49d71))


# 1.0.0-alpha.41 (2026-06-04)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-catalog-spec





# 1.0.0-alpha.40 (2026-06-04)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-catalog-spec





# 1.0.0-alpha.39 (2026-06-04)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-catalog-spec





# 1.0.0-alpha.38 (2026-06-04)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-catalog-spec





# 1.0.0-alpha.37 (2026-05-27)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-catalog-spec





# 1.0.0-alpha.36 (2026-05-27)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-catalog-spec





# 1.0.0-alpha.35 (2026-05-27)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-catalog-spec





# 1.0.0-alpha.34 (2026-05-26)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-catalog-spec





# 1.0.0-alpha.33 (2026-05-26)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-catalog-spec





# 1.0.0-alpha.32 (2026-05-25)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-catalog-spec





# 1.0.0-alpha.31 (2026-05-25)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-catalog-spec





# 1.0.0-alpha.30 (2026-05-25)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-catalog-spec





# 1.0.0-alpha.29 (2026-05-21)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-catalog-spec





# 1.0.0-alpha.28 (2026-05-21)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-catalog-spec





# 1.0.0-alpha.27 (2026-05-20)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-catalog-spec





# 1.0.0-alpha.26 (2026-05-19)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-catalog-spec





# 1.0.0-alpha.25 (2026-05-18)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-catalog-spec





# 1.0.0-alpha.24 (2026-05-17)

### Bug Fixes

* **deps:** pin sury-ppx to 11.0.0-alpha.2 to prevent prerelease drift ([c9d05fe](https://github.com/ReventlessDev/reventless-core/commit/c9d05fe5118a9c0442ca3e071f2606b3a139fc81))


# 1.0.0-alpha.23 (2026-05-17)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-catalog-spec





# 1.0.0-alpha.22 (2026-05-17)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-catalog-spec





# 1.0.0-alpha.21 (2026-05-16)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-catalog-spec





# 1.0.0-alpha.20 (2026-05-16)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-catalog-spec





# 1.0.0-alpha.19 (2026-05-16)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-catalog-spec





# 1.0.0-alpha.18 (2026-05-14)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-catalog-spec





# 1.0.0-alpha.17 (2026-05-13)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-catalog-spec





# 1.0.0-alpha.16 (2026-05-05)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-catalog-spec





# 1.0.0-alpha.15 (2026-05-03)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-catalog-spec





# 1.0.0-alpha.14 (2026-04-28)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-catalog-spec





# 1.0.0-alpha.13 (2026-04-27)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-catalog-spec





# 1.0.0-alpha.12 (2026-04-26)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-catalog-spec





# 1.0.0-alpha.11 (2026-04-24)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-catalog-spec





# 1.0.0-alpha.10 (2026-04-24)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-catalog-spec





# 1.0.0-alpha.9 (2026-04-22)

### Features

* **build:** migrate from npm to pnpm (hoisted layout) ([1de8b77](https://github.com/ReventlessDev/reventless-core/commit/1de8b7753b8f45c63ea3c8d9f64de2f27febd029))


# 1.0.0-alpha.8 (2026-04-06)

### Bug Fixes

* add package-specs to all rescript.json to prevent CJS .js output ([780f1e0](https://github.com/ReventlessDev/reventless-core/commit/780f1e035173b73b17b78466ad01fb69c7cca350))


# 1.0.0-alpha.7 (2026-04-04)

### Features

* migrate online-shop-hybrid example to reventless-ppx ([ac66980](https://github.com/ReventlessDev/reventless-core/commit/ac669807bf94b061b85e0217f1ec76af50d12a44))


# 1.0.0-alpha.6 (2026-03-30)

### Features

* **examples:** publish example packages to GitHub Package Registry ([2495ba5](https://github.com/ReventlessDev/reventless-core/commit/2495ba5c4436613d58964f9948c1bacbde61965f))


# [1.0.0-alpha.5](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/online-shop-hybrid-catalog-spec@1.0.0-alpha.2...@reventlessdev/online-shop-hybrid-catalog-spec@1.0.0-alpha.5) (2026-03-27)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-catalog-spec





# [1.0.0-alpha.4](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/online-shop-hybrid-catalog-spec@1.0.0-alpha.2...@reventlessdev/online-shop-hybrid-catalog-spec@1.0.0-alpha.4) (2026-03-26)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-catalog-spec





# [1.0.0-alpha.3](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/online-shop-hybrid-catalog-spec@1.0.0-alpha.2...@reventlessdev/online-shop-hybrid-catalog-spec@1.0.0-alpha.3) (2026-03-26)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-catalog-spec





# [1.0.0-alpha.2](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/online-shop-hybrid-catalog-spec@1.0.0-alpha.1...@reventlessdev/online-shop-hybrid-catalog-spec@1.0.0-alpha.2) (2026-03-22)

* feat(reventless-aws)!: replace esbuild pipeline with compiled ReScript entry points ([6cb3133](https://github.com/ReventlessDev/reventless-core/commit/6cb313323c73a078d0922fa6b977466f61de74ea))

### BREAKING CHANGES

* esbuild removed from dependencies, `makeBundled` and
`makeBundledFromEntryPoint` removed from RuntimeEnvironment_Lambda,
`BundledEnvironment` module type removed from Runtime.
# [1.0.0-alpha.1](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/online-shop-hybrid-catalog-spec@0.1.0-alpha.1...@reventlessdev/online-shop-hybrid-catalog-spec@1.0.0-alpha.1) (2026-03-17)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-catalog-spec

# [0.1.0-alpha.1](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/online-shop-hybrid-catalog-spec@0.1.0-alpha.0...@reventlessdev/online-shop-hybrid-catalog-spec@0.1.0-alpha.1) (2026-03-12)

### Features

* **deps:** upgrade rescript to 12.2 and migrate Belt usages to stdlib ([eaa96ea](https://github.com/ReventlessDev/reventless-core/commit/eaa96ea61ca40d61573fb5fe2002a1f73d43ce3e))
# 0.1.0-alpha.0 (2026-03-08)

### Features

* **examples:** add online-shop-hybrid example with aggregate + DCB composition ([296ad05](https://github.com/ReventlessDev/reventless-core/commit/296ad05f067c53854d4cf0a5d4a8deb91d751b04))
* replace explicit queryMode with automatic schema-driven DCB query construction ([8df4350](https://github.com/ReventlessDev/reventless-core/commit/8df4350c37f1f15678f4796f229647eaeb3e8222))
