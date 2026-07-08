# Change Log

All notable changes to this project will be documented in this file.
See [Conventional Commits](https://conventionalcommits.org) for commit guidelines.

# 3.0.0-alpha.186 (2026-07-08)

### Bug Fixes

* **reventless-core:** composite DCB slices can read back their own events ([4604a91](https://github.com/ReventlessDev/reventless-core/commit/4604a9159fb8bf59b2191ad69fee6613c7f75cd9))


# 3.0.0-alpha.185 (2026-07-08)

### Bug Fixes

* **reventless-aws:** thread partitionTag into deployed DCB command Lambda append ([68f0859](https://github.com/ReventlessDev/reventless-core/commit/68f0859d3d5e44f6217a5dc0d8537cfec3d21194))


# 3.0.0-alpha.184 (2026-07-08)

### Bug Fixes

* **reventless-aws:** exclude internal rows from Platform_Plugins connection scan ([df14af2](https://github.com/ReventlessDev/reventless-core/commit/df14af2cbd70d49062f2afc03418cdbf18d151d6))


# 3.0.0-alpha.183 (2026-07-08)

### Bug Fixes

* **reventless-aws:** stop admin-base schema clobber of split-mode DomainApi ([afce85f](https://github.com/ReventlessDev/reventless-core/commit/afce85fa57474735cea3dcb1c2a151c2d8804f0e))


# 3.0.0-alpha.182 (2026-07-07)

### Bug Fixes

* **reventless-aws:** fence composite-partition DCB slices on one composite key ([e5f2d95](https://github.com/ReventlessDev/reventless-core/commit/e5f2d95652d795e4dea60e28548f96100a997e78))


# 3.0.0-alpha.181 (2026-07-07)

### Bug Fixes

* **reventless-aws:** thread inferred DCB scope into the deployed command handler ([4d8327f](https://github.com/ReventlessDev/reventless-core/commit/4d8327fad8659a1cde8c36098c72392737437af1))


# 3.0.0-alpha.180 (2026-07-07)

### Bug Fixes

* **reventless-aws:** type-level dual-auth + derived query fields for system callers ([91e01f8](https://github.com/ReventlessDev/reventless-core/commit/91e01f82f43f64f07e7eb0a4aaa8cf5dc77a916e))


# 3.0.0-alpha.179 (2026-07-07)

### Bug Fixes

* **reventless-postgres:** keep [@pulumi](https://github.com/pulumi) out of the deployed Lambda runtime graph ([0f363cd](https://github.com/ReventlessDev/reventless-core/commit/0f363cd273590591c8f9353fa38ac8b6072e6c49))


# 3.0.0-alpha.178 (2026-07-06)

### Bug Fixes

* **reventless-aws:** make deployed ESM Lambdas self-contained via layer resolver hook ([3fc768c](https://github.com/ReventlessDev/reventless-core/commit/3fc768cba5ef72fca6e4a706eb855f67ac7f0b30))
### Features

* **reventless-aws:** auth-table pipeline for group-restricted Postgres indexes (B3.2c) ([52be859](https://github.com/ReventlessDev/reventless-core/commit/52be8590ed934a2ffbc898cef381ca4ce50d8cda))
* **reventless-aws:** deploy-time Postgres schema provisioning via in-VPC migration Lambda (A3) ([44c8eee](https://github.com/ReventlessDev/reventless-core/commit/44c8eeebd351e883f2d2e21460108e2963a061ce))
* **reventless-aws:** expose DCB Postgres lock-strategy knob (C2) ([3991862](https://github.com/ReventlessDev/reventless-core/commit/3991862aa50eb939796413236a04deae80a61aa3))
* **reventless-aws:** Postgres read-model live updates via projection Lambda (B3.3) ([ff8fc43](https://github.com/ReventlessDev/reventless-core/commit/ff8fc43049a8fc7134e340a473c2a1665a139140))
* **reventless-aws:** provision the Postgres read path in plugin-stack mode (B3.2) ([719efbc](https://github.com/ReventlessDev/reventless-core/commit/719efbc20ab6e8bf5bb46499150fe07e54d9eca5))


# 3.0.0-alpha.177 (2026-07-06)

### Features

* **reventless-aws:** AppSync read path for Postgres read models (B3.2b) ([a6dd6cb](https://github.com/ReventlessDev/reventless-core/commit/a6dd6cbddfc65410bf96da49bb2603c88670aced))
* **reventless-aws:** cross-table @resolves/[@resolves](https://github.com/resolves)Many + node resolvers for Postgres reads (B3.2c) ([713b6ab](https://github.com/ReventlessDev/reventless-core/commit/713b6ab736715209e7198b2b4ab609c5447adef5))
* **reventless-postgres,reventless-aws:** items (sub-id connection) resolver for Postgres reads (B3.2c) ([2477220](https://github.com/ReventlessDev/reventless-core/commit/247722062913f5d0bcb5895b152f05033d8297d8))


# 3.0.0-alpha.176 (2026-07-06)

### Bug Fixes

* **reventless-aws:** QueryEngine deploy crash on resource-less Postgres QueryDbs (B3.1b) ([a11b5d6](https://github.com/ReventlessDev/reventless-core/commit/a11b5d6f0797f1c9324f2a4ff3ba4197c20e721b))
### Features

* **reventless-aws:** classic EventLog Postgres deploy-time wiring + relay (B1 vertical) ([8235ba4](https://github.com/ReventlessDev/reventless-core/commit/8235ba44e506f7094d17251405c6a05c39789805))
* **reventless-aws:** PgQueryResolver Lambda dispatcher for Postgres GraphQL reads (B3.2a-2) ([140d2bd](https://github.com/ReventlessDev/reventless-core/commit/140d2bd44c2443a03de16e21fd29d5a66b5db9be))
* **reventless-aws:** Postgres projection delivery via relay feed queues (B3.0) ([80a0ffb](https://github.com/ReventlessDev/reventless-core/commit/80a0ffb1696902a1df99acca1f7915dd65e5c016))
* **reventless-aws:** Postgres QueryDb storage vertical (B3.1) ([51a7993](https://github.com/ReventlessDev/reventless-core/commit/51a79934c1d9f59bb6f61233a90651d5eadf9f4e))


# 3.0.0-alpha.175 (2026-07-05)

**Note:** Version bump only for package @reventlessdev/reventless-aws





# 3.0.0-alpha.174 (2026-07-05)

### Features

* @[@reventless](https://github.com/reventless).systemCallable slice opt-in for deploy-time system callers ([c5ed537](https://github.com/ReventlessDev/reventless-core/commit/c5ed537309f8e4b7d4a4d4af1ed1ec83d060aea3))
* **reventless-aws:** deploy-time Postgres selection for DCB EventLog (B2.3c) ([c9ac79e](https://github.com/ReventlessDev/reventless-core/commit/c9ac79e890e183874e81ee562ed0938d1efb02df))
* **reventless-aws:** Postgres change-feed relay auto-wiring (B2.3d) ([62b430f](https://github.com/ReventlessDev/reventless-core/commit/62b430f1e6d8ec1f172de0cca324f7f26aaf5fcb))


# 3.0.0-alpha.173 (2026-07-05)

### Features

* **reventless-aws:** aggregate EventLog Postgres runtime + entry-point branch ([fd81ece](https://github.com/ReventlessDev/reventless-core/commit/fd81ece65c2bf6aebf227d74ec2d0f002833d351))
* **reventless-aws:** DCB EventLog Postgres runtime + entry-point branch (B2.1) ([a6b4f8d](https://github.com/ReventlessDev/reventless-core/commit/a6b4f8d34509ff7213273a1f71f31705b625ff40)), closes [#4](https://github.com/ReventlessDev/reventless-core/issues/4)
* **reventless-aws:** opt-in [@aws](https://github.com/aws)_iam dual-auth for deploy-time AppSync callers ([94037f1](https://github.com/ReventlessDev/reventless-core/commit/94037f17ae48a33415b02e8e7b178906be8b59a4))
* **reventless-aws:** Postgres change-feed relay deploy builder + Lambda VPC (B2.3a/b, C1) ([64d67f3](https://github.com/ReventlessDev/reventless-core/commit/64d67f3ecd2c42d59ba814d6d821683ae8c81612))
* **reventless-aws:** Postgres change-feed relay runtime (B2.2) ([9ccb601](https://github.com/ReventlessDev/reventless-core/commit/9ccb60192457e9da21869e0d1c98fe8dbfb42178))


# 3.0.0-alpha.172 (2026-07-05)

### Bug Fixes

* **reventless-aws:** sub-select CommandResult in AppSync mutation caller ([24cf37c](https://github.com/ReventlessDev/reventless-core/commit/24cf37cc537215b9523d1eac4a0f8ac6c610257d))
### Features

* **postgres:** add reventless-postgres backend + local-platform integration ([6913200](https://github.com/ReventlessDev/reventless-core/commit/69132001f9271e832a5af33416acd5b645feaf47))
* **postgres:** cold-start pool foundation for AWS Postgres adapters ([b393449](https://github.com/ReventlessDev/reventless-core/commit/b393449769b6cd92abd03d2d5e7f564fe092938e))
* **reventless-aws:** add PgConnection component + wire reventless-postgres dep ([a403a62](https://github.com/ReventlessDev/reventless-core/commit/a403a6292381513cfe679a2f7a967fda0ab00c0e))


# 3.0.0-alpha.171 (2026-07-04)

**Note:** Version bump only for package @reventlessdev/reventless-aws





# 3.0.0-alpha.170 (2026-07-03)

### Features

* **core,local,aws:** EventLog snapshot storage surface, all backends (aggregate-snapshotting plan, steps 3+4) ([b6e50e2](https://github.com/ReventlessDev/reventless-core/commit/b6e50e2e5fe50b7372e54811f883fa91f6758dd1))


# 3.0.0-alpha.169 (2026-07-02)

**Note:** Version bump only for package @reventlessdev/reventless-aws





# 3.0.0-alpha.168 (2026-06-29)

**Note:** Version bump only for package @reventlessdev/reventless-aws





# 3.0.0-alpha.167 (2026-06-27)

**Note:** Version bump only for package @reventlessdev/reventless-aws





# 3.0.0-alpha.166 (2026-06-23)

### Bug Fixes

* **dcb:** scope DynamoDB consistency fences per event type ([a20646f](https://github.com/ReventlessDev/reventless-core/commit/a20646f31a33041871f123cf66e65dd8dff429c3))


# 3.0.0-alpha.165 (2026-06-22)

**Note:** Version bump only for package @reventlessdev/reventless-aws





# 3.0.0-alpha.164 (2026-06-21)

### Bug Fixes

* **aws:** plumb tagKeysByEventType/crossPartitionTagKeys + grant ConditionCheckItem ([8d29fc4](https://github.com/ReventlessDev/reventless-core/commit/8d29fc45ccf92c004d7120d34f603716f34803b8))


# 3.0.0-alpha.163 (2026-06-21)

### Features

* **dcb:** cross-partition secondary-tag reads (Phase 7) ([9e1f8b3](https://github.com/ReventlessDev/reventless-core/commit/9e1f8b3595004b92148dd053aae380078baa42a3))
### Performance Improvements

* **dcb:** down-project per-tag DCB GSIs to KEYS_ONLY ([ac9305b](https://github.com/ReventlessDev/reventless-core/commit/ac9305b3456ea7f9bd672c5863a79081dc1ac44f))


# 3.0.0-alpha.162 (2026-06-21)

### Bug Fixes

* **appsync:** use throw instead of deprecated raise ([6b9fd40](https://github.com/ReventlessDev/reventless-core/commit/6b9fd4080e90eac76b9abc6ec029f08a0734a607))
### Features

* **dcb:** eventual-first, strong-on-retry decision reads ([b920a66](https://github.com/ReventlessDev/reventless-core/commit/b920a663c1dbb3a13cb8bd27ecbfe0cfd8ec5d65))
* **dcb:** provision CloudWatch metric filters for retry/conflict signal (AWS) ([e9a1356](https://github.com/ReventlessDev/reventless-core/commit/e9a13567c3622c83cf3becb24a47fba36fd751f5))


# 3.0.0-alpha.161 (2026-06-21)

### Features

* **appsync:** serialize deploy-time schema pushes with a shared lease ([b7d8af0](https://github.com/ReventlessDev/reventless-core/commit/b7d8af076e0af594179b64142d894b8b6ce0ac7d))


# 3.0.0-alpha.160 (2026-06-20)

### Bug Fixes

* **appsync:** shrink-guard the deploy-time schema push against concurrent clobber ([15473d7](https://github.com/ReventlessDev/reventless-core/commit/15473d7eff920385092ef2e37efece2c70b4a849))
* **dcb:** always exclude fence sentinels from scan reads (Issue 12) ([80f7658](https://github.com/ReventlessDev/reventless-core/commit/80f7658015bf668e92c8c8e02ceb8f837f4c43f9))


# 3.0.0-alpha.159 (2026-06-20)

### Bug Fixes

* **dcb:** close the after=None create-race with a per-type create guard ([e5a834b](https://github.com/ReventlessDev/reventless-core/commit/e5a834bbffd1cafdd16e2e691a5999dfd86f65b4))
* **dcb:** scope DynamoDB consistency fences to the partition tag ([2ecbd85](https://github.com/ReventlessDev/reventless-core/commit/2ecbd8599a6466c3a25299f4506dd5c5993367a8))
* **state-view-slice:** compress HANDLER_CONFIG under Lambda 4KB env limit ([c7aa606](https://github.com/ReventlessDev/reventless-core/commit/c7aa6064024de183def6ed73f453d6c5309aa63f))


# 3.0.0-alpha.158 (2026-06-20)

**Note:** Version bump only for package @reventlessdev/reventless-aws





# 3.0.0-alpha.157 (2026-06-20)

**Note:** Version bump only for package @reventlessdev/reventless-aws





# 3.0.0-alpha.156 (2026-06-20)

**Note:** Version bump only for package @reventlessdev/reventless-aws





# 3.0.0-alpha.155 (2026-06-18)

**Note:** Version bump only for package @reventlessdev/reventless-aws





# 3.0.0-alpha.154 (2026-06-18)

**Note:** Version bump only for package @reventlessdev/reventless-aws





# 3.0.0-alpha.153 (2026-06-18)

### Bug Fixes

* **aws:** run all runtime handlers sharing one source stream ([8a9546b](https://github.com/ReventlessDev/reventless-core/commit/8a9546b03156f50df309cc5ee935228b32581713))
### Features

* **admin:** expose PluginHistory as a visible admin read model ([8a1d86e](https://github.com/ReventlessDev/reventless-core/commit/8a1d86ee30eddefe9a363eaf041e853c1d4e4af6))


# 3.0.0-alpha.152 (2026-06-18)

### Bug Fixes

* **aws:** reject mutations on Retired plugins in the runtime status gate ([0e9afdd](https://github.com/ReventlessDev/reventless-core/commit/0e9afdd30d15f537b54c9404ddc37a78d2219ee4))
### Features

* **admin:** PluginHistory lifecycle audit view (core + AWS) ([00402ca](https://github.com/ReventlessDev/reventless-core/commit/00402ca010e3e404928e9df5ed15f6a419924d46))
* **aws:** deploy-time synthetic heartbeat for zero-downtime plugin handover ([347b14f](https://github.com/ReventlessDev/reventless-core/commit/347b14fc702f5ddb690ee9624519abf36d9a93b8))


# 3.0.0-alpha.151 (2026-06-17)

### Bug Fixes

* **admin:** dedup plugin versions in UI manifest queries ([7a21ca3](https://github.com/ReventlessDev/reventless-core/commit/7a21ca30461622287a9d3f42fe54579fbdb75eb2))


# 3.0.0-alpha.150 (2026-06-17)

### Bug Fixes

* **packaging:** executable ppx binaries + promote phantom deps for standalone installs ([9b6bea2](https://github.com/ReventlessDev/reventless-core/commit/9b6bea24570b0b0654c825d560ef781c0295512a))


# 3.0.0-alpha.149 (2026-06-12)

**Note:** Version bump only for package @reventlessdev/reventless-aws





# 3.0.0-alpha.148 (2026-06-12)

**Note:** Version bump only for package @reventlessdev/reventless-aws





# 3.0.0-alpha.147 (2026-06-11)

**Note:** Version bump only for package @reventlessdev/reventless-aws





# 3.0.0-alpha.146 (2026-06-10)

### Bug Fixes

* **aws:** deliver plugin Retire to standard command-topic queues ([f4e507d](https://github.com/ReventlessDev/reventless-core/commit/f4e507df250db8d3b96edc1251117cd8cc4be645))
* **aws:** repair StateTopic channel format so admin Plugins list live-updates ([de444b7](https://github.com/ReventlessDev/reventless-core/commit/de444b7d5a9cf6192a6880109ab77de12c07191c))
* **aws:** surface StateTopic publish failures and bound ESM retries ([6bc4e62](https://github.com/ReventlessDev/reventless-core/commit/6bc4e629d3c839778467657158f9055fe7e52e11))
* **aws:** tag Retire command with service: "Plugin" so projection picks it up ([6bd7f59](https://github.com/ReventlessDev/reventless-core/commit/6bd7f599d507a722978e15249a919b3a38aeb8b9))
* **aws:** widen EventLogSubscription channel-name rule for parity with StateTopic ([b5d30a3](https://github.com/ReventlessDev/reventless-core/commit/b5d30a35819bbea1965a25b691595dccf267fe15))
* **naming:** EP CmdHandler kind for the platform-admin Plugin extension point ([cc55347](https://github.com/ReventlessDev/reventless-core/commit/cc55347ce89a2a789cd8debd270c4ee13649d6d9))
* refactor(reventless-local)!: rename reventless-in-memory to reventless-local ([f36e17c](https://github.com/ReventlessDev/reventless-core/commit/f36e17c407714ab9740393fac96865d6a5c143c9))
### Features

* **logging:** structured JSON fields + correlationId/requestId tracing (Tier 2) ([7335638](https://github.com/ReventlessDev/reventless-core/commit/7335638c7b7da376e2368dd829c3a26290114d5e))

### BREAKING CHANGES

* @reventlessdev/reventless-in-memory -> @reventlessdev/reventless-local;
namespace ReventlessInMemory -> ReventlessLocal.



# 3.0.0-alpha.145 (2026-06-08)

### Bug Fixes

* **naming:** EP CmdHandler kind for the platform-admin Plugin extension point ([19102b9](https://github.com/ReventlessDev/reventless-core/commit/19102b908a535ca62f6a5db435032ed8275a03eb))


# 3.0.0-alpha.144 (2026-06-08)

**Note:** Version bump only for package @reventlessdev/reventless-aws





# 3.0.0-alpha.143 (2026-06-08)

### Features

* **logging:** structured JSON fields + correlationId/requestId tracing (Tier 2) ([49738c5](https://github.com/ReventlessDev/reventless-core/commit/49738c5e54f0707b4a9c6991c07c61abe41ccf64))


# 3.0.0-alpha.142 (2026-06-08)

**Note:** Version bump only for package @reventlessdev/reventless-aws





# 3.0.0-alpha.141 (2026-06-07)

**Note:** Version bump only for package @reventlessdev/reventless-aws





# 3.0.0-alpha.140 (2026-06-06)

* refactor(reventless-local)!: rename reventless-in-memory to reventless-local ([966855f](https://github.com/ReventlessDev/reventless-core/commit/966855fd31e518d56a381bf40204735809cead15))

### BREAKING CHANGES

* @reventlessdev/reventless-in-memory -> @reventlessdev/reventless-local;
namespace ReventlessInMemory -> ReventlessLocal.



# 3.0.0-alpha.139 (2026-06-04)

### Bug Fixes

* **aws:** repair StateTopic channel format so admin Plugins list live-updates ([7aaa563](https://github.com/ReventlessDev/reventless-core/commit/7aaa563246c647a913da440bd382c20c953231ab))
* **aws:** surface StateTopic publish failures and bound ESM retries ([1b0de23](https://github.com/ReventlessDev/reventless-core/commit/1b0de23c0a212ee88e9c7a54c69a511d48c896fd))
* **aws:** widen EventLogSubscription channel-name rule for parity with StateTopic ([913b17f](https://github.com/ReventlessDev/reventless-core/commit/913b17ff934640e06bda1eb012b913a27ff61ef2))


# 3.0.0-alpha.138 (2026-06-04)

### Bug Fixes

* **aws:** tag Retire command with service: "Plugin" so projection picks it up ([e1c7efd](https://github.com/ReventlessDev/reventless-core/commit/e1c7efd5d26b57e5b4caeecebf7dff77e97b8a9a))


# 3.0.0-alpha.137 (2026-06-04)

### Bug Fixes

* **aws:** deliver plugin Retire to standard command-topic queues ([c7c0158](https://github.com/ReventlessDev/reventless-core/commit/c7c0158518a56958bbcbdee27fc2631fd238d66a))


# 3.0.0-alpha.136 (2026-06-04)

**Note:** Version bump only for package @reventlessdev/reventless-aws





# 3.0.0-alpha.135 (2026-06-04)

**Note:** Version bump only for package @reventlessdev/reventless-aws





# 3.0.0-alpha.134 (2026-06-04)

**Note:** Version bump only for package @reventlessdev/reventless-aws





# 3.0.0-alpha.133 (2026-06-04)

**Note:** Version bump only for package @reventlessdev/reventless-aws





# 3.0.0-alpha.132 (2026-05-28)

### Bug Fixes

* **aws:** bundle reventless-core into DcbCommandTopic Lambda asset ([1c4fd08](https://github.com/ReventlessDev/reventless-core/commit/1c4fd089e9d4e8cc2189b1ae474ca019224ab532))
* **framework:** align DCB event tags with query tags and relax fence check when slice observed nothing ([de21635](https://github.com/ReventlessDev/reventless-core/commit/de21635bcb026d73cad0eef5561b6779df81fdc2))
* **framework:** wire user extensions with mapIncomingEvent-only to publish to their Delegate cmd-topic ([fb4644b](https://github.com/ReventlessDev/reventless-core/commit/fb4644be789b6271bebeaa1f5984f0278b45ec14))


# 3.0.0-alpha.131 (2026-05-28)

### Bug Fixes

* **aws:** keep SNS subs alive when a superseded plugin version disconnects ([e78a3ab](https://github.com/ReventlessDev/reventless-core/commit/e78a3ab0888e01968747920dc2095ce96467edbf))


# 3.0.0-alpha.130 (2026-05-28)

### Bug Fixes

* **aws:** patch Delegate.Id at runtime in EP/Extension EC Lambda wiring ([609eb83](https://github.com/ReventlessDev/reventless-core/commit/609eb8317f11c27399228feae5da962cbf7a7eec))


# 3.0.0-alpha.129 (2026-05-28)

### Bug Fixes

* **aws:** pass serviceName to runtime DcbEventLog ops in CmdTopic entry ([2881744](https://github.com/ReventlessDev/reventless-core/commit/28817440c2b61ed9adffda6e2281a01c10515c57))
* **aws:** wire plugin RM streams to StateTopic Lambda ([c874ef4](https://github.com/ReventlessDev/reventless-core/commit/c874ef4e1ef35511b650ba483bd4ac1523f50024))


# 3.0.0-alpha.128 (2026-05-28)

**Note:** Version bump only for package @reventlessdev/reventless-aws





# 3.0.0-alpha.127 (2026-05-28)

### Bug Fixes

* **aws:** handle flat-shape user-authored EP mappings in plugin EC Lambda ([fe34b36](https://github.com/ReventlessDev/reventless-core/commit/fe34b369c33589e9794729e75e3e56a871df4d97))


# 3.0.0-alpha.126 (2026-05-28)

### Bug Fixes

* **pulumi-aws:** sort handler arrays for deterministic HANDLER_CONFIG ([057e55f](https://github.com/ReventlessDev/reventless-core/commit/057e55f7e1b535619f6bc8d4a03522677f9ee8a0))


# 3.0.0-alpha.125 (2026-05-27)

### Bug Fixes

* **framework:** bundle ExtensionPoint spec/mapping packages into plugin EC Lambda ([cce9580](https://github.com/ReventlessDev/reventless-core/commit/cce95800ffeac95d54be7d2f72e3223689d24158))


# 3.0.0-alpha.124 (2026-05-27)

### Bug Fixes

* **framework:** wire plugin ExtensionPoints into EventCollector runtime context ([2ce8dff](https://github.com/ReventlessDev/reventless-core/commit/2ce8dff426b576811a28c012934d77ecba8a33c0))


# 3.0.0-alpha.123 (2026-05-27)

**Note:** Version bump only for package @reventlessdev/reventless-aws





# 3.0.0-alpha.122 (2026-05-27)

**Note:** Version bump only for package @reventlessdev/reventless-aws





# 3.0.0-alpha.121 (2026-05-27)

**Note:** Version bump only for package @reventlessdev/reventless-aws





# 3.0.0-alpha.120 (2026-05-26)

**Note:** Version bump only for package @reventlessdev/reventless-aws





# 3.0.0-alpha.119 (2026-05-26)

**Note:** Version bump only for package @reventlessdev/reventless-aws





# 3.0.0-alpha.118 (2026-05-25)

**Note:** Version bump only for package @reventlessdev/reventless-aws





# 3.0.0-alpha.117 (2026-05-25)

**Note:** Version bump only for package @reventlessdev/reventless-aws





# 3.0.0-alpha.116 (2026-05-25)

### Features

* **host-ui:** auto-provision custom domain when baseDomain + zoneId are set ([3491f86](https://github.com/ReventlessDev/reventless-core/commit/3491f8666b6965d2ace48bf1e86d64f263f42aab))
* **live-updates:** consolidate StateTopic Lambda + admin RMs live-update ([7b158c7](https://github.com/ReventlessDev/reventless-core/commit/7b158c71c97eb114d2453b81a1e8cf46e4f0bdb2))
* **readmodel:** add ReadModelStream variant for live-updating read models ([3d816fb](https://github.com/ReventlessDev/reventless-core/commit/3d816fb50e0e66693ae4a0a626f4d5b4e496c3b1))


# 3.0.0-alpha.115 (2026-05-21)

**Note:** Version bump only for package @reventlessdev/reventless-aws





# 3.0.0-alpha.114 (2026-05-21)

**Note:** Version bump only for package @reventlessdev/reventless-aws





# 3.0.0-alpha.113 (2026-05-21)

* feat(admin)!: replace direct DynamoDB retire write with Retire/Retired event flow ([7f5f018](https://github.com/ReventlessDev/reventless-core/commit/7f5f018e714e247331d143c304c0d671c2ac7c84))

### BREAKING CHANGES

* Platform.deployPlugin no longer accepts ~version. Generated
Main.res files are regenerated; any direct caller must drop the arg.



# 3.0.0-alpha.112 (2026-05-20)

### Bug Fixes

* **admin:** name the platform Plugins read model in the plural ([afa11a8](https://github.com/ReventlessDev/reventless-core/commit/afa11a8b7314bad5681006c93aa44196eb7c122f))
* **aws:** auto-invalidate CloudFront + cache-control on host-UI bundle deploys ([35c5fe4](https://github.com/ReventlessDev/reventless-core/commit/35c5fe45539af990c3e2d101b3e527a8b044460b))


# 3.0.0-alpha.111 (2026-05-20)

### Bug Fixes

* **aws:** make AutoUI lists live-update by fixing Events API auth + channel root ([9ebe4b8](https://github.com/ReventlessDev/reventless-core/commit/9ebe4b80c606ef27cc014dac844c2c1acd65c29f))


# 3.0.0-alpha.110 (2026-05-20)

### Bug Fixes

* **aws:** harden runtime AppSync schema update against transient clobber ([4d768e4](https://github.com/ReventlessDev/reventless-core/commit/4d768e434c28042242463e0341e1c543ddc12c63))
* **aws:** repair clobbered AppSync schema via drift-aware deploy push ([3ba690b](https://github.com/ReventlessDev/reventless-core/commit/3ba690b5f72ce80f7a8610bd534c845f4c83833d))
### Features

* **aws:** wire live-update Events config into host config.json + retire superseded plugin versions on deploy ([954cc47](https://github.com/ReventlessDev/reventless-core/commit/954cc47d93fc6f862a2045f73935560fbbd171ab))


# 3.0.0-alpha.109 (2026-05-20)

### Bug Fixes

* **aws:** treat "Type not found" as drift in AppSync resolver refresh ([5961503](https://github.com/ReventlessDev/reventless-core/commit/5961503a1cb42582d3bc2bc74843c753ee40252a))


# 3.0.0-alpha.108 (2026-05-20)

### Bug Fixes

* **admin:** make cross-plugin SNS subscriptions actually wire (Phase 3 Step 4) ([8f727df](https://github.com/ReventlessDev/reventless-core/commit/8f727dfb20d137fc7fcc307c80c1007eab802a26))
* **aws:** filter DCB FENCE rows from event stream parser ([a48436e](https://github.com/ReventlessDev/reventless-core/commit/a48436ef333b9d5e92b982281526045019fe791d))
* **aws:** load StateViewSlice projection module in entry point ([e8abf64](https://github.com/ReventlessDev/reventless-core/commit/e8abf64b6f1dccee7654c89d9233c62a5bf453bd))
### Features

* **plugin:** wire dcbEventLog into pluginDefinition for cross-plugin DCB routing (Phase 4) ([07b78f3](https://github.com/ReventlessDev/reventless-core/commit/07b78f359f8f039992ec0ce7922085b165695537))


# 3.0.0-alpha.107 (2026-05-19)

### Bug Fixes

* **aws:** wrap TransactWriteCommand input via .make() before .send() ([a6d65b5](https://github.com/ReventlessDev/reventless-core/commit/a6d65b50986809fc06e8888b3374019bb28df281))


# 3.0.0-alpha.106 (2026-05-19)

### Bug Fixes

* **admin:** gate admin createResolvers on schema push to eliminate API-lock race ([cfd282a](https://github.com/ReventlessDev/reventless-core/commit/cfd282a65cea981c67d27309808471a4d7bfb5a3))
* **aws:** retry AppSync ConcurrentModification on resolver create/update ([1b6b7b0](https://github.com/ReventlessDev/reventless-core/commit/1b6b7b0cd341cbb01c03d5bb9269a55c4415bd9f))


# 3.0.0-alpha.105 (2026-05-19)

### Bug Fixes

* **aws:** close AppSync resolver gaps for drift, inbound subs, slice query DBs ([8d10126](https://github.com/ReventlessDev/reventless-core/commit/8d10126168eade99e6dad19c8bac3f0dfa2240fa))
### Features

* **api:** batched-by-ids query field for single-key projections ([d5d836d](https://github.com/ReventlessDev/reventless-core/commit/d5d836de52a478fb096965d7c83882d6ef302508))
* **aws:** subscribeAuth registry on AppSync_EventsApi; extend ChannelNamespace binding ([47bbfb9](https://github.com/ReventlessDev/reventless-core/commit/47bbfb9122d9fa1221101ac77039f1a3aae55e87))
* **subscriptions:** emit change descriptor payload from StateTopic Lambda ([049cac8](https://github.com/ReventlessDev/reventless-core/commit/049cac823f7c77f74956d21a09ae7732cbbedfe4))


# 3.0.0-alpha.104 (2026-05-19)

### Bug Fixes

* **aws:** AggregateEntryPoint AppSync direct-invocation argument plumbing ([6dd3ce9](https://github.com/ReventlessDev/reventless-core/commit/6dd3ce927758cd1723cef3fdea31e4b388853575))
* **aws:** emit __typename in CommandResult mutation response ([aa05fb5](https://github.com/ReventlessDev/reventless-core/commit/aa05fb54e25fd7232b46ec9150bdd3a0c93080a8))
* **aws:** grant admin EventCollector dynamodb:Scan on Plugin RM table ([e32ae02](https://github.com/ReventlessDev/reventless-core/commit/e32ae024090500282447088f78b214b56265c22c))
* refactor(aws)!: rename DCB Lambdas to <Plugin>StateChanges[Async] ([f2b20ca](https://github.com/ReventlessDev/reventless-core/commit/f2b20ca86c66cfd88d87696d89b745d70c5f156b))
### Features

* @[@reventless](https://github.com/reventless).async opt-in; sync command dispatch as default ([85885c8](https://github.com/ReventlessDev/reventless-core/commit/85885c80a70cfcbf4e1ac068c7115e6b6cfa8400))
* **platform:** commandHandlerConfig for per-flavor Lambda tuning ([4154061](https://github.com/ReventlessDev/reventless-core/commit/4154061d9343f90ce61955992d9119d0f7a251e1))

### BREAKING CHANGES

* this is a Pulumi resource rename without `aliases`,
so `pulumi up` will destroy and recreate the DCB Lambda, its SQS
queue(s), the AppSync DataSource and resolvers, and associated IAM.
In-flight FIFO messages on async StateChangeSlices are lost. Plan a
maintenance window for stacks with sustained async DCB traffic.



# 3.0.0-alpha.103 (2026-05-18)

### Bug Fixes

* **aws:** resolve cross-plugin spec dynamic imports from /var/task asset ([003170e](https://github.com/ReventlessDev/reventless-core/commit/003170e8c2da784ceca061d606253a8212b15551))


# 3.0.0-alpha.102 (2026-05-18)

### Bug Fixes

* **aws:** pluginCallbackMake must read pluginDefinition from asset, not HANDLER_CONFIG ([52e814e](https://github.com/ReventlessDev/reventless-core/commit/52e814e53ae903fcfe1cc3ecd0d3b047fc6434ac))


# 3.0.0-alpha.101 (2026-05-18)

### Bug Fixes

* **aws:** ship pluginDefinition as bundle asset so plugin EC env vars stay under Lambda's 5120-byte limit ([f4007dc](https://github.com/ReventlessDev/reventless-core/commit/f4007dcc38bbfbb96a9228ee5880b9e347b1f9fa))


# 3.0.0-alpha.100 (2026-05-18)

**Note:** Version bump only for package @reventlessdev/reventless-aws





# 3.0.0-alpha.99 (2026-05-18)

### Bug Fixes

* **admin:** give projection files their own moduleUrl so RM lambdas don't load Platform.res ([78ef5ec](https://github.com/ReventlessDev/reventless-core/commit/78ef5ece65575671d7fce877b0cf5adf578dfd05))
* **admin:** unblock admin → plugin SNS publish chain (3 bugs) ([e3418bb](https://github.com/ReventlessDev/reventless-core/commit/e3418bbf2e08575f28e0a9cc193f373a30dbb036))
* **eventlog:** alias position keyword in DynamoDB ConditionExpression ([b11b92d](https://github.com/ReventlessDev/reventless-core/commit/b11b92d207bb93f6c735ce3f09bf1e3ab4cbc578))
### Features

* **admin:** cross-plugin SNS subscription manager in AdminEventCollector (Phase 3 Step 1) ([8f8544c](https://github.com/ReventlessDev/reventless-core/commit/8f8544c176c065b3cccb42e6eee4cdfd03b40d48))
* **admin:** IAM perms for cross-plugin SNS subscriptions (Phase 3 Step 2) ([51e56f0](https://github.com/ReventlessDev/reventless-core/commit/51e56f06b36f84e3e0f253e41f6ec13d5df9b577))
* **plugin:** unblock admin → plugin Connect via Plugin_Callback at runtime ([4076ddf](https://github.com/ReventlessDev/reventless-core/commit/4076ddf8a5c8d6c323c9ea188774030ff535b8f9))
* **plugin:** wire end-to-end user-extension dispatch through plugin EventCollectors ([f616abe](https://github.com/ReventlessDev/reventless-core/commit/f616abe169289f836f8e538b5419cb82cda886d7))


# 3.0.0-alpha.98 (2026-05-17)

**Note:** Version bump only for package @reventlessdev/reventless-aws





# 3.0.0-alpha.97 (2026-05-17)

### Bug Fixes

* **aws:** pass plain strings to scheduler runtime; drop Util_PulumiShim ([c4e027e](https://github.com/ReventlessDev/reventless-core/commit/c4e027ea8477fe0891e77bfc76b08429935c2259))


# 3.0.0-alpha.96 (2026-05-17)

### Bug Fixes

* **deps:** pin sury-ppx to 11.0.0-alpha.2 to prevent prerelease drift ([c9d05fe](https://github.com/ReventlessDev/reventless-core/commit/c9d05fe5118a9c0442ca3e071f2606b3a139fc81))


# 3.0.0-alpha.95 (2026-05-17)

### Bug Fixes

* **aws:** wire schedulerRoleArn through admin registers; default heartbeat to 5 min ([f9580a2](https://github.com/ReventlessDev/reventless-core/commit/f9580a2fc7f85a67747ccaab87358f303bd90ab9))


# 3.0.0-alpha.94 (2026-05-17)

### Bug Fixes

* **deps:** pin sury to 11.0.0-alpha.4 to unblock Lambda Layer deploys ([643d925](https://github.com/ReventlessDev/reventless-core/commit/643d92527fa9d092da9bef8547591e39a4c609dd))


# 3.0.0-alpha.93 (2026-05-17)

### Bug Fixes

* **aws:** pass pluginId through onHeartbeatEpChannelAvailable so heartbeat Lambda has PLUGIN_ID ([cc983bf](https://github.com/ReventlessDev/reventless-core/commit/cc983bf5b737cf282f1bdeab7e2a3e95531d59ef))
* **aws:** swap destructuring in Lambda entry points so publishToAggregates is keyed by aggregate name ([f2b3206](https://github.com/ReventlessDev/reventless-core/commit/f2b3206294714ac30344f3ef1fc82ba55037a42f))
### Features

* **admin:** strip plugin version at GraphQL boundary for UI-facing pluginIds ([a03f028](https://github.com/ReventlessDev/reventless-core/commit/a03f0283c020b38fae26bbef1fb702fa928af95b))


# 3.0.0-alpha.92 (2026-05-17)

### Features

* **aws:** dedicated DynamoDB table for plugin schema-fragment persistence ([d8cc943](https://github.com/ReventlessDev/reventless-core/commit/d8cc9432e18fb3c65dd309d0eeabca1c73c1d05d))


# 3.0.0-alpha.91 (2026-05-17)

**Note:** Version bump only for package @reventlessdev/reventless-aws





# 3.0.0-alpha.90 (2026-05-17)

### Bug Fixes

* **aws:** stop bundle upload from clobbering host-shell config.json ([4efbe19](https://github.com/ReventlessDev/reventless-core/commit/4efbe196eb16218ebf349856043d5dfbf90df52e))
### Features

* **aws:** stable host-shell URL across deploys via ~stableName opt-in ([6c86ab1](https://github.com/ReventlessDev/reventless-core/commit/6c86ab1d8f4a82da1e91123105696ba92b8d6233))


# 3.0.0-alpha.89 (2026-05-16)

### Bug Fixes

* **admin:** attach AppSync resolvers to Platform_Plugin(s)/PlatformEventGraph(s) ([c2cd069](https://github.com/ReventlessDev/reventless-core/commit/c2cd069880f028296de5bb625984916e9e280fe6))


# 3.0.0-alpha.88 (2026-05-16)

### Bug Fixes

* **aws:** retry AppSync StartSchemaCreation on ConcurrentModificationException ([932722a](https://github.com/ReventlessDev/reventless-core/commit/932722ab1ed0074b8925a36392add298f77a24fc))
### Features

* **ppx:** add @[@reventless](https://github.com/reventless).visibility to hide components from AutoUI ([bd302cf](https://github.com/ReventlessDev/reventless-core/commit/bd302cfc5bd5d4dfe50c8e1bf8596ab67e36c74e))


# 3.0.0-alpha.87 (2026-05-16)

### Bug Fixes

* **aws:** preserve subscription fields in AppSync auth injection ([78bb9a2](https://github.com/ReventlessDev/reventless-core/commit/78bb9a2f88309855e1fe258be6fe57077896fd00))


# 3.0.0-alpha.86 (2026-05-16)

### Bug Fixes

* **aws:** use s3.Bucket instead of deprecated s3.BucketV2 ([1d89aec](https://github.com/ReventlessDev/reventless-core/commit/1d89aecde42d61904a2b1c905b76468bbf230db3))


# 3.0.0-alpha.85 (2026-05-16)

### Features

* **admin:** expose built-in Platform admin plugin in host shell Auto UI ([e9a8cb2](https://github.com/ReventlessDev/reventless-core/commit/e9a8cb20efb958e582738720ddb5812bdf950876))
* complete plugin status gate on both adapters with tiered error codes ([2a8309b](https://github.com/ReventlessDev/reventless-core/commit/2a8309bbf324b276dbcede1be85a5f90dedd82eb))
* wire admin Plugin aggregate through standard auto-resolver flow ([73a58d3](https://github.com/ReventlessDev/reventless-core/commit/73a58d3b93922989a51bc15724dd92baa15b7037))


# 3.0.0-alpha.84 (2026-05-14)

### Bug Fixes

* **aws:** chain admin schema push behind admin Pulumi outputs ([fba902c](https://github.com/ReventlessDev/reventless-core/commit/fba902cfebed9892aaf32b26cd0f0a0b949864d9))
* **aws:** hash bundled file content for Lambda sourceCodeHash ([9fcbf39](https://github.com/ReventlessDev/reventless-core/commit/9fcbf39e8493cc2380e8ee5440a2a6697f758ecb))
* **aws:** swap sury arg order in HeartbeatEntryPoint ([09c98d7](https://github.com/ReventlessDev/reventless-core/commit/09c98d71baa3777b50063fa4a3ce773bccc58047))
* **aws:** walk up to find Pulumi.local.yaml beside Pulumi.yaml ([e53e581](https://github.com/ReventlessDev/reventless-core/commit/e53e581ecd7b1907d34f64f154ba373e2a198b7b))


# 3.0.0-alpha.83 (2026-05-14)

### Bug Fixes

* **aws:** use ALLOW defaultAction on AppSync userPoolConfig ([a461b62](https://github.com/ReventlessDev/reventless-core/commit/a461b62e472d306fbebe711f7a0bc97a4e191614))


# 3.0.0-alpha.82 (2026-05-14)

### Bug Fixes

* **aws:** drop self-namespace ref in AppSync_Adapter ([c0b8e63](https://github.com/ReventlessDev/reventless-core/commit/c0b8e63cdad59c44cf8afe9b3afa79993bfa2fe8))
### Features

* **admin:** add Platform_UIFragments GraphQL query ([cf1ae27](https://github.com/ReventlessDev/reventless-core/commit/cf1ae27d19bf396dfa71c2539fd59874c9118ca0))
* **auth:** enforce per-spec authorization at in-memory resolvers ([32c6552](https://github.com/ReventlessDev/reventless-core/commit/32c65522cf4afb61c7c56f8828a95af8db4a0ad4))
* **auth:** Stage C — Cognito UserPool provisioning + A4 hydration fixup ([08d98e0](https://github.com/ReventlessDev/reventless-core/commit/08d98e00fc18de019190d7e6e977b09375d8ff61))
* **auth:** Stage D — Cognito AppSync auth + Auth_Cognito provider ([6e4ce64](https://github.com/ReventlessDev/reventless-core/commit/6e4ce643490c9683e89cd0fe25f6fd44659ccd69))
* **auth:** Stage E2 — lift spec-level Authorization.permission into [@aws](https://github.com/aws)_auth ([5f10fc9](https://github.com/ReventlessDev/reventless-core/commit/5f10fc94f501ad6e6f0d677f754acc3761281ab3))
* **aws:** short-TTL cache behaviors for unhashed bundle entry points ([300964b](https://github.com/ReventlessDev/reventless-core/commit/300964bea011a7844abd65b5bd0fafc1c3f7eb4d))
* **host-ui:** flip config.json authMode to cognito + emit pool/client IDs ([5cc6e7d](https://github.com/ReventlessDev/reventless-core/commit/5cc6e7df5c2ab5694019d75f344a46bba814b448))
* **platform-aws:** host the static host-shell SPA on the platform CDN ([529ae4f](https://github.com/ReventlessDev/reventless-core/commit/529ae4f4b54675d43f22bb6180186e88d240b744))
* **platform,ci:** env var override for Util_LocalConfig + CI deploy wiring ([39bf14a](https://github.com/ReventlessDev/reventless-core/commit/39bf14aa765c2ef72062886ab3133ca768a87fd0))
* **platform:** Pulumi.local.yaml sidecar for per-dev config overrides ([96b5ea7](https://github.com/ReventlessDev/reventless-core/commit/96b5ea7e1caa5813355fcdecfb505d5e3e4a8d3f))
* **ppx:** inline-spec walk + Spec module types require authorization ([7db9ec0](https://github.com/ReventlessDev/reventless-core/commit/7db9ec0f186578ce0088973dba22da9257be6a61))


# 3.0.0-alpha.81 (2026-05-13)

* feat(spec)!: standardise event/command envelope (StoredEvent, optional meta, position, persisted DCB meta, causation) ([7ef3176](https://github.com/ReventlessDev/reventless-core/commit/7ef3176c6330810c817f43a52b881b5a0efee30e))

### BREAKING CHANGES

* meta.ip / meta.user go from required `string` to optional
record fields (`?: string`). Code that did `meta.user == "unknown"` to
detect system messages must check for field absence. Storage tables built
before this change are not migrated (greenfield — recreate the EventLog /
DcbEventLog tables; DynamoDB range key renamed from `seq` to `position`,
SQLite dcb_event gains meta and recorded_at columns).



# 3.0.0-alpha.80 (2026-05-10)

### Bug Fixes

* **aggregate:** atomic multi-event append via TransactWriteItems ([ef077f4](https://github.com/ReventlessDev/reventless-core/commit/ef077f4ddf7f5467d12ac8a8de4723016632db7c))
* **aggregate:** cap appendWithCondition at 100 events up front ([7079401](https://github.com/ReventlessDev/reventless-core/commit/70794017b47272ffaae4242d476e7c2406d334e9))
* **dcb:** close appendUnconditional fence-bypass on DynamoDB ([c094269](https://github.com/ReventlessDev/reventless-core/commit/c0942696bb1aea153d05c87ccb85751433a964c2))
### Performance Improvements

* **aws:** strongly-consistent reads on single-tag DCB queries ([89fe391](https://github.com/ReventlessDev/reventless-core/commit/89fe391214ece8c1ab421ba091c9eac543cd515e))


# 3.0.0-alpha.79 (2026-05-07)

### Bug Fixes

* **aws:** make DCB conditional append atomic via TransactWriteItems ([e95ae85](https://github.com/ReventlessDev/reventless-core/commit/e95ae856beec54a96a55d7929880ca16cabc6cf9))


# 3.0.0-alpha.78 (2026-05-05)

**Note:** Version bump only for package @reventlessdev/reventless-aws





# 3.0.0-alpha.77 (2026-05-04)

### Bug Fixes

* **aws:** drop empty Config functor args; thread per-spec metadata as direct params ([17837a3](https://github.com/ReventlessDev/reventless-core/commit/17837a3fde52581a06516c69c80e6a1ea5689d9a))


# 3.0.0-alpha.76 (2026-05-03)

### Bug Fixes

* **appsync:** IAM-safe identity in command/mutation resolvers ([3098ea0](https://github.com/ReventlessDev/reventless-core/commit/3098ea0b06d1eccc7c5d28470ab4824a3bf7df43))
* **aws:** apply curried Behavior in DcbCommandTopic Lambda entry point ([62a8471](https://github.com/ReventlessDev/reventless-core/commit/62a84711caee29b3241e43b9cffdd3dbd667b436))

### BREAKING CHANGES

* **aws:** to the runtime config shape, replaced atomically inside
the same Lambda zip.



# 3.0.0-alpha.75 (2026-05-03)

**Note:** Version bump only for package @reventlessdev/reventless-aws





# 3.0.0-alpha.74 (2026-05-03)

### Features

* **aws:** makeUiBundleDistribution uploads assets and supports SPA history fallback ([79ee054](https://github.com/ReventlessDev/reventless-core/commit/79ee054b78d2d0ecf91d5c87e888d8bb11e83067))
* **aws:** mirror Platform_UIDefinitions GraphQL query — Lambda DataSource backed by Plugin read model ([76e57cc](https://github.com/ReventlessDev/reventless-core/commit/76e57ccc681a66be4909bd94e131145978169c9c))


# 3.0.0-alpha.73 (2026-05-03)

### Bug Fixes

* **deps:** add uuid as direct dependency of reventless-aws ([57a7153](https://github.com/ReventlessDev/reventless-core/commit/57a7153e12d7dcd45cafa21a2404666df45c2b4a))
* feat(ppx)!: add @@reventless.mappings/extension/task; collapse AutomationSlice.Make to 2 args ([c0268ac](https://github.com/ReventlessDev/reventless-core/commit/c0268ac42c1c887fe25467af61b412ab2e27a5a7))

### BREAKING CHANGES

* Platform.AutomationSlice.Make is now 2-arg (Spec, Automation).
External callers must either rerun generate-plugin or merge their _Mappings
contents into _Automation (or add the same two-line bridge).

Verified: zero warnings, 1174/1175 tests pass — the single failing test
(OrderingE2ETest "after syncing missing product, PlaceOrder succeeds") was
confirmed pre-existing on alpha (the known testPromise concurrency race).



# 3.0.0-alpha.72 (2026-04-28)

### Features

* **aws:** server-side filter/sort on connection list resolver ([baa3f4e](https://github.com/ReventlessDev/reventless-core/commit/baa3f4e7937ff14d8e6ad2b309dbae57a242cf47))


# 3.0.0-alpha.71 (2026-04-27)

### Bug Fixes

* **in-memory:** resolve extension wirings via Output chain and use firePlatformDeployedHook ([3037fc7](https://github.com/ReventlessDev/reventless-core/commit/3037fc7af05574163873eefdb227b5421118c323))
* **spec:** regenerate plugins; simplify codegen, drop Maker suffix ([8d81302](https://github.com/ReventlessDev/reventless-core/commit/8d81302a9dc3403f98298ff69b19901d625dff7e))


# 3.0.0-alpha.70 (2026-04-26)

* feat!: mixed-source AutomationSlice — Plan 04 ([fae3fbf](https://github.com/ReventlessDev/reventless-core/commit/fae3fbf93b12ecf62d0883fe7335ed73c6f52d67))
### Features

* **core:** convert slice builders to two-arg (Spec, Impl) form — Phase 2 of Spec-First series ([4c994f3](https://github.com/ReventlessDev/reventless-core/commit/4c994f3d62003da26f5fc6a5b2a9fc9264dc241e))
* **spec:** split slice spec module types — Phase 1 of Spec-First series ([d3b1493](https://github.com/ReventlessDev/reventless-core/commit/d3b149300d09dbac45a5e316343cd79fe2a769e6))

### BREAKING CHANGES

* AutomationSlice.Spec drops consumedEvent;
AutomationSlice_Builder.Make takes Mappings as 3rd arg; make signature
swaps ~dcbEventLog for ~allEventTopics + ~context; Plugin_Builder.Spec
gains platformName. Existing slices need a sibling _Mappings.res file
and updated Plugin.res (regenerate via prebuild hook).

Tests: 362/362 pass. Build clean, zero warnings.

Plan: docs/plans/done/mixed-source-automationslice.md
Guide: docs/guides/mixed-source-automationslice.md



# 3.0.0-alpha.69 (2026-04-24)

**Note:** Version bump only for package @reventlessdev/reventless-aws





# 3.0.0-alpha.68 (2026-04-24)

### Features

* **admin:** convert PlatformEventGraph from StateViewSlice to ReadModel ([df5746b](https://github.com/ReventlessDev/reventless-core/commit/df5746bbb419833361c2fb47ed607e2ab85ced47))


# 3.0.0-alpha.67 (2026-04-22)

### Features

* **build:** migrate from npm to pnpm (hoisted layout) ([1de8b77](https://github.com/ReventlessDev/reventless-core/commit/1de8b7753b8f45c63ea3c8d9f64de2f27febd029))
* expose sourceNames on ReadModel.T for aggregate-to-read-model linking ([379f344](https://github.com/ReventlessDev/reventless-core/commit/379f3445cfd5d18b5d439dd9c6f3bd7d86bdc3d5))


# 3.0.0-alpha.66 (2026-04-20)

### Bug Fixes

* **aws:** Source B push chain end-to-end ([d2b5cef](https://github.com/ReventlessDev/reventless-core/commit/d2b5cef2ff1dde197879461551e71d04e91962ac))
### Features

* wire Platform_EventGraph into AWS platform Admin.construct ([9ff5f33](https://github.com/ReventlessDev/reventless-core/commit/9ff5f334d5e0a64220375df0e34780986cc9d9f0))


# 3.0.0-alpha.65 (2026-04-19)

### Bug Fixes

* **aws:** recover from stale __provider read_ returning undefined on pulumi refresh ([f367c73](https://github.com/ReventlessDev/reventless-core/commit/f367c731a8782674a2f30e4dfc0eee803471dc55))


# 3.0.0-alpha.64 (2026-04-19)

### Dependency Updates

* **@reventlessdev/reventless-core** updated to `^3.0.0-alpha.56`
* **@reventlessdev/reventless-infra** updated to `^3.0.0-alpha.38`
* **@reventlessdev/reventless-spec** updated to `^3.0.0-alpha.29`


# 3.0.0-alpha.63 (2026-04-18)

### Features

* **core:** AutoUI definition — makeAutoUIDefinition, Platform_UIDefinitions query, generator support ([513ca53](https://github.com/ReventlessDev/reventless-core/commit/513ca5399b0b6e5ae6a982fd15693de2ea208b8d))
* **core:** UI fragment registry — Phase 5 (CDN bundle hosting) ([949eba4](https://github.com/ReventlessDev/reventless-core/commit/949eba497139f705db1ce0b3993a4e0f051965b4))
* **core:** uiFragments manifest — Phase 1 implementation with generic types ([1e73f62](https://github.com/ReventlessDev/reventless-core/commit/1e73f623984118081d2b985c48521812e4f8417e))


# 3.0.0-alpha.62 (2026-04-18)

### Features

* **aws:** enable Source B state-change subscriptions (DynamoDB Stream → AppSync Events) ([960b203](https://github.com/ReventlessDev/reventless-core/commit/960b2035d843c2b97cf2014b05fb1a4f132e9984))


# 3.0.0-alpha.61 (2026-04-17)

### Bug Fixes

* **reventless-aws:** recover AppSync resolvers deleted by schema replacement ([63dbb32](https://github.com/ReventlessDev/reventless-core/commit/63dbb32988beb5a84bf08c7b8ffe519f14573d43))
### Features

* **reventless-aws:** add graphqlEnum helper for AppSync enum arguments ([0087235](https://github.com/ReventlessDev/reventless-core/commit/008723590863de53d1ee3ea13d2dcf454d0292a4))


# 3.0.0-alpha.60 (2026-04-16)

### Bug Fixes

* **graphql:** emit input types for nested mutation args; pass dataSourceName on subs ([9dc7107](https://github.com/ReventlessDev/reventless-core/commit/9dc7107328327470396cfe6e1e775846fee98992))


# 3.0.0-alpha.59 (2026-04-16)

### Features

* **subscriptions:** implement GraphQL subscriptions across AWS + in-memory ([a25a3b8](https://github.com/ReventlessDev/reventless-core/commit/a25a3b8928a465b7ba8de7b06e44425e206a1fcd))


# 3.0.0-alpha.58 (2026-04-16)

### Dependency Updates

* **@reventlessdev/reventless-core** updated to `^3.0.0-alpha.51`


# 3.0.0-alpha.57 (2026-04-15)

### Bug Fixes

* **reventless-aws:** detect missing AppSync API in read for pulumi refresh ([f27ba62](https://github.com/ReventlessDev/reventless-core/commit/f27ba628dd4721a6c7d4a25310a95b4239b184f5))


# 3.0.0-alpha.56 (2026-04-15)

### Bug Fixes

* **reventless-aws:** ignore NotFoundException on AppSync resolver delete ([e4e7eff](https://github.com/ReventlessDev/reventless-core/commit/e4e7eff97acfa599a9a370396770ad9a9879dbe7))


# 3.0.0-alpha.55 (2026-04-15)

### Dependency Updates

* **@reventlessdev/reventless-core** updated to `^3.0.0-alpha.50`
* **@reventlessdev/reventless-infra** updated to `^3.0.0-alpha.35`
* **@reventlessdev/reventless-spec** updated to `^3.0.0-alpha.27`


# 3.0.0-alpha.54 (2026-04-15)

### Bug Fixes

* **platform:** split-API schema routing for Platform-target plugins ([6b4c58d](https://github.com/ReventlessDev/reventless-core/commit/6b4c58dfed15c40db0e70339f0148ff445eb5c6a))


# 3.0.0-alpha.53 (2026-04-15)

### Bug Fixes

* **dcb:** move position filter from FilterExpression to KeyConditionExpression ([2c83b94](https://github.com/ReventlessDev/reventless-core/commit/2c83b941bcb22bf9f7cc2f052a3a4be264132e83))
* **sqs:** cap MessageGroupId at 128 chars using SHA-256 hash ([af246a7](https://github.com/ReventlessDev/reventless-core/commit/af246a71cc6c110a821e8a3cd6180149dbf90b33))
### Features

* zero-touch plugin assembly — generate Plugin.res from folder structure ([73ea654](https://github.com/ReventlessDev/reventless-core/commit/73ea654ab9a73f15ea7e18631e8194bfe0f4580f))


# 3.0.0-alpha.52 (2026-04-13)

### Bug Fixes

* **aws:** include package versions in sourceCodeHash to detect dependency updates ([437937e](https://github.com/ReventlessDev/reventless-core/commit/437937e8a1927cb42899693f7247d7e80c4775c0))
* **aws:** remove legacy stack export names (Phase 5 of dual-api-architecture) ([a9b483d](https://github.com/ReventlessDev/reventless-core/commit/a9b483d5029303425a2892862d394a4253af95cb))
* **aws:** rename AppSync APIs to DomainApi/PlatformApi with Pulumi auto-hash suffix ([38b76a0](https://github.com/ReventlessDev/reventless-core/commit/38b76a0f1579352aa6531008d56bbe01fb604434))


# 3.0.0-alpha.51 (2026-04-13)

### Bug Fixes

* **aws:** fix off-by-one and misleading log messages in AppSync_Resolver_Retrying ([b30a70f](https://github.com/ReventlessDev/reventless-core/commit/b30a70f9a2afe44f67c1ccc6a205e64770141d51))
* **aws:** make AppSync resolver create idempotent on state/AppSync divergence ([85afaa9](https://github.com/ReventlessDev/reventless-core/commit/85afaa9a35d0ea9849edd3d958fde1cbde058d14))


# 3.0.0-alpha.50 (2026-04-13)

### Bug Fixes

* **aws:** co-bundle effect with reventless-aws to fix ESM resolution in Lambda ([29ea07d](https://github.com/ReventlessDev/reventless-core/commit/29ea07d059f09a9844bbad901773c4f5f8046c7f))
* **aws:** prevent resolver replace cascade and fix error display in AppSync_Resolver_Retrying ([7dec70d](https://github.com/ReventlessDev/reventless-core/commit/7dec70d5f3b35930b82bbfbb22e5b0aa66f6784e))


# 3.0.0-alpha.49 (2026-04-13)

### Bug Fixes

* **aws:** correct API routing for DCB/inbound resolvers and AppSync JS runtime compat ([6ef9260](https://github.com/ReventlessDev/reventless-core/commit/6ef926087404a013b0c6e166fa35aa497a3b3050))
* **aws:** defer all AppSync resolver creation into resourcesMaker ([c6c8ba2](https://github.com/ReventlessDev/reventless-core/commit/c6c8ba2878b7ed67965882ddf6d3c468780e88b6))
* **aws:** fall back to .github/layer-arn[-{stack}].txt when REVENTLESS_LAYER_ARN is unset ([98ba46a](https://github.com/ReventlessDev/reventless-core/commit/98ba46a28427b390d81380b069bcf1eec066c1a0))
* **aws:** fix runtime builder bugs and extract archive-building helper ([bdb7dc0](https://github.com/ReventlessDev/reventless-core/commit/bdb7dc0a03aaaccd6e95d649c32028ac2d3026ee))
* **aws:** retry AppSync CreateResolver on schema-propagation 404s ([8e1d19b](https://github.com/ReventlessDev/reventless-core/commit/8e1d19b5d63c3590339d5d281971081d1ed7356f))
* **aws:** route slice builder resolvers to correct API target ([7485159](https://github.com/ReventlessDev/reventless-core/commit/7485159f415d4720dd4e567d2ffef1335db432e6))
* **aws:** update AppSync_AdapterTest to match Platform_ prefix rename ([e6b2dd2](https://github.com/ReventlessDev/reventless-core/commit/e6b2dd212a0c406bd3ae6f7544827b8295ba1325))
### Features

* **api:** use aws-native AppSync Resolver to fix schema propagation race ([7009a65](https://github.com/ReventlessDev/reventless-core/commit/7009a65f115c1dd549c49cf33461537407fecbb6))
### Performance Improvements

* **aws:** skip AppSync schema push when SDL is unchanged ([5b5f30a](https://github.com/ReventlessDev/reventless-core/commit/5b5f30a402f99898739f494528ac0ca47ec1c27d))


# 3.0.0-alpha.48 (2026-04-12)

### Features

* **api:** replace ByIdConnection with Relay-compatible Items query ([1bb7a8d](https://github.com/ReventlessDev/reventless-core/commit/1bb7a8d9e10b2db76714c61f9418cc55fd7ec2ae))
* **commands:** end-to-end CommandResult — synchronous business-rule errors reach the GraphQL client ([c241d74](https://github.com/ReventlessDev/reventless-core/commit/c241d7418205799bdc79472ebbd04f40b392f870))
* **commands:** extend CommandAccepted with entityId and eventCount ([747b85d](https://github.com/ReventlessDev/reventless-core/commit/747b85dc50042124f360627c5489321eea0d26e4))
* **platform:** MakeAsync opt-in for aggregates and DCB slices ([6970d88](https://github.com/ReventlessDev/reventless-core/commit/6970d889fa05e738dbda5d8e450a1dcf927b23b7))
* **platform:** symmetric domain/platform server architecture (Phase 6) ([4bbc88d](https://github.com/ReventlessDev/reventless-core/commit/4bbc88d2dac3b0d3a6099008f3814d6aedf03e29))


# 3.0.0-alpha.47 (2026-04-11)

### Features

* **platform:** add apiTarget routing for deployPlugin (Phase 4a-4d) ([b9b2d75](https://github.com/ReventlessDev/reventless-core/commit/b9b2d754c2fb61854fc5bca8761a0d0acfb89009))


# 3.0.0-alpha.46 (2026-04-10)

### Bug Fixes

* **aws:** wrap hooked api/apiRole in {val} to prevent Pulumi Proxy corruption ([8c071b1](https://github.com/ReventlessDev/reventless-core/commit/8c071b130d1dbe43610ae6cf8d75bb43be0ed7d5))


# 3.0.0-alpha.45 (2026-04-10)

### Features

* **aws:** implement dual-API architecture (Phases 1–3) ([9e11efc](https://github.com/ReventlessDev/reventless-core/commit/9e11efc21bb012552fbe1c1b510664d372f84b96))


# 3.0.0-alpha.44 (2026-04-09)

### Features

* **platform:** add apiEndpoint to platformDeployedInfo, extract Plugin_BuiltHook ([d53cfc5](https://github.com/ReventlessDev/reventless-core/commit/d53cfc5bd33671d2ca539b4eeb45bbaa7b3979e3))


# 3.0.0-alpha.43 (2026-04-09)

### Bug Fixes

* **reventless-aws:** correct sha256 hash constructor binding for SignatureV4 ([0edb56c](https://github.com/ReventlessDev/reventless-core/commit/0edb56c6b66145d501f896e90e597509400b8bd2))


# 3.0.0-alpha.42 (2026-04-09)

### Bug Fixes

* **AppSync:** use deploySchemaWithRetry in updateSchema ([3f741f7](https://github.com/ReventlessDev/reventless-core/commit/3f741f7eb435264f3b7d4ed61aa8f15eb965044f))
### Features

* **AppSync:** add deploySchemaWithRetry for concurrent schema modification handling ([f58f920](https://github.com/ReventlessDev/reventless-core/commit/f58f920af1a396aa71df6d2fe3f57351d3792190))
* **reventless-aws:** add Util_AppSync_Caller for IAM-signed AppSync dispatch ([8c0bc23](https://github.com/ReventlessDev/reventless-core/commit/8c0bc232f215b22c2bee8eac8d36f991ef18d430))


# 3.0.0-alpha.41 (2026-04-07)

### Bug Fixes

* **query-db:** use idField name for DynamoDB attribute definition in GSI ([bd2ab7d](https://github.com/ReventlessDev/reventless-core/commit/bd2ab7db101c6a3e5f89ef268503c90f38d1a453))


# 3.0.0-alpha.40 (2026-04-07)

### Features

* **ppx+querydb:** annotation-driven key design and sort key queries ([dee6de8](https://github.com/ReventlessDev/reventless-core/commit/dee6de84c2d2de5431d064f18ac7132bc8c23110))


# 3.0.0-alpha.39 (2026-04-07)

### Dependency Updates

* **@reventlessdev/reventless-core** updated to `^3.0.0-alpha.39`
* **@reventlessdev/reventless-infra** updated to `^3.0.0-alpha.26`
* **@reventlessdev/reventless-spec** updated to `^3.0.0-alpha.21`


# 3.0.0-alpha.38 (2026-04-06)

### Bug Fixes

* add package-specs to all rescript.json to prevent CJS .js output ([780f1e0](https://github.com/ReventlessDev/reventless-core/commit/780f1e035173b73b17b78466ad01fb69c7cca350))
* **aws:** guard verifyTtl against undefined ttl from Pulumi ([e149204](https://github.com/ReventlessDev/reventless-core/commit/e1492042c9044e40662b643dd2713a3d389a90da))
* **aws:** inject partition key id into DynamoDB items before put ([aa51fb5](https://github.com/ReventlessDev/reventless-core/commit/aa51fb52dff1aff7845c3670394f61eb52c93d80))
* **aws:** safe claims access and GSI IAM permission for AppSync/Lambda ([f0d8324](https://github.com/ReventlessDev/reventless-core/commit/f0d8324693924314a90ad7c79d0837a923fc3197))


# 3.0.0-alpha.37 (2026-04-06)

### Bug Fixes

* DCB runtime — empty tags fallback, tag_composite GSI, stream meta ([4c3a6ad](https://github.com/ReventlessDev/reventless-core/commit/4c3a6ad9f0e1a9fa357a7230d7151ba34a0c116b))
* wire DCB EventCollector and StateViewSlice Lambda pipeline ([846228f](https://github.com/ReventlessDev/reventless-core/commit/846228fc9193a4c344399ecae924241e7944204f))
### Features

* implement [@composite](https://github.com/composite)PartitionTag PPX annotation for multi-field DCB partition keys ([cf26b15](https://github.com/ReventlessDev/reventless-core/commit/cf26b15f639d151451c9aa04d32603ef9d5df315))


# 3.0.0-alpha.36 (2026-04-05)

### Bug Fixes

* DCB runtime — empty tags fallback, tag_composite GSI, stream meta ([4c3a6ad](https://github.com/ReventlessDev/reventless-core/commit/4c3a6ad9f0e1a9fa357a7230d7151ba34a0c116b))
* wire DCB EventCollector and StateViewSlice Lambda pipeline ([846228f](https://github.com/ReventlessDev/reventless-core/commit/846228fc9193a4c344399ecae924241e7944204f))


# 3.0.0-alpha.35 (2026-04-05)

### Bug Fixes

* DCB command pipeline runtime fixes ([9646c97](https://github.com/ReventlessDev/reventless-core/commit/9646c97e7fd86f28d5035d77ff40af66f592e61e))


# 3.0.0-alpha.34 (2026-04-04)

* feat!: add reventless-ppx with @@reventless.spec, @@reventless.behavior, @@reventless.dcbTags ([cb203ec](https://github.com/ReventlessDev/reventless-core/commit/cb203ece5ea3a1b92ba7d1a57d9e12bb6c4c2487))
* feat!: Extension Blueprint pattern with auto-merge and plugin naming ([0856d4d](https://github.com/ReventlessDev/reventless-core/commit/0856d4d2a23b8d5175fd091f90110d4c44927191))
### Features

* add Relay server compliance to GraphQL API ([bd9245d](https://github.com/ReventlessDev/reventless-core/commit/bd9245da87023247643c5fa37cee21b0cde0f61e))
* make Relay connection spec the default for all list queries ([fa8d258](https://github.com/ReventlessDev/reventless-core/commit/fa8d258ddeb30bf02f97b1c1f3cc564e15632e94))

### BREAKING CHANGES

* Example spec files no longer export manual moduleUrl/name/Id
declarations — these are now PPX-generated. Downstream code referencing these
exports is unaffected (same values, different source).
* Platform.Extension.Make returns Extension.Blueprint
instead of Extension.T. Plugin.make ~extensions param type changes
accordingly. Make2/Make3/MakeMulti removed from Platform.T.



# 3.0.0-alpha.33 (2026-04-03)

### Bug Fixes

* resolve pluginRmTableName export and StackReference decoding in Platform ([de8a337](https://github.com/ReventlessDev/reventless-core/commit/de8a337551e6e0f2edad1daa97082e5cc61504c8))
### Features

* migrate AppSync resolvers from VTL to APPSYNC_JS runtime ([22f8c15](https://github.com/ReventlessDev/reventless-core/commit/22f8c15cee7d99859a56e5a6fbc11f9e9ff566c9))


# 3.0.0-alpha.32 (2026-04-02)

### Features

* add tags field to resource and resolvedResource records ([18911e6](https://github.com/ReventlessDev/reventless-core/commit/18911e66aa94e60d4a9b72ba1d1ca84dd3fb1a9f))


# 3.0.0-alpha.31 (2026-04-02)

* feat!: add deploy lifecycle hooks, enrich resource metadata, and add Adapter.make factory ([0a171f4](https://github.com/ReventlessDev/reventless-core/commit/0a171f4b8aec0ee47fd7ee5069adf5d5b194548e))

### BREAKING CHANGES

* Adapter.resource.info replaced with resourceInfo variant type.
Service field values now prefixed with provider namespace (e.g. "aws:DynamoDb").
New required fields on resource/resolvedResource: role, region, resourceType, configuration.



# 3.0.0-alpha.30 (2026-04-02)

### Features

* **aws:** add generic env var and IAM extension point for all Lambdas ([0335fe5](https://github.com/ReventlessDev/reventless-core/commit/0335fe56a0a992ddb7fed0cb768e053bfa9945df))


# 3.0.0-alpha.29 (2026-03-31)

### Bug Fixes

* migrate remaining Console.log calls to unified Logger/EffectLogger ([0216b0d](https://github.com/ReventlessDev/reventless-core/commit/0216b0dde5597b2bc539a960ac86a18071777815))
### Features

* return Plugin.outputs from deployPlugin ([22e59f7](https://github.com/ReventlessDev/reventless-core/commit/22e59f730c5c87dd0e3e8d4cf225d401298759f8))


# 3.0.0-alpha.28 (2026-03-30)

### Features

* add event publish hooks and AWS query interceptor support ([5c4ec59](https://github.com/ReventlessDev/reventless-core/commit/5c4ec598f6cc7115255b4b18c9decf8007630f15))


# [3.0.0-alpha.27](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-aws@3.0.0-alpha.26...@reventlessdev/reventless-aws@3.0.0-alpha.27) (2026-03-30)

**Note:** Version bump only for package @reventlessdev/reventless-aws





# [3.0.0-alpha.26](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-aws@3.0.0-alpha.25...@reventlessdev/reventless-aws@3.0.0-alpha.26) (2026-03-29)

**Note:** Version bump only for package @reventlessdev/reventless-aws





# [3.0.0-alpha.25](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-aws@3.0.0-alpha.23...@reventlessdev/reventless-aws@3.0.0-alpha.25) (2026-03-28)

* refactor!: migrate Lambda entry points from ReScript to plain ESM ([2c1ea8f](https://github.com/ReventlessDev/reventless-core/commit/2c1ea8f1601e2142690b11f8bb0ffc2fd45c7f51))
* feat!: flatten DcbSpec module type into direct Plugin.make parameters ([1c0bc57](https://github.com/ReventlessDev/reventless-core/commit/1c0bc576fcd88b92510900c16f5f117e864d9d7f))
### Features

* add identity propagation and interceptor hook to CommandGenerator pipeline ([37494a5](https://github.com/ReventlessDev/reventless-core/commit/37494a50fe70f8db7d6d35fd733a4fc75eade5bc))

### BREAKING CHANGES

* Lambda Layer entry point paths changed from
*EntryPoint.res.mjs to *EntryPoint.mjs — requires layer rebuild.
* Plugin.make no longer accepts ~dcbSpec=module(DcbSpec).
Pass slice arrays directly instead. Empty arrays can be omitted.



# [3.0.0-alpha.24](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-aws@3.0.0-alpha.23...@reventlessdev/reventless-aws@3.0.0-alpha.24) (2026-03-27)

* refactor!: migrate Lambda entry points from ReScript to plain ESM ([2c1ea8f](https://github.com/ReventlessDev/reventless-core/commit/2c1ea8f1601e2142690b11f8bb0ffc2fd45c7f51))
* feat!: flatten DcbSpec module type into direct Plugin.make parameters ([1c0bc57](https://github.com/ReventlessDev/reventless-core/commit/1c0bc576fcd88b92510900c16f5f117e864d9d7f))

### BREAKING CHANGES

* Lambda Layer entry point paths changed from
*EntryPoint.res.mjs to *EntryPoint.mjs — requires layer rebuild.
* Plugin.make no longer accepts ~dcbSpec=module(DcbSpec).
Pass slice arrays directly instead. Empty arrays can be omitted.



# [3.0.0-alpha.23](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-aws@3.0.0-alpha.20...@reventlessdev/reventless-aws@3.0.0-alpha.23) (2026-03-27)

### Bug Fixes

* conditionally exclude ID parameter from StateViewSlice GraphQL queries ([43de4b6](https://github.com/ReventlessDev/reventless-core/commit/43de4b667d89235ea03b3e1584070515e10e71de))
* **reventless-aws:** unwrap topicItem in DCB entry point SQS command routing ([0834056](https://github.com/ReventlessDev/reventless-core/commit/083405640d928503e8a56d5d8c7b326ad86d1313))
* feat!: remove resolverConfig from Behavior module type ([6f54015](https://github.com/ReventlessDev/reventless-core/commit/6f54015e3abc1c5c05472c8f54645723a0f5ed28))
* feat!: decouple DCB slices from shared event log union type ([2a40e8d](https://github.com/ReventlessDev/reventless-core/commit/2a40e8dd9babfb88440fcaccde6fb667b60e0ba9))

### BREAKING CHANGES

* Behavior.T no longer requires resolverConfig. Remove it
from all Behavior implementations.
* All DCB slice specs must use `producedEvent`/`consumedEvent`
instead of `module DcbEventLogSpec`. Plugin `DcbSpec` no longer has `type event`
or `with type dcbEvent` constraints.



# [3.0.0-alpha.22](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-aws@3.0.0-alpha.20...@reventlessdev/reventless-aws@3.0.0-alpha.22) (2026-03-26)

### Bug Fixes

* conditionally exclude ID parameter from StateViewSlice GraphQL queries ([43de4b6](https://github.com/ReventlessDev/reventless-core/commit/43de4b667d89235ea03b3e1584070515e10e71de))
* **reventless-aws:** unwrap topicItem in DCB entry point SQS command routing ([0834056](https://github.com/ReventlessDev/reventless-core/commit/083405640d928503e8a56d5d8c7b326ad86d1313))


# [3.0.0-alpha.21](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-aws@3.0.0-alpha.20...@reventlessdev/reventless-aws@3.0.0-alpha.21) (2026-03-26)

### Bug Fixes

* conditionally exclude ID parameter from StateViewSlice GraphQL queries ([43de4b6](https://github.com/ReventlessDev/reventless-core/commit/43de4b667d89235ea03b3e1584070515e10e71de))
* **reventless-aws:** unwrap topicItem in DCB entry point SQS command routing ([0834056](https://github.com/ReventlessDev/reventless-core/commit/083405640d928503e8a56d5d8c7b326ad86d1313))


# [3.0.0-alpha.20](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-aws@3.0.0-alpha.19...@reventlessdev/reventless-aws@3.0.0-alpha.20) (2026-03-23)

* refactor!: streamline component function naming to unified two-function pattern ([06814fd](https://github.com/ReventlessDev/reventless-core/commit/06814fd8589cf05ce8a9f9654552e7d5cd9c6bf2))
* fix(reventless-aws)!: fix DcbEventLog DynamoDB stream event decoding and normalize field names ([c83d38a](https://github.com/ReventlessDev/reventless-core/commit/c83d38abbeb225cf68fdc22a0210da46f249a558))
* fix(reventless-aws)!: resolve DcbEventLogSpec undefined at runtime and add AppSync routing ([85138a3](https://github.com/ReventlessDev/reventless-core/commit/85138a39afe97047ea5f063508994e20544eb780))

### BREAKING CHANGES

* All component function signatures changed. Behavior.decide
now returns result<array<event>, error> instead of using errorHandler callback.
StateChangeSlice type decisionModel renamed to state. Projection.Mapping.map
renamed to project. StateViewSlice.project takes one argument instead of two.

* DynamoDB attribute names changed. Existing event log tables require migration.

* DcbEventLog.Spec now requires `let moduleUrl: string` field.
Add `let moduleUrl: string = %raw(\`import.meta.url\`)` to event log modules.
# [3.0.0-alpha.19](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-aws@3.0.0-alpha.17...@reventlessdev/reventless-aws@3.0.0-alpha.19) (2026-03-22)

### Bug Fixes

* **rescript-effect:** use deep imports to avoid loading effect barrel ([1823358](https://github.com/ReventlessDev/reventless-core/commit/18233588d3564d8b4d158b949e734cbb92720fcd))
* **reventless-aws:** use deep effect imports in hand-written handler factories ([7f42d25](https://github.com/ReventlessDev/reventless-core/commit/7f42d25884ddab90fa3e4217ba9ca7db7a664eb3))
* **reventless-aws:** use namespace imports for effect deep paths ([11bedcf](https://github.com/ReventlessDev/reventless-core/commit/11bedcf48400e1be47deac6234680d2959c0b7e1))
* **reventless-aws:** use package specifiers for layer-provided modules ([7fdf04b](https://github.com/ReventlessDev/reventless-core/commit/7fdf04b6757a7006d3e425c881212c15a932f469))
* **reventless-layer-builder:** include [@smithy](https://github.com/smithy) in layer for ESM resolution ([ff7f4ab](https://github.com/ReventlessDev/reventless-core/commit/ff7f4ab4cbcd2fdd203432a48603ee766b662b9e))
* feat(reventless-aws)!: replace esbuild pipeline with compiled ReScript entry points ([6cb3133](https://github.com/ReventlessDev/reventless-core/commit/6cb313323c73a078d0922fa6b977466f61de74ea))

### BREAKING CHANGES

* esbuild removed from dependencies, `makeBundled` and
`makeBundledFromEntryPoint` removed from RuntimeEnvironment_Lambda,
`BundledEnvironment` module type removed from Runtime.
# [3.0.0-alpha.18](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-aws@3.0.0-alpha.17...@reventlessdev/reventless-aws@3.0.0-alpha.18) (2026-03-21)

### Bug Fixes

* **rescript-effect:** use deep imports to avoid loading effect barrel ([1823358](https://github.com/ReventlessDev/reventless-core/commit/18233588d3564d8b4d158b949e734cbb92720fcd))
* **reventless-aws:** use deep effect imports in hand-written handler factories ([7f42d25](https://github.com/ReventlessDev/reventless-core/commit/7f42d25884ddab90fa3e4217ba9ca7db7a664eb3))
* **reventless-aws:** use package specifiers for layer-provided modules ([7fdf04b](https://github.com/ReventlessDev/reventless-core/commit/7fdf04b6757a7006d3e425c881212c15a932f469))
# [3.0.0-alpha.17](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-aws@3.0.0-alpha.16...@reventlessdev/reventless-aws@3.0.0-alpha.17) (2026-03-20)

### Bug Fixes

* **aws:** make Lambda bundling deterministic to prevent unnecessary redeploys ([049abcd](https://github.com/ReventlessDev/reventless-core/commit/049abcd07e1dd5bc7270a6dd376d57963a2ce841))
* **aws:** reduce Lambda bundle size by externalizing layer packages ([c1a042a](https://github.com/ReventlessDev/reventless-core/commit/c1a042a8304bd303a4e0018954b239e9ec38d2bf))
### Features

* **aws:** add Lambda FunctionUrl bindings and AWS split-api integration tests ([07c7cbe](https://github.com/ReventlessDev/reventless-core/commit/07c7cbeb688cfa8e48d92d7ff37738312493b00a))
* **aws:** export platform component outputs and build admin Plugin aggregate/read model ([fabc069](https://github.com/ReventlessDev/reventless-core/commit/fabc069233dcf07c4eba8934868117bfe92ad59a))
* **aws:** expose api/apiRole in Platform.T and remove unused MakeBundled modules ([a3be4cc](https://github.com/ReventlessDev/reventless-core/commit/a3be4cc5dc6041fb70c8e44a9e48f0a4f730242a))
* **aws:** implement bundled DCB CommandTopic, Heartbeat, and EP fix ([4ae72ec](https://github.com/ReventlessDev/reventless-core/commit/4ae72ec20d7ea1941e9b02dc7f06461c5fff06c4))
* **aws:** implement split API and fix bundled handler issues ([a3dfa79](https://github.com/ReventlessDev/reventless-core/commit/a3dfa79612eca4c4f57fabac7768f7bbda511eae))
* **aws:** replace CallbackFunction with bundled Lambda handlers ([6f6200b](https://github.com/ReventlessDev/reventless-core/commit/6f6200b0796e5f414493f50fd2f13dd6c7871ef4))
* **interop:** add component-level resolved output types and export plugin outputs from deployPlugin ([b502cbf](https://github.com/ReventlessDev/reventless-core/commit/b502cbf189f024f8bb3fd19a75bf5d76c7de2236))
# [3.0.0-alpha.16](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-aws@3.0.0-alpha.15...@reventlessdev/reventless-aws@3.0.0-alpha.16) (2026-03-17)

### Bug Fixes

* add @aws-sdk/client-appsync dep and fix ESM Component import ([aec0dcd](https://github.com/ReventlessDev/reventless-core/commit/aec0dcd73787ed9d988223c72ffd82d423f834a5))
* **reventless-aws:** resolve Pulumi deploy-time issues ([f0ce675](https://github.com/ReventlessDev/reventless-core/commit/f0ce6751cb3ac829c674991784c5f23cb45a991b))
### Features

* **reventless-aws:** implement per-plugin deployment with runtime schema stitching ([f16714c](https://github.com/ReventlessDev/reventless-core/commit/f16714c5d2b3ad869863ac30dc55ef3e1570bf4f))
# [3.0.0-alpha.15](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-aws@3.0.0-alpha.14...@reventlessdev/reventless-aws@3.0.0-alpha.15) (2026-03-16)

* feat!: unify DCB and Aggregate command generation paths ([8c9bbad](https://github.com/ReventlessDev/reventless-core/commit/8c9bbad14082e7b696da35f5abb337520b1c8683))
* feat!: replace Core component with Platform_Admin, rename schema prefix Core_ → Admin_ ([940263d](https://github.com/ReventlessDev/reventless-core/commit/940263d8b39e28f4c874af3b0335ae81444928c4))
### Features

* internalize scheduler, Core, and setup in Platform.makePlatform ([ce3e1b6](https://github.com/ReventlessDev/reventless-core/commit/ce3e1b60e8ffdbab1a6b5cd08d73f5e907726481))
* read version from package.json, make cloner opt-in, log platform version ([d8216a1](https://github.com/ReventlessDev/reventless-core/commit/d8216a1d569064ca14eff6e0c3be86923e5b84ad))

### BREAKING CHANGES

* DCB mutation return value changes from "ok" to a UUID.

* GraphQL/MCP field names change from Core_ to Admin_
prefix (e.g. Core_Plugin → Admin_Plugin). makePlatform no longer accepts
~extensionPoints, ~aggregates, ~readModels, ~dcbSpec parameters.
# [3.0.0-alpha.14](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-aws@3.0.0-alpha.13...@reventlessdev/reventless-aws@3.0.0-alpha.14) (2026-03-14)

### Bug Fixes

* eliminate Obj.magic from Platform DcbSpec boundaries ([135888b](https://github.com/ReventlessDev/reventless-core/commit/135888b226727d7ed8cc1e364e242b12071e107a))
### Features

* add optional DCB spec support to Core module and consolidate builder helpers ([06a5e6f](https://github.com/ReventlessDev/reventless-core/commit/06a5e6f2eeadbabd20fb7197318d760b91c34925))
* implement hybrid API/MCP schema split (core vs plugins) ([4f84866](https://github.com/ReventlessDev/reventless-core/commit/4f848667c0814533b2f3a294350c4310c61d9fc7))
# [3.0.0-alpha.13](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-aws@3.0.0-alpha.12...@reventlessdev/reventless-aws@3.0.0-alpha.13) (2026-03-12)

### Features

* capitalize and prefix Core_ on GraphQL/MCP queries and mutations ([769420b](https://github.com/ReventlessDev/reventless-core/commit/769420b47ce35aba46d248d1529f7c72c7df9c0e))
* unify schema generation pipeline across GraphQL and MCP protocols ([84e05ae](https://github.com/ReventlessDev/reventless-core/commit/84e05aeca8c13000040d1230502b07350ab5daeb))
# [3.0.0-alpha.12](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-aws@3.0.0-alpha.11...@reventlessdev/reventless-aws@3.0.0-alpha.12) (2026-03-12)

### Features

* **deps:** upgrade rescript to 12.2 and migrate Belt usages to stdlib ([eaa96ea](https://github.com/ReventlessDev/reventless-core/commit/eaa96ea61ca40d61573fb5fe2002a1f73d43ce3e))
# [3.0.0-alpha.11](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-aws@3.0.0-alpha.9...@reventlessdev/reventless-aws@3.0.0-alpha.11) (2026-03-08)

### Bug Fixes

* remove 26 Obj.magic usages, improve type safety across codebase ([ebb8925](https://github.com/ReventlessDev/reventless-core/commit/ebb8925b760a0f070b1aaf3ef2d4bf3fdc7282a3))
### Features

* add AutomationSlice component (TODO list pattern) ([4642688](https://github.com/ReventlessDev/reventless-core/commit/46426884727aff74db33b9289feca9878b0e3ed9))
* add AWS event history handlers and pagination for MCP resources ([33f6e39](https://github.com/ReventlessDev/reventless-core/commit/33f6e3910d50cfbe03c9d2d2ed2ea97b92ab7501))
* add effect-based handlers with Effect service injection at dispatch ([7ab3b3e](https://github.com/ReventlessDev/reventless-core/commit/7ab3b3e8a48890f2248b113328914755f604c07e))
* add MCP server layer for AI-native access to Reventless ([4b288bc](https://github.com/ReventlessDev/reventless-core/commit/4b288bce2fc17c28c32c6778028becb0cde4c544))
* add TranslationSlice components with docs and webhook backlog plan ([7362a8f](https://github.com/ReventlessDev/reventless-core/commit/7362a8f26bca2eaad9d99488ec597c426635659d))
* auto-generate GraphQL mutations for InboundTranslationSlice ([7011fd2](https://github.com/ReventlessDev/reventless-core/commit/7011fd29f3029f001aa94fa78eb4f6b34d45451e))
* fix GraphQL SDL generation — correct naming, typed returns, and aggregate mutations ([ac93318](https://github.com/ReventlessDev/reventless-core/commit/ac933182dcd238b5f02ed98d1ddf03bb52b2c109))
* harmonize error handling and retry with Effect across all AWS adapters ([a817bde](https://github.com/ReventlessDev/reventless-core/commit/a817bde2fbbda314ebdbc69aee17de717ee059ed))
* lift AWS runtime handlers into pure Effect pipelines ([136f1c0](https://github.com/ReventlessDev/reventless-core/commit/136f1c0712a65e46d4be292c42b1d02babcc2f1b))
* make Logger injectable at Platform level and replace Console.log in runtime builders ([5c5dd5b](https://github.com/ReventlessDev/reventless-core/commit/5c5dd5bc07c14c13a9fc5d857d26387e14d06dd6))
* migrate logging to Effect built-in logger and provide RequestContext ([e9ec682](https://github.com/ReventlessDev/reventless-core/commit/e9ec6822ea924fc1561bfd886e4232cb5e2a8250))
* replace timestamp-based sequenceNr with integer sequence numbers and optimistic locking ([50b7d3e](https://github.com/ReventlessDev/reventless-core/commit/50b7d3e9901daafc6dff8c9492a789bc700e9099))
# [3.0.0-alpha.10](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-aws@3.0.0-alpha.9...@reventlessdev/reventless-aws@3.0.0-alpha.10) (2026-03-08)

### Bug Fixes

* remove 26 Obj.magic usages, improve type safety across codebase ([ebb8925](https://github.com/ReventlessDev/reventless-core/commit/ebb8925b760a0f070b1aaf3ef2d4bf3fdc7282a3))
### Features

* add AutomationSlice component (TODO list pattern) ([4642688](https://github.com/ReventlessDev/reventless-core/commit/46426884727aff74db33b9289feca9878b0e3ed9))
* add AWS event history handlers and pagination for MCP resources ([33f6e39](https://github.com/ReventlessDev/reventless-core/commit/33f6e3910d50cfbe03c9d2d2ed2ea97b92ab7501))
* add effect-based handlers with Effect service injection at dispatch ([7ab3b3e](https://github.com/ReventlessDev/reventless-core/commit/7ab3b3e8a48890f2248b113328914755f604c07e))
* add MCP server layer for AI-native access to Reventless ([4b288bc](https://github.com/ReventlessDev/reventless-core/commit/4b288bce2fc17c28c32c6778028becb0cde4c544))
* add TranslationSlice components with docs and webhook backlog plan ([7362a8f](https://github.com/ReventlessDev/reventless-core/commit/7362a8f26bca2eaad9d99488ec597c426635659d))
* auto-generate GraphQL mutations for InboundTranslationSlice ([7011fd2](https://github.com/ReventlessDev/reventless-core/commit/7011fd29f3029f001aa94fa78eb4f6b34d45451e))
* fix GraphQL SDL generation — correct naming, typed returns, and aggregate mutations ([ac93318](https://github.com/ReventlessDev/reventless-core/commit/ac933182dcd238b5f02ed98d1ddf03bb52b2c109))
* harmonize error handling and retry with Effect across all AWS adapters ([a817bde](https://github.com/ReventlessDev/reventless-core/commit/a817bde2fbbda314ebdbc69aee17de717ee059ed))
* lift AWS runtime handlers into pure Effect pipelines ([136f1c0](https://github.com/ReventlessDev/reventless-core/commit/136f1c0712a65e46d4be292c42b1d02babcc2f1b))
* make Logger injectable at Platform level and replace Console.log in runtime builders ([5c5dd5b](https://github.com/ReventlessDev/reventless-core/commit/5c5dd5bc07c14c13a9fc5d857d26387e14d06dd6))
* migrate logging to Effect built-in logger and provide RequestContext ([e9ec682](https://github.com/ReventlessDev/reventless-core/commit/e9ec6822ea924fc1561bfd886e4232cb5e2a8250))
# [3.0.0-alpha.9](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-aws@3.0.0-alpha.8...@reventlessdev/reventless-aws@3.0.0-alpha.9) (2026-03-03)

### Features

* **api:** implement Api component with GraphQL fragment generation and schema stitching ([c882d3a](https://github.com/ReventlessDev/reventless-core/commit/c882d3aae8722cf6cbe9b4fbf9518d9f434ce06a))
* **platform:** expose Plugin, Core, makeScheduler, makePlatform via Platform.T ([0df4bf3](https://github.com/ReventlessDev/reventless-core/commit/0df4bf333ea4f9c0e51e96df1ad0da4ab471ffe8))
# [3.0.0-alpha.8](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-aws@3.0.0-alpha.7...@reventlessdev/reventless-aws@3.0.0-alpha.8) (2026-03-02)

**Note:** Version bump only for package @reventlessdev/reventless-aws

# [3.0.0-alpha.7](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-aws@3.0.0-alpha.6...@reventlessdev/reventless-aws@3.0.0-alpha.7) (2026-03-02)

**Note:** Version bump only for package @reventlessdev/reventless-aws

# [3.0.0-alpha.6](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-aws@3.0.0-alpha.5...@reventlessdev/reventless-aws@3.0.0-alpha.6) (2026-03-01)

* feat(reventless-spec)!: swap namespaces — spec→Reventless, core→ReventlessCore ([0fcf24e](https://github.com/ReventlessDev/reventless-core/commit/0fcf24e3fc1dcc88e9ee741dc99eb7bd726f9fd7))
* feat(reventless-core)!: rename package from @reventlessdev/reventless to @reventlessdev/reventless-core ([5e93146](https://github.com/ReventlessDev/reventless-core/commit/5e9314692b5b5d60beee187564ba94bc9fd46c05))
### Features

* **rescript-effect:** Effect library bindings + stream-based framework handlers ([#30](https://github.com/ReventlessDev/reventless-core/issues/30)) ([f2ca5cf](https://github.com/ReventlessDev/reventless-core/commit/f2ca5cf3d56d66a9f4ab56b543d7bf82e48448dd))
* **reventless-aws:** implement AWS StateViewSlice_Builder with DynamoDB/AppSync adapters ([04cc0f3](https://github.com/ReventlessDev/reventless-core/commit/04cc0f351ec4d8d18ec6eae8a7b81783ed9ecb83))

### BREAKING CHANGES

* ReventlessSpec namespace renamed to Reventless; the reventless-core
package namespace renamed from Reventless to ReventlessCore.
All usages of ReventlessSpec.* must be updated to Reventless.*;
all usages of Reventless.* (core) in dependent packages must be updated to ReventlessCore.*

* package renamed for consistency with sibling packages
and the repository name. ReScript namespace "Reventless" is unchanged —
no source code updates required.

- git mv reventless/reventless → reventless/reventless-core
- package.json and rescript.json name updated to @reventlessdev/reventless-core
- reventless-aws and reventless-local dependency references updated
- Root package.json and rescript.json renamed to "reventless-monorepo" to
  avoid name collision that caused ReScript to skip building the sub-package
- Updated recompiled .res.mjs output files with new relative import paths
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
