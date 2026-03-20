# Change Log

All notable changes to this project will be documented in this file.
See [Conventional Commits](https://conventionalcommits.org) for commit guidelines.

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

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
