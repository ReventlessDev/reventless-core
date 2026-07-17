[![npm](https://img.shields.io/npm/v/@reventlessdev/rescript-effect.svg?label=npm)](https://www.npmjs.com/package/@reventlessdev/rescript-effect)
[![License: Apache-2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)
[![Docs](https://img.shields.io/badge/docs-reventless.dev-blue)](https://docs.reventless.dev)

# @reventlessdev/rescript-effect

> ⚠️ **Alpha.** APIs can change without notice between releases.
> Pin exact versions and expect breaking changes.

ReScript bindings for [Effect](https://effect.website), used across the [Reventless](https://docs.reventless.dev) framework. It binds the `effect` library, pinned to version `3.21.2` (bundled dependency).

## Install

```bash
pnpm add @reventlessdev/rescript-effect
```

Then register it as a ReScript dependency in `rescript.json`:

```json
{
  "dependencies": ["@reventlessdev/rescript-effect"]
}
```

Requires ReScript `^12.3.0` (peer dependency).

## Usage

The bindings are exposed as ReScript modules mirroring the Effect surface, including `Effect`, `Stream`, `Layer`, `Context`, `Fiber`, `Ref`, `Queue`, `PubSub`, `Schedule`, `Stm`, `Duration`, `Cause`, `Exit`, `Deferred`, and testing helpers such as `TestClock` and `TestContext`.

## Links

- 📚 Documentation — [docs.reventless.dev](https://docs.reventless.dev)
- 📦 Repository — [ReventlessDev/reventless-core](https://github.com/ReventlessDev/reventless-core)
- 📋 [Changelog](./CHANGELOG.md)
- 🔗 Upstream — [Effect](https://effect.website) ([`effect` on npm](https://www.npmjs.com/package/effect))

## License

[Apache-2.0](https://opensource.org/licenses/Apache-2.0)
