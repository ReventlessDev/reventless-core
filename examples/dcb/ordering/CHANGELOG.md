# Change Log

All notable changes to this project will be documented in this file.
See [Conventional Commits](https://conventionalcommits.org) for commit guidelines.

# 1.0.0-alpha.1 (2026-03-01)

* feat(reventless-spec)!: swap namespaces — spec→Reventless, core→ReventlessCore ([0fcf24e](https://github.com/ReventlessDev/reventless-core/commit/0fcf24e3fc1dcc88e9ee741dc99eb7bd726f9fd7))
### Features

* **examples:** add DCB-based online shop example with catalog and ordering packages ([45a8159](https://github.com/ReventlessDev/reventless-core/commit/45a8159a6365d8c9ea2665cb58eaf8ee90c3f11d))
* **rescript-effect:** Effect library bindings + stream-based framework handlers ([#30](https://github.com/ReventlessDev/reventless-core/issues/30)) ([f2ca5cf](https://github.com/ReventlessDev/reventless-core/commit/f2ca5cf3d56d66a9f4ab56b543d7bf82e48448dd))

### BREAKING CHANGES

* ReventlessSpec namespace renamed to Reventless; the reventless-core
package namespace renamed from Reventless to ReventlessCore.
All usages of ReventlessSpec.* must be updated to Reventless.*;
all usages of Reventless.* (core) in dependent packages must be updated to ReventlessCore.*

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
