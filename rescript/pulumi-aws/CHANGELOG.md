# Change Log

All notable changes to this project will be documented in this file.
See [Conventional Commits](https://conventionalcommits.org) for commit guidelines.

# 3.0.0-alpha.2 (2026-08-21)

### Bug Fixes

* **core:** make @resolves/[@resolves](https://github.com/resolves)Many work end to end ([4c52957](https://github.com/ReventlessDev/reventless-core/commit/4c5295759dcb4b3eda4f0f4f2c1bc387fed88fcb))
* **deps:** update sury to 11.0.0-rc.2 to fix unreachable union constructors ([fa5744f](https://github.com/ReventlessDev/reventless-core/commit/fa5744fed8de975e2f14725c856c6e5ce7d04a74))


# 3.0.0-alpha.1 (2026-08-18)

### Bug Fixes

* **aws:** normalize the null a table without a sort key resolves to ([8fb15ac](https://github.com/ReventlessDev/reventless-core/commit/8fb15ac066679b6799f4287c2c8d332e2367f599))


# 3.0.0-alpha.0 (2026-08-18)

* feat(sury)!: migrate to sury 11.0.0-rc.1 ([2cf8969](https://github.com/ReventlessDev/reventless-core/commit/2cf8969a222ce1b775563668a4126cb20611966c))
### Features

* **pulumi-aws:** expose recovery actions and M-of-N on metric alarms ([0062155](https://github.com/ReventlessDev/reventless-core/commit/00621553ffc56f29a2395d444e898175ec409cbc))

### BREAKING CHANGES

* sury is a direct dependency of the published packages and
its schema and serialization surface changed; consumers must migrate to
sury 11.



# 2.4.0-alpha.80 (2026-08-18)

### Bug Fixes

* **aws:** make the unowned stub callable on the doors that call it ([931aa39](https://github.com/ReventlessDev/reventless-core/commit/931aa3968ae0e29befab7183125ed2453d4765cb))
### Features

* **aws:** compile every resolver against AppSync before the deploy attaches one ([635bc26](https://github.com/ReventlessDev/reventless-core/commit/635bc265c63e19f1a69f31dfefe116b523b1c39b))


# 2.4.0-alpha.79 (2026-08-18)

### Bug Fixes

* **api:** make the by-index door answer, and let an elevated caller widen it ([0fe0c6f](https://github.com/ReventlessDev/reventless-core/commit/0fe0c6f8dec6228ecaba39577e28d780b4f79c83))
* **aws:** apply [@owner](https://github.com/owner) on the DynamoDB by-ids and by-index doors ([a6b5afc](https://github.com/ReventlessDev/reventless-core/commit/a6b5afc2923bfa4d3e0b2990367f67e8ffdd8877))
* **aws:** narrow retirement on every DynamoDB door, not only the list ([d6a799b](https://github.com/ReventlessDev/reventless-core/commit/d6a799b287b28e9c1f75e193adbf3f6328a6bf2d))
### Features

* **core:** let a reference name a retired row, and let an elevated caller open one ([9e2623a](https://github.com/ReventlessDev/reventless-core/commit/9e2623a4b22487561607fcc0ca19d51726069ee4))


# 2.4.0-alpha.78 (2026-08-16)

### Bug Fixes

* **aws:** scope by-key reads to the owner, not only lists ([8232fd4](https://github.com/ReventlessDev/reventless-core/commit/8232fd4c09c1098c7265e4a17882ee44884f3bec))


# 2.4.0-alpha.77 (2026-08-16)

### Features

* **core:** exclude retired rows from reads a caller may not widen ([662f31a](https://github.com/ReventlessDev/reventless-core/commit/662f31abb717bda5154199d349da6dcf8e2d3e78))
* **core:** let [@retired](https://github.com/retired) name a lifecycle state, not only a boolean ([6bb346b](https://github.com/ReventlessDev/reventless-core/commit/6bb346b4f6a5f33826fc24537953482a76067177))
* **core:** mark the state that retires a row, and allow more than one ([cb1461f](https://github.com/ReventlessDev/reventless-core/commit/cb1461f024d3ca3b53fd9c8b010a054e3fcc4555))


# 2.4.0-alpha.76 (2026-08-15)

**Note:** Version bump only for package @reventlessdev/rescript-pulumi-aws





# 2.4.0-alpha.75 (2026-08-14)

**Note:** Version bump only for package @reventlessdev/rescript-pulumi-aws





# 2.4.0-alpha.74 (2026-08-13)

**Note:** Version bump only for package @reventlessdev/rescript-pulumi-aws





# 2.4.0-alpha.73 (2026-08-13)

**Note:** Version bump only for package @reventlessdev/rescript-pulumi-aws





# 2.4.0-alpha.72 (2026-08-13)

**Note:** Version bump only for package @reventlessdev/rescript-pulumi-aws





# 2.4.0-alpha.71 (2026-08-12)

### Features

* **queries:** narrow owner-bearing reads to the caller ([ba9cc3d](https://github.com/ReventlessDev/reventless-core/commit/ba9cc3d58d7914a9e4827bda90a704a74b1b82dd))


# 2.4.0-alpha.70 (2026-08-11)

**Note:** Version bump only for package @reventlessdev/rescript-pulumi-aws





# 2.4.0-alpha.69 (2026-08-09)

**Note:** Version bump only for package @reventlessdev/rescript-pulumi-aws





# 2.4.0-alpha.68 (2026-08-09)

**Note:** Version bump only for package @reventlessdev/rescript-pulumi-aws





# 2.4.0-alpha.67 (2026-08-08)

### Bug Fixes

* **aws:** create a Lambda's log group before the function that writes to it ([8d1e459](https://github.com/ReventlessDev/reventless-core/commit/8d1e4591127489d2ae8e84e7ade3843a1a859eb6))


# 2.4.0-alpha.66 (2026-08-05)

**Note:** Version bump only for package @reventlessdev/rescript-pulumi-aws





# 2.4.0-alpha.65 (2026-08-03)

**Note:** Version bump only for package @reventlessdev/rescript-pulumi-aws





# 2.4.0-alpha.64 (2026-08-02)

**Note:** Version bump only for package @reventlessdev/rescript-pulumi-aws





# 2.4.0-alpha.63 (2026-08-02)

### Features

* **aws,core,spec,seed-aws:** expire uploads nobody committed a reference to ([f63e84c](https://github.com/ReventlessDev/reventless-core/commit/f63e84c1a11cc350b799a6f69a2e7427cf1ea6e9))


# 2.4.0-alpha.62 (2026-07-31)

**Note:** Version bump only for package @reventlessdev/rescript-pulumi-aws





# 2.4.0-alpha.61 (2026-07-27)

**Note:** Version bump only for package @reventlessdev/rescript-pulumi-aws





# 2.4.0-alpha.60 (2026-07-26)

### Features

* **example:** activate geocoder + upload services in platform-aws deploy ([e684d66](https://github.com/ReventlessDev/reventless-core/commit/e684d66bc4ce844ae36e8292ed0b78fd965490ff))


# 2.4.0-alpha.59 (2026-07-23)

### Bug Fixes

* **aws:** round-trip the DynamoDB Scan cursor in full-list connections ([0e21008](https://github.com/ReventlessDev/reventless-core/commit/0e2100860767a153a5c2f50a88fd6b501787c7f4))


# 2.4.0-alpha.58 (2026-07-22)

### Bug Fixes

* **aws:** tag every taggable resource the framework still left bare ([d4f7a90](https://github.com/ReventlessDev/reventless-core/commit/d4f7a908bcaf686ff59a85e300efac4e5e6199df))


# 2.4.0-alpha.57 (2026-07-22)

### Features

* **pulumi-aws:** expose tags on IAM, EventRule and AppSync GraphQLApi ([3b147b3](https://github.com/ReventlessDev/reventless-core/commit/3b147b323a35d711bcd3efdd1781f1afa66f2a95))


# 2.4.0-alpha.56 (2026-07-19)

### Features

* **rescript-aws:** S3 ListObjectVersions + BucketNotification bindings ([f0d464a](https://github.com/ReventlessDev/reventless-core/commit/f0d464aedacea930c56aab4849637316fc151dc5))


# 2.4.0-alpha.55 (2026-07-17)

**Note:** Version bump only for package @reventlessdev/rescript-pulumi-aws





# 2.4.0-alpha.54 (2026-07-16)

**Note:** Version bump only for package @reventlessdev/rescript-pulumi-aws





# 2.4.0-alpha.53 (2026-07-14)

### Features

* surface masked GraphQL resolver errors server-side (local + AWS) ([b3bca51](https://github.com/ReventlessDev/reventless-core/commit/b3bca51b539e40c604b3db338d570de6215ea837))


# 2.4.0-alpha.52 (2026-07-14)

### Features

* **local:** plugin=subgraph composition — per-plugin subschemas merged at start (Phase 6, plan complete) ([40f44c5](https://github.com/ReventlessDev/reventless-core/commit/40f44c5c6aa32fbbd64f362841cf41ba4e2fc2e0))


# 2.4.0-alpha.51 (2026-07-14)

### Features

* **pulumi-aws:** AppSync Merged API bindings (apiType, mergedApiExecutionRoleArn, SourceApiAssociation) ([f020e87](https://github.com/ReventlessDev/reventless-core/commit/f020e871fdd1f5ae3a0395eb73bc24589139e40e))


# 2.4.0-alpha.50 (2026-07-11)

**Note:** Version bump only for package @reventlessdev/rescript-pulumi-aws





# 2.4.0-alpha.49 (2026-07-11)

### Features

* **pulumi-aws:** add email/https/application SNS subscription protocols ([9c70d81](https://github.com/ReventlessDev/reventless-core/commit/9c70d81a92b7f28023850114868142aca828f5ff))


# 2.4.0-alpha.48 (2026-07-11)

### Features

* **monitoring:** deploy-time Monitoring hook seam for provisioned execution units ([30f1c23](https://github.com/ReventlessDev/reventless-core/commit/30f1c23ba118805dae83af9115341f4aff6db92b))


# 2.4.0-alpha.47 (2026-07-08)

### Bug Fixes

* **reventless-aws:** exclude internal rows from Platform_Plugins connection scan ([df14af2](https://github.com/ReventlessDev/reventless-core/commit/df14af2cbd70d49062f2afc03418cdbf18d151d6))


# 2.4.0-alpha.46 (2026-07-06)

### Features

* **rescript-pulumi-aws:** add subnetIds to EC2_VpcEndpoint binding ([77fb606](https://github.com/ReventlessDev/reventless-core/commit/77fb6069d76b8026c7c12db433e5f6717b037d39))
* **reventless-aws:** deploy-time Postgres schema provisioning via in-VPC migration Lambda (A3) ([44c8eee](https://github.com/ReventlessDev/reventless-core/commit/44c8eeebd351e883f2d2e21460108e2963a061ce))


# 2.4.0-alpha.45 (2026-07-05)

### Features

* **rescript-pulumi-aws:** add RDS, Secrets Manager, and Lambda VPC bindings ([9b4fb3d](https://github.com/ReventlessDev/reventless-core/commit/9b4fb3d0b4173cc6f645a903801e59901dbbdeb2))
* **reventless-aws:** add PgConnection component + wire reventless-postgres dep ([a403a62](https://github.com/ReventlessDev/reventless-core/commit/a403a6292381513cfe679a2f7a967fda0ab00c0e))


# 2.4.0-alpha.44 (2026-06-27)

**Note:** Version bump only for package @reventlessdev/rescript-pulumi-aws





# 2.4.0-alpha.43 (2026-06-21)

### Features

* **dcb:** provision CloudWatch metric filters for retry/conflict signal (AWS) ([e9a1356](https://github.com/ReventlessDev/reventless-core/commit/e9a13567c3622c83cf3becb24a47fba36fd751f5))


# 2.4.0-alpha.42 (2026-06-18)

**Note:** Version bump only for package @reventlessdev/rescript-pulumi-aws





# 2.4.0-alpha.41 (2026-06-17)

### Bug Fixes

* **packaging:** executable ppx binaries + promote phantom deps for standalone installs ([9b6bea2](https://github.com/ReventlessDev/reventless-core/commit/9b6bea24570b0b0654c825d560ef781c0295512a))


# 2.4.0-alpha.40 (2026-06-10)

**Note:** Version bump only for package @reventlessdev/rescript-pulumi-aws





# 2.4.0-alpha.39 (2026-06-06)

**Note:** Version bump only for package @reventlessdev/rescript-pulumi-aws





# 2.4.0-alpha.38 (2026-06-04)

**Note:** Version bump only for package @reventlessdev/rescript-pulumi-aws





# 2.4.0-alpha.37 (2026-05-28)

### Bug Fixes

* **pulumi-aws:** filter nulls from batchGetItemsByIds response ([ece55de](https://github.com/ReventlessDev/reventless-core/commit/ece55dec5d85e899ec919602414e15adb54262db))


# 2.4.0-alpha.36 (2026-05-27)

### Features

* **pulumi-aws:** auto-resolve Lambda layer ARN from SSM for local deploys ([6d5c539](https://github.com/ReventlessDev/reventless-core/commit/6d5c53938866e1669f280c4626487925833a474c))


# 2.4.0-alpha.35 (2026-05-25)

**Note:** Version bump only for package @reventlessdev/rescript-pulumi-aws





# 2.4.0-alpha.34 (2026-05-25)

### Features

* **host-ui:** auto-provision custom domain when baseDomain + zoneId are set ([3491f86](https://github.com/ReventlessDev/reventless-core/commit/3491f8666b6965d2ace48bf1e86d64f263f42aab))


# 2.4.0-alpha.33 (2026-05-20)

**Note:** Version bump only for package @reventlessdev/rescript-pulumi-aws





# 2.4.0-alpha.32 (2026-05-20)

### Bug Fixes

* **aws:** make AutoUI lists live-update by fixing Events API auth + channel root ([9ebe4b8](https://github.com/ReventlessDev/reventless-core/commit/9ebe4b80c606ef27cc014dac844c2c1acd65c29f))


# 2.4.0-alpha.31 (2026-05-19)

**Note:** Version bump only for package @reventlessdev/rescript-pulumi-aws





# 2.4.0-alpha.30 (2026-05-19)

### Features

* **api:** batched-by-ids query field for single-key projections ([d5d836d](https://github.com/ReventlessDev/reventless-core/commit/d5d836de52a478fb096965d7c83882d6ef302508))
* **aws:** subscribeAuth registry on AppSync_EventsApi; extend ChannelNamespace binding ([47bbfb9](https://github.com/ReventlessDev/reventless-core/commit/47bbfb9122d9fa1221101ac77039f1a3aae55e87))


# 2.4.0-alpha.29 (2026-05-19)

### Features

* **platform:** commandHandlerConfig for per-flavor Lambda tuning ([4154061](https://github.com/ReventlessDev/reventless-core/commit/4154061d9343f90ce61955992d9119d0f7a251e1))


# 2.4.0-alpha.28 (2026-05-17)

### Bug Fixes

* **deps:** pin sury-ppx to 11.0.0-alpha.2 to prevent prerelease drift ([c9d05fe](https://github.com/ReventlessDev/reventless-core/commit/c9d05fe5118a9c0442ca3e071f2606b3a139fc81))


# 2.4.0-alpha.27 (2026-05-17)

### Bug Fixes

* **deps:** pin sury to 11.0.0-alpha.4 to unblock Lambda Layer deploys ([643d925](https://github.com/ReventlessDev/reventless-core/commit/643d92527fa9d092da9bef8547591e39a4c609dd))


# 2.4.0-alpha.26 (2026-05-16)

**Note:** Version bump only for package @reventlessdev/rescript-pulumi-aws





# 2.4.0-alpha.25 (2026-05-14)

### Features

* **auth:** Stage C — Cognito UserPool provisioning + A4 hydration fixup ([08d98e0](https://github.com/ReventlessDev/reventless-core/commit/08d98e00fc18de019190d7e6e977b09375d8ff61))
* **auth:** Stage D — Cognito AppSync auth + Auth_Cognito provider ([6e4ce64](https://github.com/ReventlessDev/reventless-core/commit/6e4ce643490c9683e89cd0fe25f6fd44659ccd69))
* **aws:** short-TTL cache behaviors for unhashed bundle entry points ([300964b](https://github.com/ReventlessDev/reventless-core/commit/300964bea011a7844abd65b5bd0fafc1c3f7eb4d))


# 2.4.0-alpha.24 (2026-05-03)

### Bug Fixes

* **appsync:** IAM-safe identity in command/mutation resolvers ([3098ea0](https://github.com/ReventlessDev/reventless-core/commit/3098ea0b06d1eccc7c5d28470ab4824a3bf7df43))


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
