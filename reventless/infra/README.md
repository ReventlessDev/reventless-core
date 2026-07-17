[![npm](https://img.shields.io/npm/v/@reventlessdev/reventless-infra.svg?label=npm)](https://www.npmjs.com/package/@reventlessdev/reventless-infra)
[![License: Apache-2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)
[![Docs](https://img.shields.io/badge/docs-reventless.dev-blue)](https://docs.reventless.dev)

# @reventlessdev/reventless-infra

> ⚠️ **Alpha.** APIs and on-disk formats can change without notice between releases.
> Pin exact versions and expect breaking changes.

The **infrastructure type layer** of [Reventless](https://docs.reventless.dev) — a
spec-driven, event-sourced CQRS framework written in [ReScript](https://rescript-lang.org).
This package defines the deploy-time infrastructure types and abstract `Platform` interface
that are shared across storage/cloud adapters, so plugin-assembly code can be written once
against provider-agnostic types and satisfied by any concrete adapter. It uses
[Pulumi](https://www.pulumi.com) types for deploy-time resource references. Modules are
exposed under the `ReventlessInfra` namespace.

## What it provides

ReScript modules, consumed by adding the package to your `rescript.json` `dependencies`.

**Platform interface & adapters (`types/`, `adapter/`)**

- **`Platform`** — the abstract factory interface for platform-agnostic component assembly.
  Plugin code takes a `Platform.T` as a functor argument; a concrete adapter (e.g.
  `reventless-aws`) supplies the implementation at the composition root.
- **`Adapter`** — deploy-time infrastructure primitives: `resource` (fields wrapped in
  `Pulumi.Output.t`), `resolvedResource` (runtime values), and `resourceInfo` describing a
  resource's structural role (storage keys, stream source, API resolver).
- **`ResourceNaming`** — provider-agnostic operations for validating and deriving
  URN-safe resource names.
- **`ExtensionMapping`** / **`ExtensionPointMapping`** — the action types that route commands
  and events between an extension and the extension point it wraps.
- **`Message`**, **`PluginExtensionPointSpec`**, **`NoEventMappings`** — supporting types for
  message identity and plugin/extension wiring.

**Component types (`components/`)**

Deploy-time `outputs` (infrastructure references) and runtime `operations` for each Reventless
component kind — **`Component`** (the typed wrapper around a Pulumi `ComponentResource`),
**`Plugin`**, **`Aggregate`**, **`ReadModel`**, **`EventLog`** / **`DcbEventLog`**,
**`CommandTopic`** / **`EventTopic`**, **`CommandGenerator`**, **`EventCollector`**,
**`EventMapper`**, **`QueryDb`**, **`Api`**, **`Task`**, **`ExtensionPoint`** / **`Extension`**,
**`Scheduler`**, **`Heartbeat`**, and the DCB slices.

## Where it fits

`reventless-infra` sits between the specification layer and the concrete adapters:

```
reventless-spec (specifications)
  ↓
reventless-infra (shared infrastructure types)  ← this package
  ↓
reventless-aws / reventless-postgres / reventless-local (storage & deployment adapters)
```

- It builds on
  [`@reventlessdev/reventless-spec`](https://www.npmjs.com/package/@reventlessdev/reventless-spec)
  for the domain contracts.
- Adapters such as
  [`@reventlessdev/reventless-aws`](https://www.npmjs.com/package/@reventlessdev/reventless-aws)
  provide the concrete `Platform.T` implementation these types describe.

You normally obtain `reventless-infra` transitively by scaffolding an app rather than
installing it on its own.

## Install

```bash
pnpm add @reventlessdev/reventless-infra
```

Then register it as a ReScript dependency in `rescript.json`:

```json
{
  "dependencies": ["@reventlessdev/reventless-infra"]
}
```

Requires ReScript `^12.3.0` (peer dependency).

## Links

- 📚 Documentation — [docs.reventless.dev](https://docs.reventless.dev)
- 📦 Repository — [ReventlessDev/reventless-core](https://github.com/ReventlessDev/reventless-core)
- 📋 [Changelog](./CHANGELOG.md)

## License

[Apache-2.0](https://opensource.org/licenses/Apache-2.0)
