[![npm](https://img.shields.io/npm/v/@reventlessdev/reventless-local.svg?label=npm)](https://www.npmjs.com/package/@reventlessdev/reventless-local)
[![License: Apache-2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)
[![Docs](https://img.shields.io/badge/docs-reventless.dev-blue)](https://docs.reventless.dev)

# @reventlessdev/reventless-local

> ⚠️ **Alpha.** APIs and on-disk formats can change without notice between releases.
> Pin exact versions and expect breaking changes.

The **local platform** for [Reventless](https://docs.reventless.dev) — a
spec-driven, event-sourced CQRS framework written in [ReScript](https://rescript-lang.org).
It implements the same platform interface as the cloud adapters, backed by
in-memory or SQLite data structures, so you can run and test your domain end to
end on a laptop — with no AWS and no cloud provisioning.

## What it provides

ReScript modules, consumed by adding the package to your `rescript.json` `dependencies`:

- **`Platform`** — the local platform functor (`Platform.Make()` /
  `Platform.MakeWithConfig({...})`) implementing `ReventlessInfra.Platform.T`.
  It activates Pulumi mock mode automatically and starts a Domain GraphQL server
  (and, in split mode, a Platform GraphQL server) plus MCP servers.
- **`Backend`** — selects the storage backend: `Backend.Memory` (default) or
  `Backend.Sqlite({...})` for file-backed persistence.
- **Component builders** (`Aggregate_Builder`, `ReadModel_Builder`, `Plugin_Builder`,
  the slice builders, `Task_Builder`, `Counter_Builder`, …) — local versions of
  the core hierarchical components.
- **Adapters** (`src/adapter/`) — in-memory and SQLite implementations of each
  core adapter: `EventLog`, `DcbEventLog`, `QueryDb`, `CommandTopic`, `EventTopic`,
  `EventCollector`, `Counter`, `Scheduler`, `Task`, plus a local bus, query
  engine, GraphQL/MCP server adapters, and auth/user store.
- **`TestRunner`** — helpers for running a local platform inside a test suite
  (start/stop the GraphQL server), with Given-When-Then integration via
  [`reventless-gwt`](https://www.npmjs.com/package/@reventlessdev/reventless-gwt).

## Where it fits

`reventless-local` is the local-development/testing **platform** for the Reventless
framework. [`reventless-core`](https://www.npmjs.com/package/@reventlessdev/reventless-core)
is provider-agnostic; you pair it with exactly one platform adapter, and this is
the one for running without a cloud:

- [`@reventlessdev/reventless-aws`](https://www.npmjs.com/package/@reventlessdev/reventless-aws) — AWS (DynamoDB, Lambda, SQS, SNS, S3)
- [`@reventlessdev/reventless-postgres`](https://www.npmjs.com/package/@reventlessdev/reventless-postgres) — Postgres event log + query DB
- [`@reventlessdev/reventless-local`](https://www.npmjs.com/package/@reventlessdev/reventless-local) — **this package** (in-memory / SQLite)

The same domain components run unchanged on the local platform and on a cloud
adapter, so `reventless-local` is where you iterate and test before deploying. It
reuses [`reventless-postgres`](https://www.npmjs.com/package/@reventlessdev/reventless-postgres)
storage when you point it at a local Postgres.

## Install

```bash
pnpm add @reventlessdev/reventless-local
```

Then register it as a ReScript dependency in `rescript.json`:

```json
{
  "dependencies": ["@reventlessdev/reventless-local"]
}
```

Requires ReScript `^12.3.0` (peer dependency).

## Links

- 📚 Documentation — [docs.reventless.dev](https://docs.reventless.dev)
- 📦 Repository — [ReventlessDev/reventless-core](https://github.com/ReventlessDev/reventless-core)
- 📋 [Changelog](./CHANGELOG.md)

## License

[Apache-2.0](https://opensource.org/licenses/Apache-2.0)
