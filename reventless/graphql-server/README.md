[![npm](https://img.shields.io/npm/v/@reventlessdev/reventless-graphql-server.svg?label=npm)](https://www.npmjs.com/package/@reventlessdev/reventless-graphql-server)
[![License: Apache-2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)
[![Docs](https://img.shields.io/badge/docs-reventless.dev-blue)](https://docs.reventless.dev)

# @reventlessdev/reventless-graphql-server

> ⚠️ **Alpha.** APIs and on-disk formats can change without notice between releases.
> Pin exact versions and expect breaking changes.

A **transport-neutral GraphQL server runtime** shared across
[Reventless](https://docs.reventless.dev) — a spec-driven, event-sourced CQRS
framework written in [ReScript](https://rescript-lang.org). It stands up
[Yoga](https://the-guild.dev/graphql/yoga-server)-backed GraphQL servers from
stitched SDL fragments plus a resolver map, with an optional `graphql-ws`
WebSocket endpoint and a subscription fan-out bridge over a pluggable PubSub
backend.

## What it provides

Two ReScript modules:

- **`GraphQL_ServerInstance`** — a server-instance factory. Each instance keeps an
  isolated registry, so a backend can stand up one or more independent servers
  from SDL fragments + a resolver dict, exposed over HTTP with an optional
  `graphql-ws` WebSocket transport for subscriptions. Includes registry
  diagnostics (registered type/field/resolver inventories and SDL-vs-resolver
  mismatch reporting).
- **`GraphQL_SubscriptionBridge`** — transport-neutral wiring between a server
  instance and a PubSub backend for `graphql-ws` fan-out. The topic vocabulary is
  fixed to core's generated subscription SDL (raw event-stream and state-changed
  fields), but the PubSub instance is a *parameter*: an in-process server passes
  `createPubSub()`, a multi-process gateway passes a cross-process implementation
  of the same interface.

## Where it fits

`reventless-graphql-server` builds on
[`@reventlessdev/reventless-core`](https://www.npmjs.com/package/@reventlessdev/reventless-core)
(for the subscription-schema topic vocabulary and logging) and the framework's
`graphql-yoga` bindings. It is the reusable serving layer that storage/deployment
adapters and local platforms wire their generated schema and resolvers into; it
holds no domain or storage logic of its own.

## Install

```bash
pnpm add @reventlessdev/reventless-graphql-server
```

Register it as a ReScript dependency in `rescript.json`:

```json
{
  "dependencies": ["@reventlessdev/reventless-graphql-server"]
}
```

Requires ReScript `^12.3.0` (peer dependency).

## Links

- 📚 Documentation — [docs.reventless.dev](https://docs.reventless.dev)
- 📦 Repository — [ReventlessDev/reventless-core](https://github.com/ReventlessDev/reventless-core)
- 📋 [Changelog](./CHANGELOG.md)

## License

[Apache-2.0](https://opensource.org/licenses/Apache-2.0)
