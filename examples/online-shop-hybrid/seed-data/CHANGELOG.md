# Change Log

All notable changes to this project will be documented in this file.
See [Conventional Commits](https://conventionalcommits.org) for commit guidelines.

# 1.0.0-alpha.80 (2026-09-02)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-seed





# 1.0.0-alpha.79 (2026-09-02)

### Features

* **examples:** the shop's notification preferences reach the people who own them ([111e2fd](https://github.com/ReventlessDev/reventless-core/commit/111e2fda3f5ffcb098eafa22b1fa1b00a0f2fe2d))


# 1.0.0-alpha.78 (2026-09-01)

### Bug Fixes

* **deps:** follow the host UI to 3.0.0-alpha.92 ([2192e0a](https://github.com/ReventlessDev/reventless-core/commit/2192e0afe6e482e26c7ba1e2b8a9518dec17037d))


# 1.0.0-alpha.77 (2026-09-01)

* feat(example)!: model product and category images as attachment sets ([6ae18d8](https://github.com/ReventlessDev/reventless-core/commit/6ae18d896215b448177ba0516e74bfda5f88d2db))
### Features

* **online-shop:** notifications decide who to reach and record why they did not ([b850ce3](https://github.com/ReventlessDev/reventless-core/commit/b850ce3d3e238db70a168aa6a72812dc89986697))

### BREAKING CHANGES

* ProductAdded/CategoryAdded lose their image field and
ChangeProductImage/ChangeCategoryImage are replaced; the alpha event log is
wiped on the next deploy.



# 1.0.0-alpha.76 (2026-08-31)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-seed





# 1.0.0-alpha.75 (2026-08-27)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-seed





# 1.0.0-alpha.74 (2026-08-27)

* feat(spec)!: keep the amount in minor units, and add times and allocate ([6ff6308](https://github.com/ReventlessDev/reventless-core/commit/6ff630875f9b126b2f87b980a4dbb56582f8aebe))
* feat(spec)!: hold a money amount in the currency's own units ([94d3bba](https://github.com/ReventlessDev/reventless-core/commit/94d3bbaf0c47a639c20de6847c4615070ad51b38))

### BREAKING CHANGES

* reverts the wire shape to whole minor units, so a log written
against the intervening commit reads a hundredfold low. Nothing released carried
the decimal form.
* stored amounts do not migrate. A log written before this holds
minor units and now decodes a hundredfold high, cleanly and without complaint —
a log that has to survive needs an upcaster written before this is deployed, and
a demo log needs discarding and reseeding. A stored currency outside the ten no
longer decodes; admit it in the generator or migrate the data.



# 1.0.0-alpha.73 (2026-08-23)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-seed





# 1.0.0-alpha.72 (2026-08-23)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-seed





# 1.0.0-alpha.71 (2026-08-23)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-seed





# 1.0.0-alpha.70 (2026-08-22)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-seed





# 1.0.0-alpha.69 (2026-08-21)

### Bug Fixes

* **deps:** update sury to 11.0.0-rc.2 to fix unreachable union constructors ([fa5744f](https://github.com/ReventlessDev/reventless-core/commit/fa5744fed8de975e2f14725c856c6e5ce7d04a74))


# 1.0.0-alpha.68 (2026-08-20)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-seed





# 1.0.0-alpha.67 (2026-08-20)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-seed





# 1.0.0-alpha.66 (2026-08-20)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-seed





# 1.0.0-alpha.65 (2026-08-20)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-seed





# 1.0.0-alpha.64 (2026-08-19)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-seed





# 1.0.0-alpha.63 (2026-08-18)

* feat(sury)!: migrate to sury 11.0.0-rc.1 ([2cf8969](https://github.com/ReventlessDev/reventless-core/commit/2cf8969a222ce1b775563668a4126cb20611966c))

### BREAKING CHANGES

* sury is a direct dependency of the published packages and
its schema and serialization surface changed; consumers must migrate to
sury 11.



# 1.0.0-alpha.62 (2026-08-18)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-seed





# 1.0.0-alpha.61 (2026-08-16)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-seed





# 1.0.0-alpha.60 (2026-08-16)

### Bug Fixes

* **example:** make the hybrid seed run again after the lifecycle rename ([b3bdc75](https://github.com/ReventlessDev/reventless-core/commit/b3bdc75cfe9d59654e85fc1b728a9455664c8274))
* **seed:** report the retirements the projection has actually applied ([91bc877](https://github.com/ReventlessDev/reventless-core/commit/91bc877d90fc69dab76ff0fb9aae9ea989107aed))
### Features

* **core:** mark the state that retires a row, and allow more than one ([cb1461f](https://github.com/ReventlessDev/reventless-core/commit/cb1461f024d3ca3b53fd9c8b010a054e3fcc4555))
* **example:** give the hybrid shop's archive a way back ([524d374](https://github.com/ReventlessDev/reventless-core/commit/524d3748e455c70924b7861cbd4748744186de41))


# 1.0.0-alpha.59 (2026-08-15)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-seed





# 1.0.0-alpha.58 (2026-08-15)

### Features

* **core:** curate the pages a shell builds across a plugin's views ([589835a](https://github.com/ReventlessDev/reventless-core/commit/589835a1ad428c5e2dea8bf6e4c64e49d2f67e0d))
* **examples:** give a category an image ([ad1b741](https://github.com/ReventlessDev/reventless-core/commit/ad1b7416ea6a4392dada097bc45f707e24bdbd2a))
* **examples:** label the order list for whose rows it shows ([dddff13](https://github.com/ReventlessDev/reventless-core/commit/dddff13485f28c9529f21247345b756b3075c44e))


# 1.0.0-alpha.57 (2026-08-14)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-seed





# 1.0.0-alpha.56 (2026-08-14)

### Features

* **example:** let the shop's fulfilment role read every customer's orders ([aa1017c](https://github.com/ReventlessDev/reventless-core/commit/aa1017c1fc2c1ce0434c6022004baf5669e34098))


# 1.0.0-alpha.55 (2026-08-14)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-seed





# 1.0.0-alpha.54 (2026-08-13)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-seed





# 1.0.0-alpha.53 (2026-08-13)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-seed





# 1.0.0-alpha.52 (2026-08-13)

### Bug Fixes

* **example:** seed the demo shopper the login file actually ships ([033e212](https://github.com/ReventlessDev/reventless-core/commit/033e2126bca54c91e46b81dddb687eebffad96c2))
### Features

* **example:** give the shop four roles instead of one ([e35ccc5](https://github.com/ReventlessDev/reventless-core/commit/e35ccc57a0fcdcc2880fcbdcda6affb9bd162919))
* **example:** let the shop state its own navigation and checkout action ([3d7fb90](https://github.com/ReventlessDev/reventless-core/commit/3d7fb90df5a5913a188be620583c92198ba601a0))
* **local:** bake one curated surface per audience ([3be6f63](https://github.com/ReventlessDev/reventless-core/commit/3be6f63e579cef8cd213a84b6ccded773b1abc9e))
* **rescript:** bind import.meta so no module reaches for %raw ([c7bd00c](https://github.com/ReventlessDev/reventless-core/commit/c7bd00c0d49ca06cb26a0891a85921219eb87b12))


# 1.0.0-alpha.51 (2026-08-12)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-seed





# 1.0.0-alpha.50 (2026-08-12)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-seed





# 1.0.0-alpha.49 (2026-08-12)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-seed





# 1.0.0-alpha.48 (2026-08-12)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-seed





# 1.0.0-alpha.47 (2026-08-12)

### Features

* **examples:** tie an order to the shopper who placed it ([6d31a72](https://github.com/ReventlessDev/reventless-core/commit/6d31a724ac542ae069baed738c3efbe90591d6eb))
* **platform:** bake a curated component manifest as a static asset ([4f30265](https://github.com/ReventlessDev/reventless-core/commit/4f30265a51fc2c59e69afd8074cf1b2534c06378))


# 1.0.0-alpha.46 (2026-08-11)

### Features

* **examples:** seed a deliberate AddProduct rejection in the hybrid demo ([b690056](https://github.com/ReventlessDev/reventless-core/commit/b690056beef807d07a6451d224b966a17ccf7b1f))


# 1.0.0-alpha.45 (2026-08-10)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-seed





# 1.0.0-alpha.44 (2026-08-10)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-seed





# 1.0.0-alpha.43 (2026-08-09)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-seed





# 1.0.0-alpha.42 (2026-08-09)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-seed





# 1.0.0-alpha.41 (2026-08-09)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-seed





# 1.0.0-alpha.40 (2026-08-09)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-seed





# 1.0.0-alpha.39 (2026-08-08)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-seed





# 1.0.0-alpha.38 (2026-08-08)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-seed





# 1.0.0-alpha.37 (2026-08-08)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-seed





# 1.0.0-alpha.36 (2026-08-07)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-seed





# 1.0.0-alpha.35 (2026-08-05)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-seed





# 1.0.0-alpha.34 (2026-08-04)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-seed





# 1.0.0-alpha.33 (2026-08-04)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-seed





# 1.0.0-alpha.32 (2026-08-04)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-seed





# 1.0.0-alpha.31 (2026-08-03)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-seed





# 1.0.0-alpha.30 (2026-08-03)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-seed





# 1.0.0-alpha.29 (2026-08-03)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-seed





# 1.0.0-alpha.28 (2026-08-03)

### Features

* **outbound:** let an outbound slice read an aggregate, and geocode addresses with it ([867e63e](https://github.com/ReventlessDev/reventless-core/commit/867e63e774ebc8b78b2b19c78645c8a12a8d06f6))


# 1.0.0-alpha.27 (2026-08-02)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-seed





# 1.0.0-alpha.26 (2026-08-02)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-seed





# 1.0.0-alpha.25 (2026-08-02)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-seed





# 1.0.0-alpha.24 (2026-08-02)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-seed





# 1.0.0-alpha.23 (2026-08-02)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-seed





# 1.0.0-alpha.22 (2026-08-01)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-seed





# 1.0.0-alpha.21 (2026-08-01)

### Features

* **upload:** add the release half of the upload contract via the domain API ([448f887](https://github.com/ReventlessDev/reventless-core/commit/448f88714a5875be420f794a08d482fcf4ba8404))


# 1.0.0-alpha.20 (2026-08-01)

### Bug Fixes

* **examples:** stop the seed expecting the removed USD-only import rule ([e8841ea](https://github.com/ReventlessDev/reventless-core/commit/e8841ea4010202267ad384b3a907acf6673d31cc))


# 1.0.0-alpha.19 (2026-08-01)

### Features

* **spec:** add DateRange semantic type ([d85b6cc](https://github.com/ReventlessDev/reventless-core/commit/d85b6cc18241644905241df2abd99949dd758059))


# 1.0.0-alpha.18 (2026-07-31)

### Features

* **spec:** add Money and a closed ISO 4217 Currency ([d4852ab](https://github.com/ReventlessDev/reventless-core/commit/d4852ab63e823e39fac793c4fa5ac31470db9655))


# 1.0.0-alpha.17 (2026-07-31)

### Bug Fixes

* **seed:** address a deployment's per-store upload endpoints ([45b226e](https://github.com/ReventlessDev/reventless-core/commit/45b226e00604af9fd28b6fb0b75ba7d3414791f2))


# 1.0.0-alpha.16 (2026-07-30)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-seed





# 1.0.0-alpha.15 (2026-07-30)

### Features

* **examples:** seed products with optional images; add upload-test PNGs ([a5205c8](https://github.com/ReventlessDev/reventless-core/commit/a5205c8c233a580cb7bd02989b14bb73d888b7d6))


# 1.0.0-alpha.14 (2026-07-30)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-seed





# 1.0.0-alpha.13 (2026-07-30)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-seed





# 1.0.0-alpha.12 (2026-07-29)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-seed





# 1.0.0-alpha.11 (2026-07-28)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-seed





# 1.0.0-alpha.10 (2026-07-28)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-seed





# 1.0.0-alpha.9 (2026-07-28)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-seed





# 1.0.0-alpha.8 (2026-07-28)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-seed





# 1.0.0-alpha.7 (2026-07-27)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-seed





# 1.0.0-alpha.6 (2026-07-27)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-seed





# 1.0.0-alpha.5 (2026-07-27)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-seed





# 1.0.0-alpha.4 (2026-07-27)

### Features

* **seed:** guarded AWS store reset (seed:reset) with per-project scope selection ([8446172](https://github.com/ReventlessDev/reventless-core/commit/8446172cbb53776a58f53220d19e96d96ce94508))


# 1.0.0-alpha.3 (2026-07-27)

### Features

* **seed:** refuse to seed onto a non-empty store (fresh-store guard) ([987613f](https://github.com/ReventlessDev/reventless-core/commit/987613f0767fc4391297dfeed3a6b19cd76d8157))


# 1.0.0-alpha.2 (2026-07-26)

### Features

* **seed:** per-provider seed scripts, shared machinery, exportable data sets ([ba43e9e](https://github.com/ReventlessDev/reventless-core/commit/ba43e9efab84dd2955b6dafd1e187fd4aad699ad))
