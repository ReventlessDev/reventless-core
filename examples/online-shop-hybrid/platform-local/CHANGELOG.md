# Change Log

All notable changes to this project will be documented in this file.
See [Conventional Commits](https://conventionalcommits.org) for commit guidelines.

# 1.0.0-alpha.250 (2026-09-04)

### Features

* **local:** one platform per app directory, and a reset that refuses a served store ([e0fd219](https://github.com/ReventlessDev/reventless-core/commit/e0fd219a8c1bbda85589374ffa75aaab0f3e4fda))


# 1.0.0-alpha.249 (2026-09-04)

### Bug Fixes

* **deps:** follow the host UI to 3.0.0-alpha.94 ([7256832](https://github.com/ReventlessDev/reventless-core/commit/72568329413d4e53c4b37cb042a5453cc7857061))


# 1.0.0-alpha.248 (2026-09-02)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.247 (2026-09-02)

* feat(aws)!: the messaging sender is configuration, and a stack can choose to only log ([23b8b4b](https://github.com/ReventlessDev/reventless-core/commit/23b8b4bfe9c70555de4d74266ca686cb427485ca))
### Features

* **dcb:** a boundary that cannot derive its scope says so ([db79969](https://github.com/ReventlessDev/reventless-core/commit/db79969df36bd90607425f6a22b4624227cfc4a0))

### BREAKING CHANGES

* `Capability_Messaging_Ses.make` is replaced by
`Capability_Messaging.make(~name)`, which reads the transport and the address
from config; the SES module keeps only `emailSender`. A deployment that named its
sender in code must move it to `platform:messagingEmailSender` or the deploy is
refused.



# 1.0.0-alpha.246 (2026-09-01)

### Bug Fixes

* **deps:** follow the host UI to 3.0.0-alpha.92 ([2192e0a](https://github.com/ReventlessDev/reventless-core/commit/2192e0afe6e482e26c7ba1e2b8a9518dec17037d))


# 1.0.0-alpha.245 (2026-09-01)

* feat(example)!: model product and category images as attachment sets ([6ae18d8](https://github.com/ReventlessDev/reventless-core/commit/6ae18d896215b448177ba0516e74bfda5f88d2db))

### BREAKING CHANGES

* ProductAdded/CategoryAdded lose their image field and
ChangeProductImage/ChangeCategoryImage are replaced; the alpha event log is
wiped on the next deploy.



# 1.0.0-alpha.244 (2026-08-31)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.243 (2026-08-27)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.242 (2026-08-27)

### Bug Fixes

* **deps:** follow the host UI to 3.0.0-alpha.91 ([324ccf3](https://github.com/ReventlessDev/reventless-core/commit/324ccf377a8849af9b6c14ae829c9e63992d5b1f))


# 1.0.0-alpha.241 (2026-08-27)

### Bug Fixes

* **deps:** bump reventless-host-shell to 3.0.0-alpha.89 ([4f53b68](https://github.com/ReventlessDev/reventless-core/commit/4f53b680417a9b7e0dadd3d48948321fcf234950))
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



# 1.0.0-alpha.240 (2026-08-25)

### Bug Fixes

* **deps:** update host-shell to 3.0.0-alpha.87 ([ce3e35c](https://github.com/ReventlessDev/reventless-core/commit/ce3e35c9e4ebb3bd6b22d4d59fb2093f454decdb))
* **deps:** update host-shell to 3.0.0-alpha.88 ([82b8025](https://github.com/ReventlessDev/reventless-core/commit/82b8025ae70d051c157a844acd1e1705b03a2423))


# 1.0.0-alpha.239 (2026-08-24)

### Bug Fixes

* **deps:** update host-shell to 3.0.0-alpha.85 for working backward paging ([0bd8fa5](https://github.com/ReventlessDev/reventless-core/commit/0bd8fa5b5ceefef364fa29f10c1c32769885a31c))
* **deps:** update host-shell to 3.0.0-alpha.86 ([80c3f11](https://github.com/ReventlessDev/reventless-core/commit/80c3f110c7b6c2c9c971e613a4cbc7acca1bc1aa))


# 1.0.0-alpha.238 (2026-08-23)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.237 (2026-08-23)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.236 (2026-08-23)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.235 (2026-08-22)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.234 (2026-08-21)

### Bug Fixes

* **deps:** update sury to 11.0.0-rc.2 to fix unreachable union constructors ([fa5744f](https://github.com/ReventlessDev/reventless-core/commit/fa5744fed8de975e2f14725c856c6e5ce7d04a74))


# 1.0.0-alpha.233 (2026-08-20)

### Features

* **seed:** choose the login from the platform's users.yaml ([74e61de](https://github.com/ReventlessDev/reventless-core/commit/74e61de8fba3ee4cc62b368ff12010f162d49db7))


# 1.0.0-alpha.232 (2026-08-20)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.231 (2026-08-20)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.230 (2026-08-20)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.229 (2026-08-19)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.228 (2026-08-18)

* feat(sury)!: migrate to sury 11.0.0-rc.1 ([2cf8969](https://github.com/ReventlessDev/reventless-core/commit/2cf8969a222ce1b775563668a4126cb20611966c))

### BREAKING CHANGES

* sury is a direct dependency of the published packages and
its schema and serialization surface changed; consumers must migrate to
sury 11.



# 1.0.0-alpha.227 (2026-08-18)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.226 (2026-08-16)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.225 (2026-08-16)

### Bug Fixes

* **seed:** let seed:reset take the yes it asks for ([1f646f6](https://github.com/ReventlessDev/reventless-core/commit/1f646f6ce13a4238e92b7047ee31650ccc4de4f3))


# 1.0.0-alpha.224 (2026-08-15)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.223 (2026-08-15)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.222 (2026-08-14)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.221 (2026-08-14)

### Features

* **example:** let the shop's fulfilment role read every customer's orders ([aa1017c](https://github.com/ReventlessDev/reventless-core/commit/aa1017c1fc2c1ce0434c6022004baf5669e34098))


# 1.0.0-alpha.220 (2026-08-14)

### Features

* **local:** let the seed tools address a platform, not a guessed file ([98862ad](https://github.com/ReventlessDev/reventless-core/commit/98862adaa4111f605553e4a78bc52a8a488a4ef3))


# 1.0.0-alpha.219 (2026-08-13)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.218 (2026-08-13)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.217 (2026-08-13)

### Bug Fixes

* **example:** seed the demo shopper the login file actually ships ([033e212](https://github.com/ReventlessDev/reventless-core/commit/033e2126bca54c91e46b81dddb687eebffad96c2))
### Features

* **example:** give the shop four roles instead of one ([e35ccc5](https://github.com/ReventlessDev/reventless-core/commit/e35ccc57a0fcdcc2880fcbdcda6affb9bd162919))
* **example:** let the shop state its own navigation and checkout action ([3d7fb90](https://github.com/ReventlessDev/reventless-core/commit/3d7fb90df5a5913a188be620583c92198ba601a0))
* **local:** point the dev shell at the manifest it bakes ([e4d0f1c](https://github.com/ReventlessDev/reventless-core/commit/e4d0f1cef70f9a9ca6d13266d72db3f38d0cc2d9))


# 1.0.0-alpha.216 (2026-08-13)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.215 (2026-08-12)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.214 (2026-08-12)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.213 (2026-08-12)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.212 (2026-08-12)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.211 (2026-08-12)

### Features

* **examples:** tie an order to the shopper who placed it ([6d31a72](https://github.com/ReventlessDev/reventless-core/commit/6d31a724ac542ae069baed738c3efbe90591d6eb))
* **platform:** bake a curated component manifest as a static asset ([4f30265](https://github.com/ReventlessDev/reventless-core/commit/4f30265a51fc2c59e69afd8074cf1b2534c06378))


# 1.0.0-alpha.210 (2026-08-11)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.209 (2026-08-10)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.208 (2026-08-10)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.207 (2026-08-10)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.206 (2026-08-09)

### Bug Fixes

* **examples:** pin host-shell 3.0.0-alpha.58 so [@live](https://github.com/live)(false) hides the Live control ([f1eba90](https://github.com/ReventlessDev/reventless-core/commit/f1eba9024540db5d20d7e11080f5f2d35ed3dbee))


# 1.0.0-alpha.205 (2026-08-09)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.204 (2026-08-09)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.203 (2026-08-09)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.202 (2026-08-08)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.201 (2026-08-08)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.200 (2026-08-08)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.199 (2026-08-07)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.198 (2026-08-05)

### Features

* **local:** scoped seed:reset for the local platform ([a4dd003](https://github.com/ReventlessDev/reventless-core/commit/a4dd0033b7d01be23be91bac3f01d38ebeab7d45))


# 1.0.0-alpha.197 (2026-08-04)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.196 (2026-08-04)

### Features

* **deps:** pin host-shell to 3.0.0-alpha.55 for the geocode client ([78d2d5c](https://github.com/ReventlessDev/reventless-core/commit/78d2d5c4fd53dd63a8a5ae695ad1b60627eed1c0))


# 1.0.0-alpha.195 (2026-08-04)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.194 (2026-08-03)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.193 (2026-08-03)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.192 (2026-08-03)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.191 (2026-08-03)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.190 (2026-08-02)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.189 (2026-08-02)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.188 (2026-08-02)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.187 (2026-08-02)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.186 (2026-08-02)

### Features

* **deps:** bump host-shell to 3.0.0-alpha.54 ([6866095](https://github.com/ReventlessDev/reventless-core/commit/6866095ca2a1c1b9e42866623f9cf73aa275e02a))


# 1.0.0-alpha.185 (2026-08-01)

### Features

* **deps:** bump host-shell to 3.0.0-alpha.53 ([3a8eb71](https://github.com/ReventlessDev/reventless-core/commit/3a8eb71d36c8945b0d1858000b84b86f5fc53f53))


# 1.0.0-alpha.184 (2026-08-01)

### Features

* **deps:** bump host-shell to 3.0.0-alpha.52 ([4a56549](https://github.com/ReventlessDev/reventless-core/commit/4a565497a8895a46fd28482e4495cfbaad6f86b5))
* **upload:** add the release half of the upload contract via the domain API ([448f887](https://github.com/ReventlessDev/reventless-core/commit/448f88714a5875be420f794a08d482fcf4ba8404))


# 1.0.0-alpha.183 (2026-08-01)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.182 (2026-08-01)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.181 (2026-07-31)

### Features

* **spec:** add Money and a closed ISO 4217 Currency ([d4852ab](https://github.com/ReventlessDev/reventless-core/commit/d4852ab63e823e39fac793c4fa5ac31470db9655))


# 1.0.0-alpha.180 (2026-07-31)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.179 (2026-07-30)

### Bug Fixes

* **deps:** bump reventless-host-shell to 3.0.0-alpha.50 ([d54a4ec](https://github.com/ReventlessDev/reventless-core/commit/d54a4ecbd81209e57b9637753bf36fb3f386f612))


# 1.0.0-alpha.178 (2026-07-30)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.177 (2026-07-30)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.176 (2026-07-30)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.175 (2026-07-30)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.174 (2026-07-29)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.173 (2026-07-28)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.172 (2026-07-28)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.171 (2026-07-28)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.170 (2026-07-28)

### Features

* **spec:** StorageRef — the first semantic type, declared on the field's type ([44f15c3](https://github.com/ReventlessDev/reventless-core/commit/44f15c37de71261d701d18a9f1ada6f481c4a8dc))


# 1.0.0-alpha.169 (2026-07-27)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.168 (2026-07-27)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.167 (2026-07-27)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.166 (2026-07-27)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.165 (2026-07-27)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.164 (2026-07-26)

### Features

* **seed:** per-provider seed scripts, shared machinery, exportable data sets ([ba43e9e](https://github.com/ReventlessDev/reventless-core/commit/ba43e9efab84dd2955b6dafd1e187fd4aad699ad))


# 1.0.0-alpha.163 (2026-07-26)

### Bug Fixes

* **core:** decode the event envelope in OutboundTranslationSlice ([66008a4](https://github.com/ReventlessDev/reventless-core/commit/66008a4dff411c85470f60aac5424e7b3eda6f01))
* **graphql:** give InboundTranslationSlice mutations a resolvable result type ([381b545](https://github.com/ReventlessDev/reventless-core/commit/381b5458c16797404cb8ed95fa853fb1e1ca4199))
* feat(examples)!: gate hybrid auto-shipping on a shipping method ([d620e12](https://github.com/ReventlessDev/reventless-core/commit/d620e1292db1b470670654588d04cc51b34d2ab9))
### Features

* **example:** geo-point + file command inputs and a map-bearing view ([1cd89e8](https://github.com/ReventlessDev/reventless-core/commit/1cd89e8dbf256a84a2d689df58887203ea345358))
* **example:** product image upload replaces the customer document demo ([467b8d3](https://github.com/ReventlessDev/reventless-core/commit/467b8d3ab729be1d4fb334939453e86fdb402015))
* **seed:** add a reusable GraphQL seeding harness ([e8c2230](https://github.com/ReventlessDev/reventless-core/commit/e8c2230f25d59e7f93518bff2b2a55997395fb2c))
* **seed:** seed product images through the served-bucket upload contract ([7e63efc](https://github.com/ReventlessDev/reventless-core/commit/7e63efccba52de5458efbaa0788ed4564a45ae50))

### BREAKING CHANGES

* PlaceOrder and OrderPlaced gain a required shippingMethod
field; the RefundOrder slice and its IssueRefund command are removed.



# 1.0.0-alpha.162 (2026-07-24)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.161 (2026-07-23)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.160 (2026-07-22)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.159 (2026-07-22)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.158 (2026-07-22)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.157 (2026-07-22)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.156 (2026-07-21)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.155 (2026-07-20)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.154 (2026-07-17)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.153 (2026-07-17)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.152 (2026-07-16)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.151 (2026-07-16)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.150 (2026-07-15)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.149 (2026-07-14)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.148 (2026-07-14)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.147 (2026-07-14)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.146 (2026-07-13)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.145 (2026-07-13)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.144 (2026-07-13)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.143 (2026-07-13)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.142 (2026-07-13)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.141 (2026-07-13)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.140 (2026-07-13)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.139 (2026-07-12)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.138 (2026-07-12)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.137 (2026-07-12)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.136 (2026-07-11)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.135 (2026-07-11)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.134 (2026-07-11)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.133 (2026-07-11)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.132 (2026-07-11)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.131 (2026-07-10)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.130 (2026-07-10)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.129 (2026-07-10)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.128 (2026-07-10)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.127 (2026-07-09)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.126 (2026-07-09)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.125 (2026-07-08)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.124 (2026-07-08)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.123 (2026-07-08)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.122 (2026-07-07)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.121 (2026-07-07)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.120 (2026-07-07)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.119 (2026-07-06)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.118 (2026-07-06)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.117 (2026-07-06)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.116 (2026-07-06)

### Features

* **reventless-aws:** classic EventLog Postgres deploy-time wiring + relay (B1 vertical) ([8235ba4](https://github.com/ReventlessDev/reventless-core/commit/8235ba44e506f7094d17251405c6a05c39789805))


# 1.0.0-alpha.115 (2026-07-05)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.114 (2026-07-05)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.113 (2026-07-05)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.112 (2026-07-05)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.111 (2026-07-04)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.110 (2026-07-03)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.109 (2026-07-02)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.108 (2026-06-29)

### Bug Fixes

* **deps:** regenerate pnpm-lock.yaml onto npmjs; bump host-shell alpha.32->alpha.33 ([b3e5ae2](https://github.com/ReventlessDev/reventless-core/commit/b3e5ae2d8a2aebd4ddf5480dfe64d647c340f130)), closes [#1](https://github.com/ReventlessDev/reventless-core/issues/1) [#3](https://github.com/ReventlessDev/reventless-core/issues/3)


# 1.0.0-alpha.107 (2026-06-27)

### Features

* verify category exists in AddProduct via cross-partition DCB read ([074d4fa](https://github.com/ReventlessDev/reventless-core/commit/074d4faecf694164f2e0c789c4d94cae402b03e1))


# 1.0.0-alpha.106 (2026-06-22)

### Bug Fixes

* **deps:** bump reventless-host-shell to 3.0.0-alpha.31 ([83ceb18](https://github.com/ReventlessDev/reventless-core/commit/83ceb181b5c32f810b4379831ccebd078ab8fc99))


# 1.0.0-alpha.105 (2026-06-21)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.104 (2026-06-21)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.103 (2026-06-21)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.102 (2026-06-20)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.101 (2026-06-20)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.100 (2026-06-20)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.99 (2026-06-20)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.98 (2026-06-20)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.97 (2026-06-18)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.96 (2026-06-18)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.95 (2026-06-18)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.94 (2026-06-18)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.93 (2026-06-17)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.92 (2026-06-17)

### Bug Fixes

* **deps:** pin ppx alpha.40 binaries and bump reventless-host-shell to alpha.29 ([57d5b99](https://github.com/ReventlessDev/reventless-core/commit/57d5b993090f482326769c97a282c4cba2d32041))
* **packaging:** executable ppx binaries + promote phantom deps for standalone installs ([9b6bea2](https://github.com/ReventlessDev/reventless-core/commit/9b6bea24570b0b0654c825d560ef781c0295512a))
* feat!: harmonize plugin make() across aggregate/DCB/hybrid; AutoUI default-on ([6f3b95e](https://github.com/ReventlessDev/reventless-core/commit/6f3b95e6aa8a136c6e837346c41a3a4dff0f9405))

### BREAKING CHANGES

* makeAutoUIManifest signature dropped ~aggregates and
~readModels; replaced with ~pluginStructure. Hand-written Plugin.res files
that pass ~uiBundleUrl to plugin.make must drop the arg and rely on the
generator-emitted env var read.



# 1.0.0-alpha.91 (2026-06-12)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.90 (2026-06-12)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.89 (2026-06-11)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.88 (2026-06-10)

* refactor(reventless-local)!: rename reventless-in-memory to reventless-local ([f36e17c](https://github.com/ReventlessDev/reventless-core/commit/f36e17c407714ab9740393fac96865d6a5c143c9))

### BREAKING CHANGES

* @reventlessdev/reventless-in-memory -> @reventlessdev/reventless-local;
namespace ReventlessInMemory -> ReventlessLocal.



# 1.0.0-alpha.87 (2026-06-09)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.86 (2026-06-08)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.85 (2026-06-08)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.84 (2026-06-08)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.83 (2026-06-08)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.82 (2026-06-07)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.81 (2026-06-06)

* refactor(reventless-local)!: rename reventless-in-memory to reventless-local ([966855f](https://github.com/ReventlessDev/reventless-core/commit/966855fd31e518d56a381bf40204735809cead15))

### BREAKING CHANGES

* @reventlessdev/reventless-in-memory -> @reventlessdev/reventless-local;
namespace ReventlessInMemory -> ReventlessLocal.



# 1.0.0-alpha.80 (2026-06-04)

### Bug Fixes

* **deps:** bump reventless-host-shell to 3.0.0-alpha.26 ([941ac14](https://github.com/ReventlessDev/reventless-core/commit/941ac142ae30a9d1f83ff4d3f241d15e41979057))


# 1.0.0-alpha.79 (2026-06-04)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.78 (2026-06-04)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.77 (2026-06-04)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.76 (2026-06-04)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.75 (2026-06-04)

### Features

* **onboarding:** one-command setup, accurate docs, Intel-mac PPX prebuilt ([e5faa10](https://github.com/ReventlessDev/reventless-core/commit/e5faa10e3ea3fc2b53f3712a8da5301e50755c60))


# 1.0.0-alpha.74 (2026-06-04)

### Bug Fixes

* **example:** bump host-shell pin to 3.0.0-alpha.21 in online-shop-hybrid ([c85cd32](https://github.com/ReventlessDev/reventless-core/commit/c85cd32e4bda2ad652a99d768d290926ab4b0eed))


# 1.0.0-alpha.73 (2026-05-28)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.72 (2026-05-28)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.71 (2026-05-27)

### Bug Fixes

* **deps:** bump reventless-host-shell to 3.0.0-alpha.20 ([b462a64](https://github.com/ReventlessDev/reventless-core/commit/b462a64e56e8d702926d7df1f339bf6ca46c435a))


# 1.0.0-alpha.70 (2026-05-27)

### Bug Fixes

* **framework:** wire plugin ExtensionPoints into EventCollector runtime context ([2ce8dff](https://github.com/ReventlessDev/reventless-core/commit/2ce8dff426b576811a28c012934d77ecba8a33c0))


# 1.0.0-alpha.69 (2026-05-27)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.68 (2026-05-27)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.67 (2026-05-27)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.66 (2026-05-26)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.65 (2026-05-26)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.64 (2026-05-25)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.63 (2026-05-25)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.62 (2026-05-25)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.61 (2026-05-21)

### Features

* **gwt:** add Delegate_GWT + Flow_GWT cross-slice/cross-plugin test kinds ([19f89a6](https://github.com/ReventlessDev/reventless-core/commit/19f89a6baba3acddb683c81952692fb1a695681d))


# 1.0.0-alpha.60 (2026-05-21)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.59 (2026-05-21)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.58 (2026-05-20)

### Bug Fixes

* **deps:** bump host-shell to 3.0.0-alpha.17 in hybrid platforms ([c5c3077](https://github.com/ReventlessDev/reventless-core/commit/c5c3077caf35d11194e52a804bdfcd653d31a2c3))
* **deps:** bump host-shell to 3.0.0-alpha.18 in hybrid platforms ([5c1f031](https://github.com/ReventlessDev/reventless-core/commit/5c1f0319f033e857db7b3153060786a372f40c98))


# 1.0.0-alpha.57 (2026-05-20)

### Bug Fixes

* **deps:** bump host-shell to 3.0.0-alpha.16 in hybrid platforms ([7648c25](https://github.com/ReventlessDev/reventless-core/commit/7648c25d6fd99d1d2796cd321199ece5f4933926))


# 1.0.0-alpha.56 (2026-05-20)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.55 (2026-05-19)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.54 (2026-05-19)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.53 (2026-05-19)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.52 (2026-05-19)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.51 (2026-05-18)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.50 (2026-05-18)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.49 (2026-05-17)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.48 (2026-05-17)

### Bug Fixes

* **deps:** pin sury-ppx to 11.0.0-alpha.2 to prevent prerelease drift ([c9d05fe](https://github.com/ReventlessDev/reventless-core/commit/c9d05fe5118a9c0442ca3e071f2606b3a139fc81))


# 1.0.0-alpha.47 (2026-05-17)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.46 (2026-05-17)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.45 (2026-05-17)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.44 (2026-05-17)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.43 (2026-05-17)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.42 (2026-05-16)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.41 (2026-05-16)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.40 (2026-05-16)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.39 (2026-05-16)

### Bug Fixes

* **deps:** bump @reventlessdev/reventless-host-shell to 3.0.0-alpha.13 ([f671d74](https://github.com/ReventlessDev/reventless-core/commit/f671d74722522f1ab4a71552789a9a83255e8954))


# 1.0.0-alpha.38 (2026-05-16)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.37 (2026-05-16)

### Bug Fixes

* **deps:** bump @reventlessdev/reventless-host-shell to 3.0.0-alpha.11 ([a89211c](https://github.com/ReventlessDev/reventless-core/commit/a89211cd2f1bf23f4eb84223e7d37d7dda5194a5))
* **deps:** bump @reventlessdev/reventless-host-shell to 3.0.0-alpha.12 ([a5f8ac0](https://github.com/ReventlessDev/reventless-core/commit/a5f8ac02652a3d29435ec1248671ba13ae199599))
### Features

* **example:** switch online-shop-hybrid dev:ui to host-shell ([65e2cf8](https://github.com/ReventlessDev/reventless-core/commit/65e2cf8fadaa46c97741b2cf945d6ceae7d22fe4))


# 1.0.0-alpha.36 (2026-05-14)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.35 (2026-05-13)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.34 (2026-05-10)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.33 (2026-05-05)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.32 (2026-05-04)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.31 (2026-05-03)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.30 (2026-05-03)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.29 (2026-05-03)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.27 (2026-04-28)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.26 (2026-04-27)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.25 (2026-04-26)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.24 (2026-04-24)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.23 (2026-04-24)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform-local





# 1.0.0-alpha.22 (2026-04-22)

### Bug Fixes

* **deps:** correct dev-app package scope to [@reventlessdev](https://github.com/reventlessdev) ([7b7b285](https://github.com/ReventlessDev/reventless-core/commit/7b7b285b615bd9fd4e68a133544d114498e32e02))
* wire DCB cross-plugin event routing and AutoUI command linking ([8baabad](https://github.com/ReventlessDev/reventless-core/commit/8baabad8bce02ab0954a0eeefffb4cf5f448e1e7))
### Features

* **build:** migrate from npm to pnpm (hoisted layout) ([1de8b77](https://github.com/ReventlessDev/reventless-core/commit/1de8b7753b8f45c63ea3c8d9f64de2f27febd029))
* **spec:** wire UI fragment manifest through plugin make via ~uiBundleUrl ([e07fa3a](https://github.com/ReventlessDev/reventless-core/commit/e07fa3a05d6effdd4c6c6686ab1f7e4e4312c438))


# 1.0.0-alpha.21 (2026-04-20)

### Dependency Updates

* **@reventlessdev/online-shop-hybrid-catalog** updated to `^1.0.0-alpha.19`
* **@reventlessdev/online-shop-hybrid-ordering** updated to `^1.0.0-alpha.19`


# 1.0.0-alpha.20 (2026-04-18)

### Dependency Updates

* **@reventlessdev/online-shop-hybrid-catalog** updated to `^1.0.0-alpha.18`
* **@reventlessdev/online-shop-hybrid-ordering** updated to `^1.0.0-alpha.18`


# 1.0.0-alpha.19 (2026-04-15)

### Features

* zero-touch plugin assembly — generate Plugin.res from folder structure ([73ea654](https://github.com/ReventlessDev/reventless-core/commit/73ea654ab9a73f15ea7e18631e8194bfe0f4580f))


# 1.0.0-alpha.18 (2026-04-12)

### Features

* **commands:** extend CommandAccepted with entityId and eventCount ([747b85d](https://github.com/ReventlessDev/reventless-core/commit/747b85dc50042124f360627c5489321eea0d26e4))


# 1.0.0-alpha.17 (2026-04-09)

### Dependency Updates

* **@reventlessdev/online-shop-hybrid-ordering** updated to `^1.0.0-alpha.16`


# 1.0.0-alpha.16 (2026-04-07)

### Dependency Updates

* **@reventlessdev/online-shop-hybrid-catalog** updated to `^1.0.0-alpha.16`
* **@reventlessdev/online-shop-hybrid-ordering** updated to `^1.0.0-alpha.15`


# 1.0.0-alpha.15 (2026-04-07)

### Dependency Updates

* **@reventlessdev/online-shop-hybrid-catalog** updated to `^1.0.0-alpha.15`
* **@reventlessdev/online-shop-hybrid-ordering** updated to `^1.0.0-alpha.14`


# 1.0.0-alpha.14 (2026-04-06)

### Bug Fixes

* add package-specs to all rescript.json to prevent CJS .js output ([780f1e0](https://github.com/ReventlessDev/reventless-core/commit/780f1e035173b73b17b78466ad01fb69c7cca350))


# 1.0.0-alpha.13 (2026-04-06)

### Dependency Updates

* **@reventlessdev/online-shop-hybrid-catalog** updated to `^1.0.0-alpha.13`
* **@reventlessdev/online-shop-hybrid-ordering** updated to `^1.0.0-alpha.12`


# 1.0.0-alpha.12 (2026-04-05)

### Dependency Updates

* **@reventlessdev/online-shop-hybrid-catalog** updated to `^1.0.0-alpha.12`
* **@reventlessdev/online-shop-hybrid-ordering** updated to `^1.0.0-alpha.11`


# 1.0.0-alpha.11 (2026-04-04)

### Features

* migrate online-shop-hybrid example to reventless-ppx ([ac66980](https://github.com/ReventlessDev/reventless-core/commit/ac669807bf94b061b85e0217f1ec76af50d12a44))


# 1.0.0-alpha.10 (2026-04-03)

### Dependency Updates

* **@reventlessdev/online-shop-hybrid-catalog** updated to `^1.0.0-alpha.10`


# 1.0.0-alpha.9 (2026-03-30)

### Features

* **examples:** publish example packages to GitHub Package Registry ([2495ba5](https://github.com/ReventlessDev/reventless-core/commit/2495ba5c4436613d58964f9948c1bacbde61965f))


# [1.0.0-alpha.8](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/online-shop-hybrid-platform@1.0.0-alpha.6...@reventlessdev/online-shop-hybrid-platform@1.0.0-alpha.8) (2026-03-28)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform





# [1.0.0-alpha.7](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/online-shop-hybrid-platform@1.0.0-alpha.6...@reventlessdev/online-shop-hybrid-platform@1.0.0-alpha.7) (2026-03-27)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform





# [1.0.0-alpha.6](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/online-shop-hybrid-platform@1.0.0-alpha.3...@reventlessdev/online-shop-hybrid-platform@1.0.0-alpha.6) (2026-03-27)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform





# [1.0.0-alpha.5](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/online-shop-hybrid-platform@1.0.0-alpha.3...@reventlessdev/online-shop-hybrid-platform@1.0.0-alpha.5) (2026-03-26)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform





# [1.0.0-alpha.4](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/online-shop-hybrid-platform@1.0.0-alpha.3...@reventlessdev/online-shop-hybrid-platform@1.0.0-alpha.4) (2026-03-26)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform





# [1.0.0-alpha.3](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/online-shop-hybrid-platform@1.0.0-alpha.2...@reventlessdev/online-shop-hybrid-platform@1.0.0-alpha.3) (2026-03-23)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform

# [1.0.0-alpha.2](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/online-shop-hybrid-platform@1.0.0-alpha.1...@reventlessdev/online-shop-hybrid-platform@1.0.0-alpha.2) (2026-03-22)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform

# 1.0.0-alpha.1 (2026-03-17)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-platform

# [1.0.0-alpha.0](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/online-shop-hybrid@0.1.0-alpha.2...@reventlessdev/online-shop-hybrid@1.0.0-alpha.0) (2026-03-16)

* feat!: replace Core component with Platform_Admin, rename schema prefix Core_ → Admin_ ([940263d](https://github.com/ReventlessDev/reventless-core/commit/940263d8b39e28f4c874af3b0335ae81444928c4))
### Features

* internalize scheduler, Core, and setup in Platform.makePlatform ([ce3e1b6](https://github.com/ReventlessDev/reventless-core/commit/ce3e1b60e8ffdbab1a6b5cd08d73f5e907726481))
* read version from package.json, make cloner opt-in, log platform version ([d8216a1](https://github.com/ReventlessDev/reventless-core/commit/d8216a1d569064ca14eff6e0c3be86923e5b84ad))

### BREAKING CHANGES

* GraphQL/MCP field names change from Core_ to Admin_
prefix (e.g. Core_Plugin → Admin_Plugin). makePlatform no longer accepts
~extensionPoints, ~aggregates, ~readModels, ~dcbSpec parameters.
# [0.1.0-alpha.2](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/online-shop-hybrid@0.1.0-alpha.1...@reventlessdev/online-shop-hybrid@0.1.0-alpha.2) (2026-03-14)

### Features

* add optional DCB spec support to Core module and consolidate builder helpers ([06a5e6f](https://github.com/ReventlessDev/reventless-core/commit/06a5e6f2eeadbabd20fb7197318d760b91c34925))
# [0.1.0-alpha.1](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/online-shop-hybrid@0.1.0-alpha.0...@reventlessdev/online-shop-hybrid@0.1.0-alpha.1) (2026-03-12)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid

# 0.1.0-alpha.0 (2026-03-08)

### Features

* **examples:** add online-shop-hybrid example with aggregate + DCB composition ([296ad05](https://github.com/ReventlessDev/reventless-core/commit/296ad05f067c53854d4cf0a5d4a8deb91d751b04))
