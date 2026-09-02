# Change Log

All notable changes to this project will be documented in this file.
See [Conventional Commits](https://conventionalcommits.org) for commit guidelines.

# 3.0.0-alpha.127 (2026-09-02)

* feat(aws)!: the messaging sender is configuration, and a stack can choose to only log ([23b8b4b](https://github.com/ReventlessDev/reventless-core/commit/23b8b4bfe9c70555de4d74266ca686cb427485ca))
### Features

* **dcb:** a boundary that cannot derive its scope says so ([db79969](https://github.com/ReventlessDev/reventless-core/commit/db79969df36bd90607425f6a22b4624227cfc4a0))

### BREAKING CHANGES

* `Capability_Messaging_Ses.make` is replaced by
`Capability_Messaging.make(~name)`, which reads the transport and the address
from config; the SES module keeps only `emailSender`. A deployment that named its
sender in code must move it to `platform:messagingEmailSender` or the deploy is
refused.



# 3.0.0-alpha.126 (2026-09-01)

**Note:** Version bump only for package @reventlessdev/reventless-spec





# 3.0.0-alpha.125 (2026-09-01)

### Bug Fixes

* **automation:** a mapping is handed the envelope's id ([9ee482c](https://github.com/ReventlessDev/reventless-core/commit/9ee482c5ad0aae09efd1259eeb7f39b781867b91))
* **capabilities:** a plugin's geocoding need was declared nowhere and failed silently ([67917dd](https://github.com/ReventlessDev/reventless-core/commit/67917dd504b43fa78b7c6a51644c9eae656b7f6b))
* feat(example)!: model product and category images as attachment sets ([6ae18d8](https://github.com/ReventlessDev/reventless-core/commit/6ae18d896215b448177ba0516e74bfda5f88d2db))
### Features

* **capabilities:** a plugin can send a message without naming a provider ([b001a1e](https://github.com/ReventlessDev/reventless-core/commit/b001a1e9361a0f4d0affe228cb4c08c38a5a995e))
* **plugin:** the admin lifecycle commands name their argument ([ea552ec](https://github.com/ReventlessDev/reventless-core/commit/ea552ec64e5db0b3dc465c0d9a80cac89627f727))
* **spec:** a command declares its lifecycle edge as a value ([40eee9f](https://github.com/ReventlessDev/reventless-core/commit/40eee9f7723dc05e418be680528f01967d074da4))
* **spec:** a graft leaves a trace the deployed plugin can read ([c08ff6c](https://github.com/ReventlessDev/reventless-core/commit/c08ff6c0f6177d58603e7ae1e5cec392d9bac16a))
* **spec:** graft-trait, a CLI that runs a trait's emitter ([1b87399](https://github.com/ReventlessDev/reventless-core/commit/1b87399987033765d6a1ee8ea22ab7f02056e9c0))
* **traits:** a conformance run leaves something a machine can read ([cd9cb81](https://github.com/ReventlessDev/reventless-core/commit/cd9cb81aa643f8e30ccf072df458fdc136897746))
* **traits:** a listing reads a trait instead of being told about it ([8a23219](https://github.com/ReventlessDev/reventless-core/commit/8a23219c5a69011ef9310ebf8bfcbf9315a577ba))

### BREAKING CHANGES

* ProductAdded/CategoryAdded lose their image field and
ChangeProductImage/ChangeCategoryImage are replaced; the alpha event log is
wiped on the next deploy.



# 3.0.0-alpha.124 (2026-08-27)

* feat(spec)!: reflect the command direction across a port, both halves ([f2fe258](https://github.com/ReventlessDev/reventless-core/commit/f2fe258d195b74f4a61488edee305665341020ea))
* feat(spec)!: read the port's translation table off the mapping's arms ([956348a](https://github.com/ReventlessDev/reventless-core/commit/956348a9fcb256cfff9db51809bdc27d73360e6c))
* feat(spec)!: keep the amount in minor units, and add times and allocate ([6ff6308](https://github.com/ReventlessDev/reventless-core/commit/6ff630875f9b126b2f87b980a4dbb56582f8aebe))
* feat(spec)!: hold a money amount in the currency's own units ([94d3bba](https://github.com/ReventlessDev/reventless-core/commit/94d3bbaf0c47a639c20de6847c4615070ad51b38))

### BREAKING CHANGES

* `ExtensionPointMapping.Mapping` gains `acceptedCommands` and
`ExtensionMapping.Mapping` gains `issuedCommands`; both are derived, so a
mapping the ppx can read needs no source change, and one it cannot names itself
at compile time. Definitions persisted before the two new def fields must be
re-emitted before a consumer can read them as present — and until then they
decode as None, which means unknown, not "issues nothing".
* `ExtensionPointMapping.Mapping` requires `publishedEvents` and
`ExtensionMapping.Mapping` requires `handledEvents`; the ppx injects both for
mappings it can read, so app code must build against the matching ppx. Plugin
definitions persisted before the new fields must be re-emitted before a consumer
reads them as present.
* reverts the wire shape to whole minor units, so a log written
against the intervening commit reads a hundredfold low. Nothing released carried
the decimal form.
* stored amounts do not migrate. A log written before this holds
minor units and now decodes a hundredfold high, cleanly and without complaint —
a log that has to survive needs an upcaster written before this is deployed, and
a demo log needs discarding and reseeding. A stored currency outside the ten no
longer decodes; admit it in the generator or migrate the data.



# 3.0.0-alpha.123 (2026-08-23)

### Features

* **querydb:** serve owner-scoped lists from an index instead of a filtered Scan ([ad26c28](https://github.com/ReventlessDev/reventless-core/commit/ad26c284b4b0650fa3f3b6109ed33bbfe8608f6d))


# 3.0.0-alpha.122 (2026-08-22)

* feat(core)!: a slice that has given up says so ([f5559ab](https://github.com/ReventlessDev/reventless-core/commit/f5559abede3a9cf2c9a48aadc69a666c46cc75bf))

### BREAKING CHANGES

* `onExhausted` is required on the Translation and Automation
module types. ReScript has no optional module-type fields, so the alternative
was a PPX-injected default — and defaulting this one to silence is the bug.
A slice now states what abandonment means for its domain, `None` included.
GeocodeCustomerAddress answers with MarkAddressUnresolvable; the others say
nothing, on purpose.



# 3.0.0-alpha.121 (2026-08-21)

### Bug Fixes

* **deps:** update sury to 11.0.0-rc.2 to fix unreachable union constructors ([fa5744f](https://github.com/ReventlessDev/reventless-core/commit/fa5744fed8de975e2f14725c856c6e5ce7d04a74))


# 3.0.0-alpha.120 (2026-08-20)

### Features

* **spec:** type a geocoder's answer as one Geolocation value ([157be7a](https://github.com/ReventlessDev/reventless-core/commit/157be7aca4806ae19dba1f58979af13b88dc1821))


# 3.0.0-alpha.119 (2026-08-20)

### Features

* **api:** emit a tagged-union state field as a GraphQL union ([3a380c0](https://github.com/ReventlessDev/reventless-core/commit/3a380c0ab055b87048d90a852ec1664f6aab6b00))


# 3.0.0-alpha.118 (2026-08-18)

### Bug Fixes

* **core:** report the real reason a decode failed ([233c835](https://github.com/ReventlessDev/reventless-core/commit/233c835be47cb83fbd247ab0d8a7073cad622fee)), closes [DZakh/sury#392](https://github.com/DZakh/sury/issues/392)
* feat(sury)!: migrate to sury 11.0.0-rc.1 ([2cf8969](https://github.com/ReventlessDev/reventless-core/commit/2cf8969a222ce1b775563668a4126cb20611966c))
### Features

* **spec,ppx:** uploadable types that derive their store from the field name ([722b404](https://github.com/ReventlessDev/reventless-core/commit/722b4044a2e8dfb6a34231d6bfb529526de38b20))
* **spec:** ImageRef and FileRef, for media the platform does not own ([a63425c](https://github.com/ReventlessDev/reventless-core/commit/a63425cba5fd381da6deaabccc94501739e3ad59))

### BREAKING CHANGES

* sury is a direct dependency of the published packages and
its schema and serialization surface changed; consumers must migrate to
sury 11.



# 3.0.0-alpha.117 (2026-08-18)

### Bug Fixes

* **api:** declare the reference door in the SDL every backend is built from ([5c1857e](https://github.com/ReventlessDev/reventless-core/commit/5c1857ea90ff40305a1c44a9e57043528e6a93aa))
### Features

* **core:** let a reference name a retired row, and let an elevated caller open one ([9e2623a](https://github.com/ReventlessDev/reventless-core/commit/9e2623a4b22487561607fcc0ca19d51726069ee4))


# 3.0.0-alpha.116 (2026-08-16)

### Features

* **ppx:** declare a command's lifecycle edge once, as [@transition](https://github.com/transition) ([dd35130](https://github.com/ReventlessDev/reventless-core/commit/dd3513014f14b71879ee21263c6755d3c3d95096))


# 3.0.0-alpha.115 (2026-08-16)

### Features

* **core:** let [@retired](https://github.com/retired) name a lifecycle state, not only a boolean ([6bb346b](https://github.com/ReventlessDev/reventless-core/commit/6bb346b4f6a5f33826fc24537953482a76067177))
* **core:** mark the state that retires a row, and allow more than one ([cb1461f](https://github.com/ReventlessDev/reventless-core/commit/cb1461f024d3ca3b53fd9c8b010a054e3fcc4555))
* **core:** publish queryableDef.retiredField from the [@retired](https://github.com/retired) annotation ([b44436a](https://github.com/ReventlessDev/reventless-core/commit/b44436a997b6c4ff0531f0b07d793cc858eef94a))
* **spec:** [@retired](https://github.com/retired) state-field annotation and its schema emission ([2d8234b](https://github.com/ReventlessDev/reventless-core/commit/2d8234b6b3dd8f479031a67eb5b4b47b5c0c2ff9))
* **spec:** classify a caller against a view's retirement flag ([5031ce5](https://github.com/ReventlessDev/reventless-core/commit/5031ce573ce56d2407888c7777274e5580c4fb51))


# 3.0.0-alpha.114 (2026-08-15)

**Note:** Version bump only for package @reventlessdev/reventless-spec





# 3.0.0-alpha.113 (2026-08-14)

**Note:** Version bump only for package @reventlessdev/reventless-spec





# 3.0.0-alpha.112 (2026-08-13)

**Note:** Version bump only for package @reventlessdev/reventless-spec





# 3.0.0-alpha.111 (2026-08-12)

### Features

* **scripts:** publish the platform SDL instead of copying it by hand ([3f28ceb](https://github.com/ReventlessDev/reventless-core/commit/3f28cebe7f9f947894105592d7ff7e5c07043d8f))


# 3.0.0-alpha.110 (2026-08-12)

### Features

* **ppx:** let a field say [@owner](https://github.com/owner) instead of spelling out its schema ([3bb0a4b](https://github.com/ReventlessDev/reventless-core/commit/3bb0a4bf3e5823fa929815fbe6f47203ba7958d7))


# 3.0.0-alpha.109 (2026-08-12)

### Features

* **plugin:** publish the access a component's authorization rule implies ([e0d0f09](https://github.com/ReventlessDev/reventless-core/commit/e0d0f096b72fe44b185ed28dc1c133364fa841b8))
* **plugin:** publish which field ties a component to its owner ([ca71289](https://github.com/ReventlessDev/reventless-core/commit/ca7128931ce525af0d7d3a4487b2b5c54b19bec0))
* **spec:** let a record name the field that identifies its owner ([b69ee91](https://github.com/ReventlessDev/reventless-core/commit/b69ee9123e6beb38fcdd716519103ab9328213c6))
* **spec:** let the environment name the groups exempt from owner scoping ([2de5c51](https://github.com/ReventlessDev/reventless-core/commit/2de5c5118347a46998f9ab603308fca09addf00b))


# 3.0.0-alpha.108 (2026-08-11)

### Features

* **api:** infer a queryable's key field and publish its provenance ([c835a42](https://github.com/ReventlessDev/reventless-core/commit/c835a42a0da07cdc4a3f010212e1f340a4a0ca27))
* **plugin:** publish singleQueryField on queryableDef ([a724ab5](https://github.com/ReventlessDev/reventless-core/commit/a724ab573614792c0615d68b6486b94da14f9f82))


# 3.0.0-alpha.107 (2026-08-10)

### Bug Fixes

* **core:** collect [@ref](https://github.com/ref) declared on an array field ([6f9e2fe](https://github.com/ReventlessDev/reventless-core/commit/6f9e2fef2568ad57a8bf2efbaa9cd4830a947f26))


# 3.0.0-alpha.106 (2026-08-09)

### Features

* **ppx,spec,core:** [@live](https://github.com/live) on state declarations → top-level x-reventless-live schema key ([0f38f38](https://github.com/ReventlessDev/reventless-core/commit/0f38f38dc83c38da2fde6615b89a98cd7fda6fed))


# 3.0.0-alpha.105 (2026-08-09)

**Note:** Version bump only for package @reventlessdev/reventless-spec





# 3.0.0-alpha.104 (2026-08-09)

### Bug Fixes

* **spec:** see payload-less variants inside a mixed union, and say what differs ([e82e742](https://github.com/ReventlessDev/reventless-core/commit/e82e742201941f978bfde809eeb2581fdda453c5))


# 3.0.0-alpha.103 (2026-08-09)

### Bug Fixes

* **aws:** heal a persisted structure that predates a required list field ([dc4c42c](https://github.com/ReventlessDev/reventless-core/commit/dc4c42cab5a7db538d90edbce6d13b949830aad6))


# 3.0.0-alpha.102 (2026-08-08)

### Features

* **core,spec:** surface a write-side component's declared error types ([c9c2505](https://github.com/ReventlessDev/reventless-core/commit/c9c25057c70595fe27d73447c9aef9b451f86168))


# 3.0.0-alpha.101 (2026-08-05)

**Note:** Version bump only for package @reventlessdev/reventless-spec





# 3.0.0-alpha.100 (2026-08-04)

### Features

* **outbound:** hand translate its geocoder instead of making it fetch one ([fb18312](https://github.com/ReventlessDev/reventless-core/commit/fb1831216b37c9562868c46e1a09054e69418c67))


# 3.0.0-alpha.99 (2026-08-03)

### Bug Fixes

* **geocoding:** calibrate the confidence rule against a real index ([cd72b27](https://github.com/ReventlessDev/reventless-core/commit/cd72b2741460c871db2915a8603f7837b8191187))


# 3.0.0-alpha.98 (2026-08-03)

### Features

* **aws:** let a deployment hand its plugins a geocoder ([143bf41](https://github.com/ReventlessDev/reventless-core/commit/143bf4137765362ce07dd42db0f4a57057da9f13))
* **outbound:** let an outbound slice read an aggregate, and geocode addresses with it ([867e63e](https://github.com/ReventlessDev/reventless-core/commit/867e63e774ebc8b78b2b19c78645c8a12a8d06f6))


# 3.0.0-alpha.97 (2026-08-02)

### Features

* **ppx:** add [@offload](https://github.com/offload) field shorthand with per-field threshold ([3d5e3b5](https://github.com/ReventlessDev/reventless-core/commit/3d5e3b5da5010547ce0eaf7d94d660daec67feed))


# 3.0.0-alpha.96 (2026-08-02)

### Bug Fixes

* **spec:** add Offload.toJson to serialize a payload as untagged wire JSON ([6a4c60f](https://github.com/ReventlessDev/reventless-core/commit/6a4c60f606dd6657082981acf75a90070099bf29))


# 3.0.0-alpha.95 (2026-08-02)

**Note:** Version bump only for package @reventlessdev/reventless-spec





# 3.0.0-alpha.94 (2026-08-02)

### Features

* **spec:** add [@offload](https://github.com/offload) inline-or-reference field primitive ([a54c39c](https://github.com/ReventlessDev/reventless-core/commit/a54c39ceb45b2c0b63caffd8ad039e732a5eb95d))
* **spec:** add Offload prepare/resolve/cachedFetch client helpers ([2855990](https://github.com/ReventlessDev/reventless-core/commit/2855990ba5cc56bd691460d3614ac666382c7fac))
* **spec:** make plugin structure/apiSchemaFragment offloadable payloads ([a0391bf](https://github.com/ReventlessDev/reventless-core/commit/a0391bf26f91035460cbf90f52d105a1003414c3))


# 3.0.0-alpha.93 (2026-08-02)

### Features

* **aws,core,spec,seed-aws:** expire uploads nobody committed a reference to ([f63e84c](https://github.com/ReventlessDev/reventless-core/commit/f63e84c1a11cc350b799a6f69a2e7427cf1ea6e9))


# 3.0.0-alpha.92 (2026-08-01)

* feat(aws,core,spec)!: qualify store prefixes by plugin and refuse name collisions ([da39405](https://github.com/ReventlessDev/reventless-core/commit/da394059d9f8f981bf7adc79e2c1ce2b429e0267))
### Features

* **spec:** a coordinate is one declared point, not two fields and a name guess ([bfe2f90](https://github.com/ReventlessDev/reventless-core/commit/bfe2f90241492422d6c242e3f50e31b81ed2a010))

### BREAKING CHANGES

* objects minted under the old bare prefix are orphaned and their
refs unresolvable. The migration is `seed:reset` for the owning plugin, then
re-seed. Legacy-prefix grandfathering was considered and deliberately dropped —
it would have added a permanent prefix SET across the deploy argument, both store
configs, the presign IAM fan-out, the release scope check and the stack output,
to spare a disposable stack one wipe.



# 3.0.0-alpha.91 (2026-08-01)

### Bug Fixes

* **spec,core:** heal a missing scalar on read ([de9a98e](https://github.com/ReventlessDev/reventless-core/commit/de9a98ec5fe11ec19bef80626e99244d9c30a6b1))
* **spec,core:** make the storageRef annotation optional, as its readers already are ([c8477c5](https://github.com/ReventlessDev/reventless-core/commit/c8477c5c34384b864c06716dc5896310629dc349))


# 3.0.0-alpha.90 (2026-08-01)

### Features

* **spec:** add DateRange semantic type ([d85b6cc](https://github.com/ReventlessDev/reventless-core/commit/d85b6cc18241644905241df2abd99949dd758059))


# 3.0.0-alpha.89 (2026-07-31)

### Features

* **spec:** add Money and a closed ISO 4217 Currency ([d4852ab](https://github.com/ReventlessDev/reventless-core/commit/d4852ab63e823e39fac793c4fa5ac31470db9655))


# 3.0.0-alpha.88 (2026-07-30)

### Bug Fixes

* **core:** a command's field markers reach the wire, and its optional fields stay optional ([f1c1112](https://github.com/ReventlessDev/reventless-core/commit/f1c1112e9baa6b06e50097a5a618f49c9301cd0a))


# 3.0.0-alpha.87 (2026-07-30)

### Bug Fixes

* **spec,core:** record the storageRef annotation instead of inferring it ([06fb5d6](https://github.com/ReventlessDev/reventless-core/commit/06fb5d671db91fb536acefd0c2db69d98671da39))
* **spec:** read a semantic marker through an optional field's wrapper ([abebaa9](https://github.com/ReventlessDev/reventless-core/commit/abebaa9e6c73986765bb3de589ba0414eb0d85da))


# 3.0.0-alpha.86 (2026-07-30)

### Features

* **spec,local:** resolve capability manifests beyond the example topology ([8bfadd5](https://github.com/ReventlessDev/reventless-core/commit/8bfadd5beef90c0c9f6f6f3fbb753c8b789469ed))
* **spec:** semantic branded scalars — Email, Url, Phone, Percent, Color, Bytes, Duration ([2e64ff9](https://github.com/ReventlessDev/reventless-core/commit/2e64ff992e913c038a71659c731c25a104e3c5a9))


# 3.0.0-alpha.85 (2026-07-30)

### Features

* **spec,core,local:** emit capabilities.json from the plugin build ([57a3276](https://github.com/ReventlessDev/reventless-core/commit/57a3276a6b02af93490a8b460e3aa158b7e0e0f8))
* **spec,core:** derive the platform capability list — inference and generation (stage 3) ([8ab4d25](https://github.com/ReventlessDev/reventless-core/commit/8ab4d2504bd717487fbc87a0f5a053024c8258f9))


# 3.0.0-alpha.84 (2026-07-29)

### Features

* **plugin:** why a read model is named by that field ([699ef8e](https://github.com/ReventlessDev/reventless-core/commit/699ef8e72f1b1d82fb04672739e5e4a8db61ae9a))


# 3.0.0-alpha.83 (2026-07-28)

### Features

* **platform:** provision object stores from the fields that declare them ([b5e2a1e](https://github.com/ReventlessDev/reventless-core/commit/b5e2a1ec88099941c113e4963f9c4b346b96b0d6))


# 3.0.0-alpha.82 (2026-07-28)

### Features

* **spec:** one semantic marker every typed semantic marks itself with ([aa18afc](https://github.com/ReventlessDev/reventless-core/commit/aa18afcf04c8edad9afe27e6fa4261d01e184da7))
* **spec:** StorageRef — the first semantic type, declared on the field's type ([44f15c3](https://github.com/ReventlessDev/reventless-core/commit/44f15c37de71261d701d18a9f1ada6f481c4a8dc))


# 3.0.0-alpha.81 (2026-07-26)

### Features

* **auto-ui:** declare command target state via [@target](https://github.com/target)State ([5fc0374](https://github.com/ReventlessDev/reventless-core/commit/5fc03741a8816c57085b86a4ad7d595e3b690193)), closes [#5](https://github.com/ReventlessDev/reventless-core/issues/5)
* **auto-ui:** declare field semantics + dashboard metrics ([@semantic](https://github.com/semantic), [@metric](https://github.com/metric)) ([d74ff77](https://github.com/ReventlessDev/reventless-core/commit/d74ff7721e18e8638a82931a370a549b304dac94)), closes [#4](https://github.com/ReventlessDev/reventless-core/issues/4)


# 3.0.0-alpha.80 (2026-07-22)

### Features

* **core:** annotate event-collector logs with the element's comp ([eda413a](https://github.com/ReventlessDev/reventless-core/commit/eda413ab00eb8bb02b30e029af2d6221e3e9ba75)), closes [#1](https://github.com/ReventlessDev/reventless-core/issues/1)


# 3.0.0-alpha.79 (2026-07-17)

**Note:** Version bump only for package @reventlessdev/reventless-spec





# 3.0.0-alpha.78 (2026-07-16)

### Features

* **aws:** consume per-component runtime hints; fold into shared command Lambdas ([7ba2485](https://github.com/ReventlessDev/reventless-core/commit/7ba248579f2472f2fc847b26033927199353f3e6))
* **core:** thread per-component runtime hints from plugin.json (spec/infra/core/local) ([a94f419](https://github.com/ReventlessDev/reventless-core/commit/a94f4199c4ac7eeeb24dd0a71d58fb73c1e514e6))


# 3.0.0-alpha.77 (2026-07-15)

### Performance Improvements

* **spec:** reverse-convert DcbTag extraction instead of stringify round-trip ([4311c7b](https://github.com/ReventlessDev/reventless-core/commit/4311c7b863f99e582911ced529d77dca7cc36381))


# 3.0.0-alpha.76 (2026-07-12)

### Features

* **admin:** make the API fragment registry per-target (Domain | Platform) ([30491a9](https://github.com/ReventlessDev/reventless-core/commit/30491a9e14b4236c98cc756efb6de68ede1e77d7))
* **admin:** retire the Plugin-aggregate UI-fragment path in favour of the registry slices ([1dbc708](https://github.com/ReventlessDev/reventless-core/commit/1dbc708e7439b34ff970cc3d963d7835a8c6fd48))


# 3.0.0-alpha.75 (2026-07-11)

### Features

* **infra:** add DeployBootstrap seam for generated deploy programs ([f0dc868](https://github.com/ReventlessDev/reventless-core/commit/f0dc8686396d21e7b39667eb0825b2e57fe4dabf))


# 3.0.0-alpha.74 (2026-07-11)

### Bug Fixes

* **build:** mark tests as dev-only sources so dependents don't compile them ([28b3b1c](https://github.com/ReventlessDev/reventless-core/commit/28b3b1ccfeaafc1d7050a86ce2362f32e4299187))


# 3.0.0-alpha.73 (2026-07-11)

### Bug Fixes

* **plugin-lifecycle:** heal message decode of definitions persisted before a schema field existed ([6bb3e72](https://github.com/ReventlessDev/reventless-core/commit/6bb3e7259ad606a0f77fb670bcfc680256592003))


# 3.0.0-alpha.72 (2026-07-10)

### Features

* **plugin-structure:** capture per-component chapter grouping for the deployed graph ([f9c88a9](https://github.com/ReventlessDev/reventless-core/commit/f9c88a9a48d8c032ffe23f9e5277caf12c29e85c))


# 3.0.0-alpha.71 (2026-07-10)

**Note:** Version bump only for package @reventlessdev/reventless-spec





# 3.0.0-alpha.70 (2026-07-10)

### Features

* **reventless-ppx:** add [@group](https://github.com/group)By state-field annotation → x-reventless-group-by ([9e7a7b2](https://github.com/ReventlessDev/reventless-core/commit/9e7a7b29e54fb4eda1c6a145c0e7b6dcf26940ee))


# 3.0.0-alpha.69 (2026-07-08)

### Features

* **reventless-core:** classify plugins by kind in the lifecycle read model ([64e3f22](https://github.com/ReventlessDev/reventless-core/commit/64e3f22b8114a771886b7c8ec023e95971413c0b))


# 3.0.0-alpha.68 (2026-07-07)

### Bug Fixes

* **reventless-aws:** thread inferred DCB scope into the deployed command handler ([4d8327f](https://github.com/ReventlessDev/reventless-core/commit/4d8327fad8659a1cde8c36098c72392737437af1))


# 3.0.0-alpha.67 (2026-07-06)

**Note:** Version bump only for package @reventlessdev/reventless-spec





# 3.0.0-alpha.66 (2026-07-05)

### Bug Fixes

* **spec:** republish DcbTag to ship [@schema-generated](https://github.com/schema-generated) derivedPartitionTagSchema ([c110c26](https://github.com/ReventlessDev/reventless-core/commit/c110c26ba54617a8455e205ed77aeba5212f6170))


# 3.0.0-alpha.65 (2026-07-05)

### Features

* @[@reventless](https://github.com/reventless).systemCallable slice opt-in for deploy-time system callers ([c5ed537](https://github.com/ReventlessDev/reventless-core/commit/c5ed537309f8e4b7d4a4d4af1ed1ec83d060aea3))
* **reventless-aws:** Postgres change-feed relay auto-wiring (B2.3d) ([62b430f](https://github.com/ReventlessDev/reventless-core/commit/62b430f1e6d8ec1f172de0cca324f7f26aaf5fcb))


# 3.0.0-alpha.64 (2026-07-03)

**Note:** Version bump only for package @reventlessdev/reventless-spec





# 3.0.0-alpha.63 (2026-07-02)

### Bug Fixes

* **spec,interop,layer-builder:** generator/protocol/build failure modes (plan A8,A9) ([66d7a54](https://github.com/ReventlessDev/reventless-core/commit/66d7a54e3a0afdbfe3ea2975f517d1d64d52c180))


# 3.0.0-alpha.62 (2026-06-29)

### Features

* external-system boxes for translation slices (Event Graph data) ([3f8ad39](https://github.com/ReventlessDev/reventless-core/commit/3f8ad39b78a3cb1182d59a0e1fb203b7dcb7379b))


# 3.0.0-alpha.61 (2026-06-27)

### Bug Fixes

* **dcb:** harden scope inference against real catalog (partitionHint + rule 3) ([acea3f8](https://github.com/ReventlessDev/reventless-core/commit/acea3f8bb0e96a0993d81fd1aa521e9456982a13))
* **dcb:** only infer cross-partition for SCALAR foreign references ([57416bf](https://github.com/ReventlessDev/reventless-core/commit/57416bf150df4c801577a60bf72f69abe9c701a8))
### Features

* **dcb:** add tag-scope inference core + runtime diff logging (Phase 1) ([5e17560](https://github.com/ReventlessDev/reventless-core/commit/5e17560fefc4272deb8b501dcb8ecef11c3a7c23))
* **dcb:** thread inferred tag scope into the decision-query wiring (Phase 2) ([63445b2](https://github.com/ReventlessDev/reventless-core/commit/63445b239bc368932b043872ca16b6c35f723566))
* **dcb:** validate [@cross](https://github.com/cross)Partition annotations against inferred scope ([acbb387](https://github.com/ReventlessDev/reventless-core/commit/acbb3870d32bbd4ef7e61ed52795800b87660e93))


# 3.0.0-alpha.60 (2026-06-22)

### Bug Fixes

* **domain-graph:** route EP commands only with a real inbound protocol ([647d1fa](https://github.com/ReventlessDev/reventless-core/commit/647d1fa0194189f4d53cf5fca0f2ef4045b983f9))
* **ppx:** compose [@ref](https://github.com/ref) with the DCB tag key for plural *Ids fields ([cba2193](https://github.com/ReventlessDev/reventless-core/commit/cba2193d1c377c1bf91dee1f01da2a91a82ab488))
### Features

* **structure:** mark API-exposed commands for the event-graph badge ([8cd6faa](https://github.com/ReventlessDev/reventless-core/commit/8cd6faa0a66c6cf1b4b5eea26df6f70c540b67a4))


# 3.0.0-alpha.59 (2026-06-21)

### Features

* **dcb:** cross-partition secondary-tag reads (Phase 7) ([9e1f8b3](https://github.com/ReventlessDev/reventless-core/commit/9e1f8b3595004b92148dd053aae380078baa42a3))
* **dcb:** per-slice readConsistency override for StateChangeSlice decision reads ([65516f7](https://github.com/ReventlessDev/reventless-core/commit/65516f7fc62daaad51edef2c668cc7b362506364))


# 3.0.0-alpha.58 (2026-06-21)

### Features

* **dcb:** warn on composite reads that silently miss extra-tagged events (Issue 5) ([9e14f68](https://github.com/ReventlessDev/reventless-core/commit/9e14f68c76b0e5acf95878d89693eec26e0e1760))


# 3.0.0-alpha.57 (2026-06-20)

### Features

* **dcb:** narrow query clauses to types that can carry each tag (Issue 14) ([6bceae6](https://github.com/ReventlessDev/reventless-core/commit/6bceae675b91154b5a1abf73a6aaca56533cbbe8))


# 3.0.0-alpha.56 (2026-06-17)

* feat!: harmonize plugin make() across aggregate/DCB/hybrid; AutoUI default-on ([6f3b95e](https://github.com/ReventlessDev/reventless-core/commit/6f3b95e6aa8a136c6e837346c41a3a4dff0f9405))
### Features

* **core:** carry emitted-event field schemas in pluginStructure (Phase 6.3) ([693d452](https://github.com/ReventlessDev/reventless-core/commit/693d4529ee4c66a2a4a4b0d4d7efb104cf94bcab))

### BREAKING CHANGES

* makeAutoUIManifest signature dropped ~aggregates and
~readModels; replaced with ~pluginStructure. Hand-written Plugin.res files
that pass ~uiBundleUrl to plugin.make must drop the arg and rely on the
generator-emitted env var read.



# 3.0.0-alpha.55 (2026-06-12)

### Features

* **vscode:** jump from event-graph nodes to source + show Internal components in the dev graph ([6a6e5e4](https://github.com/ReventlessDev/reventless-core/commit/6a6e5e466c6ea5c0c7315ccc37a538e0b496c99a))


# 3.0.0-alpha.54 (2026-06-10)

* refactor(reventless-local)!: rename reventless-in-memory to reventless-local ([f36e17c](https://github.com/ReventlessDev/reventless-core/commit/f36e17c407714ab9740393fac96865d6a5c143c9))
### Features

* **logging:** sink-aware ANSI formatting — clean JSON in non-TTY sinks (Tier 1) ([32ae533](https://github.com/ReventlessDev/reventless-core/commit/32ae5337a45ff9cbd26754b5b1c71c5c7070507b))
* **reventless-core:** extension-point source events in pluginStructure ([9c47a0e](https://github.com/ReventlessDev/reventless-core/commit/9c47a0ea9a1643ac12fbe8dc1c43244e580de024))

### BREAKING CHANGES

* @reventlessdev/reventless-in-memory -> @reventlessdev/reventless-local;
namespace ReventlessInMemory -> ReventlessLocal.



# 3.0.0-alpha.53 (2026-06-08)

### Features

* **logging:** sink-aware ANSI formatting — clean JSON in non-TTY sinks (Tier 1) ([7da6256](https://github.com/ReventlessDev/reventless-core/commit/7da62568eaa06c2bedf5d7ad6d10b1ec006a6b75))


# 3.0.0-alpha.52 (2026-06-08)

### Features

* **reventless-core:** extension-point source events in pluginStructure ([1e1d925](https://github.com/ReventlessDev/reventless-core/commit/1e1d9258b5a228b9fdfa003348a5367281573b3c))


# 3.0.0-alpha.51 (2026-06-06)

* refactor(reventless-local)!: rename reventless-in-memory to reventless-local ([966855f](https://github.com/ReventlessDev/reventless-core/commit/966855fd31e518d56a381bf40204735809cead15))

### BREAKING CHANGES

* @reventlessdev/reventless-in-memory -> @reventlessdev/reventless-local;
namespace ReventlessInMemory -> ReventlessLocal.



# 3.0.0-alpha.50 (2026-06-04)

**Note:** Version bump only for package @reventlessdev/reventless-spec





# 3.0.0-alpha.49 (2026-05-25)

**Note:** Version bump only for package @reventlessdev/reventless-spec





# 3.0.0-alpha.48 (2026-05-25)

### Features

* **readmodel:** add ReadModelStream variant for live-updating read models ([3d816fb](https://github.com/ReventlessDev/reventless-core/commit/3d816fb50e0e66693ae4a0a626f4d5b4e496c3b1))


# 3.0.0-alpha.47 (2026-05-21)

* feat(admin)!: replace direct DynamoDB retire write with Retire/Retired event flow ([7f5f018](https://github.com/ReventlessDev/reventless-core/commit/7f5f018e714e247331d143c304c0d671c2ac7c84))

### BREAKING CHANGES

* Platform.deployPlugin no longer accepts ~version. Generated
Main.res files are regenerated; any direct caller must drop the arg.



# 3.0.0-alpha.46 (2026-05-20)

### Features

* **plugin:** wire dcbEventLog into pluginDefinition for cross-plugin DCB routing (Phase 4) ([07b78f3](https://github.com/ReventlessDev/reventless-core/commit/07b78f359f8f039992ec0ce7922085b165695537))


# 3.0.0-alpha.45 (2026-05-19)

### Features

* @[@reventless](https://github.com/reventless).async opt-in; sync command dispatch as default ([85885c8](https://github.com/ReventlessDev/reventless-core/commit/85885c80a70cfcbf4e1ac068c7115e6b6cfa8400))


# 3.0.0-alpha.44 (2026-05-18)

### Bug Fixes

* **admin:** unblock admin → plugin SNS publish chain (3 bugs) ([e3418bb](https://github.com/ReventlessDev/reventless-core/commit/e3418bbf2e08575f28e0a9cc193f373a30dbb036))
* **spec:** restore payload-less filter in extractVariantNames; route acceptedTags through extractAllVariantNames ([208f644](https://github.com/ReventlessDev/reventless-core/commit/208f644cc0e21cb7c2ad3cf7bf43b5e7a99732f7))


# 3.0.0-alpha.43 (2026-05-17)

### Bug Fixes

* **deps:** pin sury-ppx to 11.0.0-alpha.2 to prevent prerelease drift ([c9d05fe](https://github.com/ReventlessDev/reventless-core/commit/c9d05fe5118a9c0442ca3e071f2606b3a139fc81))


# 3.0.0-alpha.42 (2026-05-17)

### Bug Fixes

* **aws:** wire schedulerRoleArn through admin registers; default heartbeat to 5 min ([f9580a2](https://github.com/ReventlessDev/reventless-core/commit/f9580a2fc7f85a67747ccaab87358f303bd90ab9))


# 3.0.0-alpha.41 (2026-05-17)

### Bug Fixes

* **deps:** pin sury to 11.0.0-alpha.4 to unblock Lambda Layer deploys ([643d925](https://github.com/ReventlessDev/reventless-core/commit/643d92527fa9d092da9bef8547591e39a4c609dd))


# 3.0.0-alpha.40 (2026-05-16)

### Features

* **ppx:** add @[@reventless](https://github.com/reventless).visibility to hide components from AutoUI ([bd302cf](https://github.com/ReventlessDev/reventless-core/commit/bd302cfc5bd5d4dfe50c8e1bf8596ab67e36c74e))


# 3.0.0-alpha.39 (2026-05-16)

### Bug Fixes

* **ppx:** drop [@allowed](https://github.com/allowed)States witness; spec.status as option<string> ([cc0eed0](https://github.com/ReventlessDev/reventless-core/commit/cc0eed0e499c70009603619dd9f23a6bb2dd35df))
### Features

* **ppx:** [@status](https://github.com/status) field annotation + [@allowed](https://github.com/allowed)States command annotation ([15f0478](https://github.com/ReventlessDev/reventless-core/commit/15f0478209dbb4e5d385332cf8cf320c694ac1c1))
* **spec:** allowedStates + statusField metadata for AutoUI command filtering ([b5d138b](https://github.com/ReventlessDev/reventless-core/commit/b5d138bb706515f7c6ba5daf7f4ef481cc35d024))


# 3.0.0-alpha.38 (2026-05-14)

### Features

* **auth:** expose payload-less commands to GraphQL + per-constructor authz test ([7a55b27](https://github.com/ReventlessDev/reventless-core/commit/7a55b27ea04e84368909b24fc5ca29f415d108da))
* **auth:** scaffold provider-agnostic auth abstraction ([a273c10](https://github.com/ReventlessDev/reventless-core/commit/a273c10d4598d9d2fdcc7428dde3278818aba9b8))
* **ppx:** inline-spec walk + Spec module types require authorization ([7db9ec0](https://github.com/ReventlessDev/reventless-core/commit/7db9ec0f186578ce0088973dba22da9257be6a61))


# 3.0.0-alpha.37 (2026-05-13)

* feat(spec)!: standardise event/command envelope (StoredEvent, optional meta, position, persisted DCB meta, causation) ([7ef3176](https://github.com/ReventlessDev/reventless-core/commit/7ef3176c6330810c817f43a52b881b5a0efee30e))

### BREAKING CHANGES

* meta.ip / meta.user go from required `string` to optional
record fields (`?: string`). Code that did `meta.user == "unknown"` to
detect system messages must check for field absence. Storage tables built
before this change are not migrated (greenfield — recreate the EventLog /
DcbEventLog tables; DynamoDB range key renamed from `seq` to `position`,
SQLite dcb_event gains meta and recorded_at columns).



# 3.0.0-alpha.36 (2026-05-05)

### Features

* **dcb:** allow plural *Ids field names with shared singular tag key ([19a5167](https://github.com/ReventlessDev/reventless-core/commit/19a5167ed904c6152c137af738f869ee4d26287e))


# 3.0.0-alpha.35 (2026-05-03)

* feat(codegen)!: drop View suffix from StateView slice file names ([476dd8c](https://github.com/ReventlessDev/reventless-core/commit/476dd8c8c91f67b198faaef51aa1b29d26099844))
* feat(ppx,codegen)!: retire @reventless.projections; add spec-stem-uniqueness lint ([a6fa11f](https://github.com/ReventlessDev/reventless-core/commit/a6fa11fa26086fd356e16b01b6f15b819630534e))
* refactor(examples)!: migrate online-shop-aggregates to new naming + adopt new PPX ([9dac635](https://github.com/ReventlessDev/reventless-core/commit/9dac6353b88e6c6bba88d1ce9d4a0594be976f62))
* feat(ppx)!: add @@reventless.mappings/extension/task; collapse AutomationSlice.Make to 2 args ([c0268ac](https://github.com/ReventlessDev/reventless-core/commit/c0268ac42c1c887fe25467af61b412ab2e27a5a7))
### Features

* **logger:** prefix plugin-component logs with stable-color [PluginName] bracket ([ed61eaf](https://github.com/ReventlessDev/reventless-core/commit/ed61eaf5cf84d8b8925c148050a2c51ddb65226a))

### BREAKING CHANGES

* any downstream consumers regenerating from EventModeling
JSON via reventless-codegen will see StateView slices' spec file rename
from <Title>View.res to <Title>.res (with the matching _Projection.res
sibling). Move existing files with `git mv` if the canonical model still
titles them "*View".
* any user code applying @reventless.projections to
an inline wrapper module inside Plugin.res fails to compile with a
clear migration message. Move the per-source Mapping.Make modules
and the let mappings array into the slice-local
<Plural>_Projections.res file (in ReadModel/) and add
@@reventless.mappings at the top. Auto-generated Plugin.res then
references the projections module directly.
* external code consuming the
`@reventlessdev/online-shop-aggregates-*` packages must update module name
references (e.g., `CategoriesReadModel` → `Categories`,
`ProductsExtensionPoint` → `Products_ExtensionPoint`, `CategoryBehavior` →
`Category_Behavior`).

Verified: zero warnings, 1174/1175 tests pass — same single pre-existing
testPromise race in OrderingE2ETest as PR1/PR2.
* Platform.AutomationSlice.Make is now 2-arg (Spec, Automation).
External callers must either rerun generate-plugin or merge their _Mappings
contents into _Automation (or add the same two-line bridge).

Verified: zero warnings, 1174/1175 tests pass — the single failing test
(OrderingE2ETest "after syncing missing product, PlaceOrder succeeds") was
confirmed pre-existing on alpha (the known testPromise concurrency race).



# 3.0.0-alpha.34 (2026-04-28)

### Features

* **ppx:** add [@drill](https://github.com/drill)Target and [@collapsed](https://github.com/collapsed) rendering hints ([9de6499](https://github.com/ReventlessDev/reventless-core/commit/9de6499a458a1a29f51f67df03b607bdb46c707c))
* **ppx:** add [@hidden](https://github.com/hidden) and [@summary](https://github.com/summary) visibility annotations ([f26b05c](https://github.com/ReventlessDev/reventless-core/commit/f26b05cd561f1a879ed74135a3446f1faf29ad21))
* **ppx:** add [@scan](https://github.com/scan) and [@scan](https://github.com/scan)Sort opt-in for server-side filter/sort ([534a4bf](https://github.com/ReventlessDev/reventless-core/commit/534a4bf2116ec6f597f87dadc785767c3dc54ace))
* **ppx:** propagate state annotations to JSON Schema as x-reventless-* properties ([5ce39e4](https://github.com/ReventlessDev/reventless-core/commit/5ce39e4d22dca7d5ae3577b6210e40dd81cef4f5))


# 3.0.0-alpha.33 (2026-04-27)

### Bug Fixes

* **spec:** regenerate plugins; simplify codegen, drop Maker suffix ([8d81302](https://github.com/ReventlessDev/reventless-core/commit/8d81302a9dc3403f98298ff69b19901d625dff7e))
### Features

* **codegen:** AWS Plugin.res delegates to composition variant; forward uiBundleUrl from env ([8832ab7](https://github.com/ReventlessDev/reventless-core/commit/8832ab7a3a19cd697afe14b230f122fc18f73403))


# 3.0.0-alpha.32 (2026-04-26)

* refactor(automation)!: drop tagSet and toTags from Mapping API ([c9cd7f2](https://github.com/ReventlessDev/reventless-core/commit/c9cd7f2a1c1758990cb3d83a6876348477fe89d6))
* feat!: mixed-source AutomationSlice — Plan 04 ([fae3fbf](https://github.com/ReventlessDev/reventless-core/commit/fae3fbf93b12ecf62d0883fe7335ed73c6f52d67))
### Features

* enable mixed-source ReadModel — Aggregate + DCB projections (Plan 03) ([2a5f9de](https://github.com/ReventlessDev/reventless-core/commit/2a5f9de1df23cac39fc292dbad23cf16ad0aece4))
* **ppx:** add @[@reventless](https://github.com/reventless).projection / .automation / .translation — Phase 3a of Spec-First series ([d193ae6](https://github.com/ReventlessDev/reventless-core/commit/d193ae64cff93aae2867182641489f17ce4e88d6))
* **spec:** split slice spec module types — Phase 1 of Spec-First series ([d3b1493](https://github.com/ReventlessDev/reventless-core/commit/d3b149300d09dbac45a5e316343cd79fe2a769e6))

### BREAKING CHANGES

* Mapping/MappingImpl no longer have `type tagSet`
or `let toTags`. Mappings declared in user code with `type tagSet`
or `let toTags` need those lines removed. Migrate any toTags
validation logic to `collect` (filter) or to `@s.matches` /
`@compositePartitionTag` annotations on the command schema.
* AutomationSlice.Spec drops consumedEvent;
AutomationSlice_Builder.Make takes Mappings as 3rd arg; make signature
swaps ~dcbEventLog for ~allEventTopics + ~context; Plugin_Builder.Spec
gains platformName. Existing slices need a sibling _Mappings.res file
and updated Plugin.res (regenerate via prebuild hook).

Tests: 362/362 pass. Build clean, zero warnings.

Plan: docs/plans/done/mixed-source-automationslice.md
Guide: docs/guides/mixed-source-automationslice.md



# 3.0.0-alpha.31 (2026-04-22)

### Bug Fixes

* **core:** correct plugin structure graph and dcb event publishing ([a61a9d0](https://github.com/ReventlessDev/reventless-core/commit/a61a9d024cffdf36faafc6bec8b8c04221ca3db2))
* wire DCB cross-plugin event routing and AutoUI command linking ([8baabad](https://github.com/ReventlessDev/reventless-core/commit/8baabad8bce02ab0954a0eeefffb4cf5f448e1e7))
### Features

* add [@ref](https://github.com/ref) ppx annotation for explicit cross-entity field references ([079c732](https://github.com/ReventlessDev/reventless-core/commit/079c732e81b481e9b2836ea755e1610b13f828fc))
* add composite [@display](https://github.com/display)Name annotation with projected displayName column ([115f550](https://github.com/ReventlessDev/reventless-core/commit/115f5506231f635e261d977da0ca32bdabef817f))
* **logs:** bold event and command names in log output ([3b09f41](https://github.com/ReventlessDev/reventless-core/commit/3b09f41299bc1f851e15cfb7b8c4a8433f499c7d))
* **spec:** add Message.variantNameOfJson helper ([a9efb5f](https://github.com/ReventlessDev/reventless-core/commit/a9efb5f1d3ac6180ea8e04dc3c1c2f183d15a984))
* **spec:** wire UI fragment manifest through plugin make via ~uiBundleUrl ([e07fa3a](https://github.com/ReventlessDev/reventless-core/commit/e07fa3a05d6effdd4c6c6686ab1f7e4e4312c438))
* surface labelField and searchableFields on Platform_UIReadSideDef ([fb7bff8](https://github.com/ReventlessDev/reventless-core/commit/fb7bff8f6fca51c2ed9261adbfedec0f45777d59))


# 3.0.0-alpha.30 (2026-04-20)

### Bug Fixes

* use run-generator.mjs wrapper so shebang survives rescript builds ([7f091d8](https://github.com/ReventlessDev/reventless-core/commit/7f091d8c6144bcd70fbc9d8e69288bc45a45ccd6))
### Features

* add automationSlices, translation slices, and extensions to pluginStructure ([631e2f3](https://github.com/ReventlessDev/reventless-core/commit/631e2f3636f0a422e58712f70106c0df8effc1e9))
* Platform_EventGraph StateViewSlice aggregating cross-plugin event graph ([718f0be](https://github.com/ReventlessDev/reventless-core/commit/718f0bed258da62c4ff5f2ab188e2d43b85e91b6))
* **plugin-structure:** add mutationField to commandDef ([80f2c8d](https://github.com/ReventlessDev/reventless-core/commit/80f2c8db6a61a705f8b05cb7429187a4b69ccf37))
* **reventless-spec:** add StateViewSliceStream, EventMappings, and Task support to AWS codegen variant ([22d6b4a](https://github.com/ReventlessDev/reventless-core/commit/22d6b4aa22a57740090fa78b8c055c798e88194f))


# 3.0.0-alpha.29 (2026-04-19)

**Note:** Version bump only for package @reventlessdev/reventless-spec





# 3.0.0-alpha.28 (2026-04-18)

### Features

* **core:** AutoUI definition — makeAutoUIDefinition, Platform_UIDefinitions query, generator support ([513ca53](https://github.com/ReventlessDev/reventless-core/commit/513ca5399b0b6e5ae6a982fd15693de2ea208b8d))
* **core:** uiFragments manifest — Phase 1 implementation with generic types ([1e73f62](https://github.com/ReventlessDev/reventless-core/commit/1e73f623984118081d2b985c48521812e4f8417e))


# 3.0.0-alpha.27 (2026-04-15)

### Bug Fixes

* **schema:** make pluginDefinition.apiTarget JSON-safe for union variant payloads ([556457f](https://github.com/ReventlessDev/reventless-core/commit/556457fd2f09f3ae572fc18aefb3262d80582524))


# 3.0.0-alpha.26 (2026-04-15)

### Bug Fixes

* **platform:** split-API schema routing for Platform-target plugins ([6b4c58d](https://github.com/ReventlessDev/reventless-core/commit/6b4c58dfed15c40db0e70339f0148ff445eb5c6a))


# 3.0.0-alpha.25 (2026-04-15)

### Features

* zero-touch plugin assembly — generate Plugin.res from folder structure ([73ea654](https://github.com/ReventlessDev/reventless-core/commit/73ea654ab9a73f15ea7e18631e8194bfe0f4580f))


# 3.0.0-alpha.24 (2026-04-12)

**Note:** Version bump only for package @reventlessdev/reventless-spec





# 3.0.0-alpha.23 (2026-04-07)

### Bug Fixes

* **dcb-validation:** handle union and object types in schemasAreCompatible ([8b13bb5](https://github.com/ReventlessDev/reventless-core/commit/8b13bb552cfa643f486c2761a441d1a2ae1cd7e0))


# 3.0.0-alpha.22 (2026-04-07)

### Features

* **ppx+querydb:** annotation-driven key design and sort key queries ([dee6de8](https://github.com/ReventlessDev/reventless-core/commit/dee6de84c2d2de5431d064f18ac7132bc8c23110))


# 3.0.0-alpha.21 (2026-04-07)

### Bug Fixes

* replace S.reverseConvertToJsonOrThrow with JSON.stringifyAny round-trip ([406acee](https://github.com/ReventlessDev/reventless-core/commit/406acee7bf98eb517419db23791b8ecb3668ada7))


# 3.0.0-alpha.20 (2026-04-06)

### Bug Fixes

* add package-specs to all rescript.json to prevent CJS .js output ([780f1e0](https://github.com/ReventlessDev/reventless-core/commit/780f1e035173b73b17b78466ad01fb69c7cca350))


# 3.0.0-alpha.19 (2026-04-06)

### Features

* implement [@composite](https://github.com/composite)PartitionTag PPX annotation for multi-field DCB partition keys ([cf26b15](https://github.com/ReventlessDev/reventless-core/commit/cf26b15f639d151451c9aa04d32603ef9d5df315))


# 3.0.0-alpha.18 (2026-04-04)

### Bug Fixes

* DCB [@partition](https://github.com/partition)Tag runtime errors, GraphQL Node interface, and ESM config ([dc4c4e1](https://github.com/ReventlessDev/reventless-core/commit/dc4c4e10f1ef09aba840e7b359df453b122c6aa4))
* feat!: add reventless-ppx with @@reventless.spec, @@reventless.behavior, @@reventless.dcbTags ([cb203ec](https://github.com/ReventlessDev/reventless-core/commit/cb203ece5ea3a1b92ba7d1a57d9e12bb6c4c2487))

### BREAKING CHANGES

* Example spec files no longer export manual moduleUrl/name/Id
declarations — these are now PPX-generated. Downstream code referencing these
exports is unaffected (same values, different source).



# 3.0.0-alpha.17 (2026-04-03)

* feat!: support multi-command returns in InboundTranslationSlice ([eaac621](https://github.com/ReventlessDev/reventless-core/commit/eaac6213829b876db508b6a98db081ee40dc3e95))

### BREAKING CHANGES

* All `translate` implementations must wrap returns in arrays.



# [3.0.0-alpha.16](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-spec@3.0.0-alpha.14...@reventlessdev/reventless-spec@3.0.0-alpha.16) (2026-03-28)

**Note:** Version bump only for package @reventlessdev/reventless-spec





# [3.0.0-alpha.15](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-spec@3.0.0-alpha.14...@reventlessdev/reventless-spec@3.0.0-alpha.15) (2026-03-27)

**Note:** Version bump only for package @reventlessdev/reventless-spec





# [3.0.0-alpha.14](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-spec@3.0.0-alpha.11...@reventlessdev/reventless-spec@3.0.0-alpha.14) (2026-03-27)

* feat!: remove resolverConfig from Behavior module type ([6f54015](https://github.com/ReventlessDev/reventless-core/commit/6f54015e3abc1c5c05472c8f54645723a0f5ed28))
* feat!: decouple DCB slices from shared event log union type ([2a40e8d](https://github.com/ReventlessDev/reventless-core/commit/2a40e8dd9babfb88440fcaccde6fb667b60e0ba9))
* feat!: add structured Identity type and expand RequestContext with identity and claims ([a2396d4](https://github.com/ReventlessDev/reventless-core/commit/a2396d4dd350bb07924d45b64b99b3dc969ced89))

### BREAKING CHANGES

* Behavior.T no longer requires resolverConfig. Remove it
from all Behavior implementations.
* All DCB slice specs must use `producedEvent`/`consumedEvent`
instead of `module DcbEventLogSpec`. Plugin `DcbSpec` no longer has `type event`
or `with type dcbEvent` constraints.
* RequestContext.t now requires identity and claims fields.
Use RequestContext.test() for test contexts.



# [3.0.0-alpha.13](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-spec@3.0.0-alpha.11...@reventlessdev/reventless-spec@3.0.0-alpha.13) (2026-03-26)

* feat!: add structured Identity type and expand RequestContext with identity and claims ([a2396d4](https://github.com/ReventlessDev/reventless-core/commit/a2396d4dd350bb07924d45b64b99b3dc969ced89))

### BREAKING CHANGES

* RequestContext.t now requires identity and claims fields.
Use RequestContext.test() for test contexts.



# [3.0.0-alpha.12](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-spec@3.0.0-alpha.11...@reventlessdev/reventless-spec@3.0.0-alpha.12) (2026-03-26)

* feat!: add structured Identity type and expand RequestContext with identity and claims ([a2396d4](https://github.com/ReventlessDev/reventless-core/commit/a2396d4dd350bb07924d45b64b99b3dc969ced89))

### BREAKING CHANGES

* RequestContext.t now requires identity and claims fields.
Use RequestContext.test() for test contexts.



# [3.0.0-alpha.11](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-spec@3.0.0-alpha.10...@reventlessdev/reventless-spec@3.0.0-alpha.11) (2026-03-23)

* refactor!: streamline component function naming to unified two-function pattern ([06814fd](https://github.com/ReventlessDev/reventless-core/commit/06814fd8589cf05ce8a9f9654552e7d5cd9c6bf2))
* fix(reventless-aws)!: resolve DcbEventLogSpec undefined at runtime and add AppSync routing ([85138a3](https://github.com/ReventlessDev/reventless-core/commit/85138a39afe97047ea5f063508994e20544eb780))

### BREAKING CHANGES

* All component function signatures changed. Behavior.decide
now returns result<array<event>, error> instead of using errorHandler callback.
StateChangeSlice type decisionModel renamed to state. Projection.Mapping.map
renamed to project. StateViewSlice.project takes one argument instead of two.

* DcbEventLog.Spec now requires `let moduleUrl: string` field.
Add `let moduleUrl: string = %raw(\`import.meta.url\`)` to event log modules.
# [3.0.0-alpha.10](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-spec@3.0.0-alpha.9...@reventlessdev/reventless-spec@3.0.0-alpha.10) (2026-03-22)

* feat(reventless-aws)!: replace esbuild pipeline with compiled ReScript entry points ([6cb3133](https://github.com/ReventlessDev/reventless-core/commit/6cb313323c73a078d0922fa6b977466f61de74ea))

### BREAKING CHANGES

* esbuild removed from dependencies, `makeBundled` and
`makeBundledFromEntryPoint` removed from RuntimeEnvironment_Lambda,
`BundledEnvironment` module type removed from Runtime.
# [3.0.0-alpha.9](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-spec@3.0.0-alpha.8...@reventlessdev/reventless-spec@3.0.0-alpha.9) (2026-03-16)

* feat!: auto-detect plugin version from package.json via V8 stack trace ([e172673](https://github.com/ReventlessDev/reventless-core/commit/e17267390c197fa34052cef8325c579bb781419f))
### Features

* read version from package.json, make cloner opt-in, log platform version ([d8216a1](https://github.com/ReventlessDev/reventless-core/commit/d8216a1d569064ca14eff6e0c3be86923e5b84ad))

### BREAKING CHANGES

* Plugin.make no longer accepts ~version.
# [3.0.0-alpha.8](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-spec@3.0.0-alpha.7...@reventlessdev/reventless-spec@3.0.0-alpha.8) (2026-03-12)

### Features

* **deps:** upgrade rescript to 12.2 and migrate Belt usages to stdlib ([eaa96ea](https://github.com/ReventlessDev/reventless-core/commit/eaa96ea61ca40d61573fb5fe2002a1f73d43ce3e))
# [3.0.0-alpha.7](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-spec@3.0.0-alpha.5...@reventlessdev/reventless-spec@3.0.0-alpha.7) (2026-03-08)

### Bug Fixes

* remove 26 Obj.magic usages, improve type safety across codebase ([ebb8925](https://github.com/ReventlessDev/reventless-core/commit/ebb8925b760a0f070b1aaf3ef2d4bf3fdc7282a3))
### Features

* add AutomationSlice component (TODO list pattern) ([4642688](https://github.com/ReventlessDev/reventless-core/commit/46426884727aff74db33b9289feca9878b0e3ed9))
* add TranslationSlice components with docs and webhook backlog plan ([7362a8f](https://github.com/ReventlessDev/reventless-core/commit/7362a8f26bca2eaad9d99488ec597c426635659d))
* migrate logging to Effect built-in logger and provide RequestContext ([e9ec682](https://github.com/ReventlessDev/reventless-core/commit/e9ec6822ea924fc1561bfd886e4232cb5e2a8250))
* replace explicit queryMode with automatic schema-driven DCB query construction ([8df4350](https://github.com/ReventlessDev/reventless-core/commit/8df4350c37f1f15678f4796f229647eaeb3e8222))
# [3.0.0-alpha.6](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-spec@3.0.0-alpha.5...@reventlessdev/reventless-spec@3.0.0-alpha.6) (2026-03-08)

### Bug Fixes

* remove 26 Obj.magic usages, improve type safety across codebase ([ebb8925](https://github.com/ReventlessDev/reventless-core/commit/ebb8925b760a0f070b1aaf3ef2d4bf3fdc7282a3))
### Features

* add AutomationSlice component (TODO list pattern) ([4642688](https://github.com/ReventlessDev/reventless-core/commit/46426884727aff74db33b9289feca9878b0e3ed9))
* add TranslationSlice components with docs and webhook backlog plan ([7362a8f](https://github.com/ReventlessDev/reventless-core/commit/7362a8f26bca2eaad9d99488ec597c426635659d))
* migrate logging to Effect built-in logger and provide RequestContext ([e9ec682](https://github.com/ReventlessDev/reventless-core/commit/e9ec6822ea924fc1561bfd886e4232cb5e2a8250))
# [3.0.0-alpha.5](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-spec@3.0.0-alpha.4...@reventlessdev/reventless-spec@3.0.0-alpha.5) (2026-03-03)

### Features

* **api:** implement Api component with GraphQL fragment generation and schema stitching ([c882d3a](https://github.com/ReventlessDev/reventless-core/commit/c882d3aae8722cf6cbe9b4fbf9518d9f434ce06a))
# [3.0.0-alpha.4](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-spec@3.0.0-alpha.3...@reventlessdev/reventless-spec@3.0.0-alpha.4) (2026-03-02)

**Note:** Version bump only for package @reventlessdev/reventless-spec

# [3.0.0-alpha.3](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-spec@3.0.0-alpha.2...@reventlessdev/reventless-spec@3.0.0-alpha.3) (2026-03-02)

**Note:** Version bump only for package @reventlessdev/reventless-spec

# [3.0.0-alpha.2](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-spec@3.0.0-alpha.1...@reventlessdev/reventless-spec@3.0.0-alpha.2) (2026-03-01)

* feat(reventless-spec)!: swap namespaces — spec→Reventless, core→ReventlessCore ([0fcf24e](https://github.com/ReventlessDev/reventless-core/commit/0fcf24e3fc1dcc88e9ee741dc99eb7bd726f9fd7))
### Features

* **rescript-effect:** Effect library bindings + stream-based framework handlers ([#30](https://github.com/ReventlessDev/reventless-core/issues/30)) ([f2ca5cf](https://github.com/ReventlessDev/reventless-core/commit/f2ca5cf3d56d66a9f4ab56b543d7bf82e48448dd))

### BREAKING CHANGES

* ReventlessSpec namespace renamed to Reventless; the reventless-core
package namespace renamed from Reventless to ReventlessCore.
All usages of ReventlessSpec.* must be updated to Reventless.*;
all usages of Reventless.* (core) in dependent packages must be updated to ReventlessCore.*
# [3.0.0-alpha.1](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-spec@3.0.0-alpha.0...@reventlessdev/reventless-spec@3.0.0-alpha.1) (2026-02-14)

**Note:** Version bump only for package @reventlessdev/reventless-spec

# [3.0.0-alpha.0](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-spec@2.3.1-alpha.2...@reventlessdev/reventless-spec@3.0.0-alpha.0) (2026-02-13)

* refactor!: remove AWS dependencies from reventless core package ([bc2c4af](https://github.com/ReventlessDev/reventless-core/commit/bc2c4aff85af4f83b9d131584845260b060db647))

### BREAKING CHANGES

* Builder functions now require explicit resourceNaming and runtimeOps parameters
## [2.3.1-alpha.2](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-spec@2.3.1-alpha.1...@reventlessdev/reventless-spec@2.3.1-alpha.2) (2026-02-12)

**Note:** Version bump only for package @reventlessdev/reventless-spec

## [2.3.1-alpha.1](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-spec@2.3.1-alpha.0...@reventlessdev/reventless-spec@2.3.1-alpha.1) (2026-02-12)

**Note:** Version bump only for package @reventlessdev/reventless-spec

## 2.3.1-alpha.0 (2026-02-12)
### Bug Fixes

* **publish:** add publishConfig to packages for GitHub Package Registry ([987a00a](https://github.com/ReventlessDev/reventless-core/commit/987a00af049fed112aa91fd53d8fad719cd80c94))
