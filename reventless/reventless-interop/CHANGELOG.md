# Change Log

All notable changes to this project will be documented in this file.
See [Conventional Commits](https://conventionalcommits.org) for commit guidelines.

# 3.0.0-alpha.24 (2026-07-06)

### Features

* **reventless-aws:** classic EventLog Postgres deploy-time wiring + relay (B1 vertical) ([8235ba4](https://github.com/ReventlessDev/reventless-core/commit/8235ba44e506f7094d17251405c6a05c39789805))


# 3.0.0-alpha.23 (2026-07-03)

### Bug Fixes

* **interop:** make Resource.resourceInfo StorageKeys serializable (js_nullable sortKey) (plan C4) ([167745a](https://github.com/ReventlessDev/reventless-core/commit/167745ad76865d6b01053dac106aafd85c44ac64))


# 3.0.0-alpha.22 (2026-07-02)

### Bug Fixes

* **spec,interop,layer-builder:** generator/protocol/build failure modes (plan A8,A9) ([66d7a54](https://github.com/ReventlessDev/reventless-core/commit/66d7a54e3a0afdbfe3ea2975f517d1d64d52c180))


# 3.0.0-alpha.21 (2026-06-27)

**Note:** Version bump only for package @reventlessdev/reventless-interop





# 3.0.0-alpha.20 (2026-06-20)

**Note:** Version bump only for package @reventlessdev/reventless-interop





# 3.0.0-alpha.19 (2026-06-18)

**Note:** Version bump only for package @reventlessdev/reventless-interop





# 3.0.0-alpha.18 (2026-06-17)

### Bug Fixes

* **packaging:** executable ppx binaries + promote phantom deps for standalone installs ([9b6bea2](https://github.com/ReventlessDev/reventless-core/commit/9b6bea24570b0b0654c825d560ef781c0295512a))


# 3.0.0-alpha.17 (2026-06-12)

**Note:** Version bump only for package @reventlessdev/reventless-interop





# 3.0.0-alpha.16 (2026-06-10)

**Note:** Version bump only for package @reventlessdev/reventless-interop





# 3.0.0-alpha.15 (2026-06-06)

**Note:** Version bump only for package @reventlessdev/reventless-interop





# 3.0.0-alpha.14 (2026-06-04)

**Note:** Version bump only for package @reventlessdev/reventless-interop





# 3.0.0-alpha.13 (2026-05-25)

**Note:** Version bump only for package @reventlessdev/reventless-interop





# 3.0.0-alpha.12 (2026-05-25)

**Note:** Version bump only for package @reventlessdev/reventless-interop





# 3.0.0-alpha.11 (2026-05-17)

### Bug Fixes

* **deps:** pin sury-ppx to 11.0.0-alpha.2 to prevent prerelease drift ([c9d05fe](https://github.com/ReventlessDev/reventless-core/commit/c9d05fe5118a9c0442ca3e071f2606b3a139fc81))


# 3.0.0-alpha.10 (2026-05-17)

### Bug Fixes

* **deps:** pin sury to 11.0.0-alpha.4 to unblock Lambda Layer deploys ([643d925](https://github.com/ReventlessDev/reventless-core/commit/643d92527fa9d092da9bef8547591e39a4c609dd))


# 3.0.0-alpha.9 (2026-04-22)

### Features

* **build:** migrate from npm to pnpm (hoisted layout) ([1de8b77](https://github.com/ReventlessDev/reventless-core/commit/1de8b7753b8f45c63ea3c8d9f64de2f27febd029))


# 3.0.0-alpha.8 (2026-04-13)

### Dependency Updates

* **@reventlessdev/rescript-pulumi-pulumi** updated to `^2.3.0-alpha.7`


# 3.0.0-alpha.7 (2026-04-06)

### Bug Fixes

* add package-specs to all rescript.json to prevent CJS .js output ([780f1e0](https://github.com/ReventlessDev/reventless-core/commit/780f1e035173b73b17b78466ad01fb69c7cca350))


# 3.0.0-alpha.6 (2026-04-04)

* feat!: add reventless-ppx with @@reventless.spec, @@reventless.behavior, @@reventless.dcbTags ([cb203ec](https://github.com/ReventlessDev/reventless-core/commit/cb203ece5ea3a1b92ba7d1a57d9e12bb6c4c2487))

### BREAKING CHANGES

* Example spec files no longer export manual moduleUrl/name/Id
declarations — these are now PPX-generated. Downstream code referencing these
exports is unaffected (same values, different source).



# 3.0.0-alpha.5 (2026-04-02)

### Features

* add tags field to resource and resolvedResource records ([18911e6](https://github.com/ReventlessDev/reventless-core/commit/18911e66aa94e60d4a9b72ba1d1ca84dd3fb1a9f))


# 3.0.0-alpha.4 (2026-04-02)

* feat!: add deploy lifecycle hooks, enrich resource metadata, and add Adapter.make factory ([0a171f4](https://github.com/ReventlessDev/reventless-core/commit/0a171f4b8aec0ee47fd7ee5069adf5d5b194548e))

### BREAKING CHANGES

* Adapter.resource.info replaced with resourceInfo variant type.
Service field values now prefixed with provider namespace (e.g. "aws:DynamoDb").
New required fields on resource/resolvedResource: role, region, resourceType, configuration.



# [3.0.0-alpha.3](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-interop@1.0.0-alpha.5...@reventlessdev/reventless-interop@3.0.0-alpha.3) (2026-03-27)

**Note:** Version bump only for package @reventlessdev/reventless-interop





# [3.0.0-alpha.2](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-interop@1.0.0-alpha.5...@reventlessdev/reventless-interop@3.0.0-alpha.2) (2026-03-26)

**Note:** Version bump only for package @reventlessdev/reventless-interop





# [1.0.0-alpha.6](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-interop@1.0.0-alpha.5...@reventlessdev/reventless-interop@1.0.0-alpha.6) (2026-03-26)

**Note:** Version bump only for package @reventlessdev/reventless-interop





# [1.0.0-alpha.5](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-interop@1.0.0-alpha.4...@reventlessdev/reventless-interop@1.0.0-alpha.5) (2026-03-20)

### Features

* **aws:** replace CallbackFunction with bundled Lambda handlers ([6f6200b](https://github.com/ReventlessDev/reventless-core/commit/6f6200b0796e5f414493f50fd2f13dd6c7871ef4))
* **interop:** add component-level resolved output types and export plugin outputs from deployPlugin ([b502cbf](https://github.com/ReventlessDev/reventless-core/commit/b502cbf189f024f8bb3fd19a75bf5d76c7de2236))
# [1.0.0-alpha.4](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-interop@1.0.0-alpha.3...@reventlessdev/reventless-interop@1.0.0-alpha.4) (2026-03-17)

### Features

* **reventless-aws:** implement per-plugin deployment with runtime schema stitching ([f16714c](https://github.com/ReventlessDev/reventless-core/commit/f16714c5d2b3ad869863ac30dc55ef3e1570bf4f))
# [1.0.0-alpha.3](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-interop@1.0.0-alpha.2...@reventlessdev/reventless-interop@1.0.0-alpha.3) (2026-03-12)

### Features

* **deps:** upgrade rescript to 12.2 and migrate Belt usages to stdlib ([eaa96ea](https://github.com/ReventlessDev/reventless-core/commit/eaa96ea61ca40d61573fb5fe2002a1f73d43ce3e))
# [1.0.0-alpha.2](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-interop@1.0.0-alpha.1...@reventlessdev/reventless-interop@1.0.0-alpha.2) (2026-03-08)

**Note:** Version bump only for package @reventlessdev/reventless-interop

# [1.0.0-alpha.1](https://github.com/ReventlessDev/reventless-core/compare/@reventlessdev/reventless-interop@1.0.0-alpha.0...@reventlessdev/reventless-interop@1.0.0-alpha.1) (2026-03-02)

**Note:** Version bump only for package @reventlessdev/reventless-interop

# 1.0.0-alpha.0 (2026-03-01)

* feat(reventless-spec)!: swap namespaces — spec→Reventless, core→ReventlessCore ([0fcf24e](https://github.com/ReventlessDev/reventless-core/commit/0fcf24e3fc1dcc88e9ee741dc99eb7bd726f9fd7))

### BREAKING CHANGES

* ReventlessSpec namespace renamed to Reventless; the reventless-core
package namespace renamed from Reventless to ReventlessCore.
All usages of ReventlessSpec.* must be updated to Reventless.*;
all usages of Reventless.* (core) in dependent packages must be updated to ReventlessCore.*
