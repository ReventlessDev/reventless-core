[![npm](https://img.shields.io/npm/v/@reventlessdev/rescript-graphql-yoga.svg?label=npm)](https://www.npmjs.com/package/@reventlessdev/rescript-graphql-yoga)
[![License: Apache-2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)
[![Docs](https://img.shields.io/badge/docs-reventless.dev-blue)](https://docs.reventless.dev)

# @reventlessdev/rescript-graphql-yoga

> ⚠️ **Alpha.** APIs can change without notice between releases.
> Pin exact versions and expect breaking changes.

ReScript bindings for [graphql-yoga](https://the-guild.dev/graphql/yoga-server), used across the [Reventless](https://docs.reventless.dev) framework. It binds `graphql-yoga` `^5.21.0` (bundled dependency), alongside `graphql` `^16`, `graphql-ws`, and `ws`.

## Install

```bash
pnpm add @reventlessdev/rescript-graphql-yoga
```

Then register it as a ReScript dependency in `rescript.json`:

```json
{
  "dependencies": ["@reventlessdev/rescript-graphql-yoga"]
}
```

Requires ReScript `^12.3.0` (peer dependency).

## Usage

The bindings are exposed as the `GraphqlYoga` ReScript module.

## Links

- 📚 Documentation — [docs.reventless.dev](https://docs.reventless.dev)
- 📦 Repository — [ReventlessDev/reventless-core](https://github.com/ReventlessDev/reventless-core)
- 📋 [Changelog](./CHANGELOG.md)
- 🔗 Upstream — [graphql-yoga](https://the-guild.dev/graphql/yoga-server)

## License

[Apache-2.0](https://opensource.org/licenses/Apache-2.0)
