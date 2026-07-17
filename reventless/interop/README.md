[![npm](https://img.shields.io/npm/v/@reventlessdev/reventless-interop.svg?label=npm)](https://www.npmjs.com/package/@reventlessdev/reventless-interop)
[![License: Apache-2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)
[![Docs](https://img.shields.io/badge/docs-reventless.dev-blue)](https://docs.reventless.dev)

# @reventlessdev/reventless-interop

> ⚠️ **Alpha.** APIs and on-disk formats can change without notice between releases.
> Pin exact versions and expect breaking changes.

The **cross-plugin interoperability layer** of [Reventless](https://docs.reventless.dev) — a
spec-driven, event-sourced CQRS framework written in [ReScript](https://rescript-lang.org).
This package defines the versioned contract types that plugins exchange across stack
boundaries and the compatibility validation that guards those contracts, so independently
deployed plugins can wire together without silently drifting apart. Modules are exposed under
the `ReventlessInterop` namespace.

## What it provides

ReScript modules, consumed by adding the package to your `rescript.json` `dependencies`.

**Protocol compatibility**

- **`Compat`** — validates that an extension's declared protocol versions are compatible with
  the host extension point's, producing typed `protocolError` variants (incompatible command
  schema, incompatible event schema, malformed version).
- **`ExtensionPointProtocol`** — the SemVer-based schema-version declarations (`commandVersion`,
  `eventVersion`) an extension point carries, plus the compatibility rule and version policy
  (MINOR bump on additive changes, MAJOR on removals/renames).
- **`CompatMatrix`** — the authoritative host-side protocol versions for the built-in
  extension points, compared against incoming plugin handshakes.

**Cross-stack export contracts**

- **`ExportMeta`** — the metadata (interop version + per-export field manifest) written
  alongside every plugin stack's named outputs, enabling forward/backward-compatible reads.
- **`Query`** / **`Projection`** — functors for querying remote stack dependencies: declare
  the fields a projection needs from a remote stack's manifest and decode the raw export JSON
  only after field validation passes.
- **`Resource`** — the `Output.t`-free, JSON-safe counterpart of an adapter `resource`, as it
  appears in serialized stack exports.
- **`components/`** — `resolvedOutputs` types (the JSON-safe cross-stack shapes) for each
  component kind: `Plugin`, `Aggregate`, `ReadModel`, `EventLog` / `DcbEventLog`,
  `CommandTopic`, `EventTopic`, `EventMapper`, `QueryDb`, `ExtensionPoint`, `Task`, and the
  DCB slices.

## Where it fits

`reventless-interop` is a framework-level package that plugins use to talk to one another
across deployment boundaries:

```
reventless-spec (specifications)
  ↓
reventless-core (provider-agnostic framework)  +  reventless-interop (cross-plugin contracts)  ← this package
  ↓
reventless-aws / reventless-postgres / reventless-local (storage & deployment adapters)
```

It pairs with
[`@reventlessdev/reventless-core`](https://www.npmjs.com/package/@reventlessdev/reventless-core)
and the storage/cloud adapters (`reventless-aws`, `reventless-postgres`, `reventless-local`),
adding the version negotiation and stack-export contracts that let separately deployed plugins
interoperate safely.

You normally obtain `reventless-interop` transitively by scaffolding an app rather than
installing it on its own.

## Install

```bash
pnpm add @reventlessdev/reventless-interop
```

Then register it as a ReScript dependency in `rescript.json`:

```json
{
  "dependencies": ["@reventlessdev/reventless-interop"]
}
```

Requires ReScript `^12.3.0` (peer dependency).

## Links

- 📚 Documentation — [docs.reventless.dev](https://docs.reventless.dev)
- 📦 Repository — [ReventlessDev/reventless-core](https://github.com/ReventlessDev/reventless-core)
- 📋 [Changelog](./CHANGELOG.md)

## License

[Apache-2.0](https://opensource.org/licenses/Apache-2.0)
