# Change Log

All notable changes to this project will be documented in this file.
See [Conventional Commits](https://conventionalcommits.org) for commit guidelines.

# 1.0.0-alpha.13 (2026-04-24)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-aws





# 1.0.0-alpha.12 (2026-04-22)

### Features

* **build:** migrate from npm to pnpm (hoisted layout) ([1de8b77](https://github.com/ReventlessDev/reventless-core/commit/1de8b7753b8f45c63ea3c8d9f64de2f27febd029))


# 1.0.0-alpha.11 (2026-04-20)

### Bug Fixes

* **aws:** Source B push chain end-to-end ([d2b5cef](https://github.com/ReventlessDev/reventless-core/commit/d2b5cef2ff1dde197879461551e71d04e91962ac))


# 1.0.0-alpha.10 (2026-04-18)

### Features

* **aws:** enable Source B state-change subscriptions (DynamoDB Stream → AppSync Events) ([960b203](https://github.com/ReventlessDev/reventless-core/commit/960b2035d843c2b97cf2014b05fb1a4f132e9984))


# 1.0.0-alpha.9 (2026-04-06)

### Bug Fixes

* add package-specs to all rescript.json to prevent CJS .js output ([780f1e0](https://github.com/ReventlessDev/reventless-core/commit/780f1e035173b73b17b78466ad01fb69c7cca350))


# 1.0.0-alpha.8 (2026-04-04)

### Features

* migrate online-shop-hybrid example to reventless-ppx ([ac66980](https://github.com/ReventlessDev/reventless-core/commit/ac669807bf94b061b85e0217f1ec76af50d12a44))


# 1.0.0-alpha.7 (2026-03-30)

### Features

* **examples:** publish example packages to GitHub Package Registry ([2495ba5](https://github.com/ReventlessDev/reventless-core/commit/2495ba5c4436613d58964f9948c1bacbde61965f))


# [1.0.0-alpha.6](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/online-shop-hybrid-platform-aws@1.0.0-alpha.3...@reventlessdev/online-shop-hybrid-platform-aws@1.0.0-alpha.6) (2026-03-27)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-aws





# [1.0.0-alpha.5](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/online-shop-hybrid-platform-aws@1.0.0-alpha.3...@reventlessdev/online-shop-hybrid-platform-aws@1.0.0-alpha.5) (2026-03-26)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-aws





# [1.0.0-alpha.4](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/online-shop-hybrid-platform-aws@1.0.0-alpha.3...@reventlessdev/online-shop-hybrid-platform-aws@1.0.0-alpha.4) (2026-03-26)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-aws





# [1.0.0-alpha.3](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/online-shop-hybrid-platform-aws@1.0.0-alpha.2...@reventlessdev/online-shop-hybrid-platform-aws@1.0.0-alpha.3) (2026-03-22)

* feat(reventless-aws)!: replace esbuild pipeline with compiled ReScript entry points ([6cb3133](https://github.com/ReventlessDev/reventless-core/commit/6cb313323c73a078d0922fa6b977466f61de74ea))

### BREAKING CHANGES

* esbuild removed from dependencies, `makeBundled` and
`makeBundledFromEntryPoint` removed from RuntimeEnvironment_Lambda,
`BundledEnvironment` module type removed from Runtime.
# [1.0.0-alpha.2](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/online-shop-hybrid-platform-aws@1.0.0-alpha.1...@reventlessdev/online-shop-hybrid-platform-aws@1.0.0-alpha.2) (2026-03-20)

### Bug Fixes

* **examples:** correct Pulumi org name and add beta stack configs ([6358f37](https://github.com/ReventlessDev/reventless-core/commit/6358f3702e3d72df0df74b7a39eb795d9fe6d756))
### Features

* **aws:** replace CallbackFunction with bundled Lambda handlers ([6f6200b](https://github.com/ReventlessDev/reventless-core/commit/6f6200b0796e5f414493f50fd2f13dd6c7871ef4))
# 1.0.0-alpha.1 (2026-03-17)

### Bug Fixes

* **reventless-aws:** resolve Pulumi deploy-time issues ([f0ce675](https://github.com/ReventlessDev/reventless-core/commit/f0ce6751cb3ac829c674991784c5f23cb45a991b))
### Features

* **reventless-aws:** implement per-plugin deployment with runtime schema stitching ([f16714c](https://github.com/ReventlessDev/reventless-core/commit/f16714c5d2b3ad869863ac30dc55ef3e1570bf4f))
