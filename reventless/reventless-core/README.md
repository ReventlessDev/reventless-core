[![npm](https://img.shields.io/npm/v/@reventlessdev/reventless-core.svg?label=npm)](https://www.npmjs.com/package/@reventlessdev/reventless-core)
[![License: Apache-2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)
[![Docs](https://img.shields.io/badge/docs-reventless.dev-blue)](https://docs.reventless.dev)

# @reventlessdev/reventless-core

> ⚠️ **Alpha.** APIs and on-disk formats can change without notice between releases.
> Pin exact versions and expect breaking changes.

The **provider-agnostic core** of [Reventless](https://docs.reventless.dev) — a
spec-driven, event-sourced CQRS framework written in [ReScript](https://rescript-lang.org).
This package is the runtime you model your domain against: the type-safe building blocks
for commands, events, projections, and the behaviors that evolve state — with **no** cloud
or storage dependency. The provider-specific adapters live in separate packages
(see [Where it fits](#where-it-fits)).

## What it provides

ReScript modules, consumed by adding the package to your `rescript.json` `dependencies`:

- **`Message`** — command / event message contracts and their service interface.
- **`Behavior`** — the write-side behavior spec: event-sourced state transitions
  (`evolve(state, event) => state`).
- **`Projection`** / **`ProjectionMapper`** — read models projected from event streams.
- **`Mapper`** / **`Mapper1toN`** / **`MapperNto1`** — cross-component event translation
  (encode/decode between a source and a target contract).
- **`ComponentType`** — the hierarchical component-kind vocabulary.
- **`PluginRuntimeOperations`** — the provider-agnostic interface a runtime adapter implements.
- **`RequestContext`** — per-invocation context threaded through the effect pipeline.
- **`Env`** — environment access.

Domain code written against these modules is provider-agnostic: the same components run
unchanged on any adapter.

## Where it fits

`reventless-core` is one package in the Reventless framework. It builds on
[`@reventlessdev/reventless-spec`](https://www.npmjs.com/package/@reventlessdev/reventless-spec)
(type specifications) and is paired at runtime with a storage/cloud adapter:

- [`@reventlessdev/reventless-aws`](https://www.npmjs.com/package/@reventlessdev/reventless-aws) — AWS (DynamoDB, Lambda, SQS, SNS, S3)
- [`@reventlessdev/reventless-postgres`](https://www.npmjs.com/package/@reventlessdev/reventless-postgres) — Postgres event log + query DB
- [`@reventlessdev/reventless-local`](https://www.npmjs.com/package/@reventlessdev/reventless-local) — in-memory / SQLite platform for local dev and tests

You normally obtain `reventless-core` transitively by scaffolding an app rather than
installing it on its own.

## Install

```bash
pnpm add @reventlessdev/reventless-core
```

Then register it as a ReScript dependency in `rescript.json`:

```json
{
  "dependencies": ["@reventlessdev/reventless-core"]
}
```

Requires ReScript `^12.3.0` (peer dependency).

## Links

- 📚 Documentation — [docs.reventless.dev](https://docs.reventless.dev)
- 📦 Repository — [ReventlessDev/reventless-core](https://github.com/ReventlessDev/reventless-core)
- 📋 [Changelog](./CHANGELOG.md)

## License

[Apache-2.0](https://opensource.org/licenses/Apache-2.0)
