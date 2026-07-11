[![npm](https://img.shields.io/npm/v/@reventlessdev/reventless-domain-protocol.svg?label=npm)](https://www.npmjs.com/package/@reventlessdev/reventless-domain-protocol)
[![License: Apache-2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)
[![Docs](https://img.shields.io/badge/docs-reventless.dev-blue)](https://docs.reventless.dev)

# @reventlessdev/reventless-domain-protocol

> ⚠️ **Alpha.** APIs and on-disk formats can change without notice between releases.
> Pin exact versions and expect breaking changes.

The **shared graph/domain wire contract** for [Reventless](https://docs.reventless.dev) —
a spec-driven, event-sourced CQRS framework written in
[ReScript](https://rescript-lang.org). It defines the NDJSON `StreamEvent`
protocol that the [`reventless-gwt`](https://www.npmjs.com/package/@reventlessdev/reventless-gwt)
CLI (`--format=vscode`) emits and that the VS Code extension and other graph
surfaces decode — a single [sury](https://github.com/DZakh/sury) `@schema` both
sides use, so a `protocolVersion` bump touches one definition instead of drifting
across hand-written declarations on either end.

## What it provides

The **`Protocol`** module (also emitted as `ReventlessDomainProtocol` /
generated `.gen.ts` for TypeScript consumers):

- **`StreamEvent`** — the tagged NDJSON line union the CLI streams: test-run
  lifecycle events plus domain-analysis payloads (component inventory, domain
  graph, dead-code report).
- **Typed kind vocabularies** — `componentKind`, `edgeKind`, and item kinds as
  `@unboxed` variants with `Other*(string)` catch-alls, so a kind from a newer
  emitter decodes into a visible typed case instead of failing the whole event
  (version-skew tolerance).
- **`toJsonLine`** (serialize) and **`parseStreamEvent`** (parse + validate) — the
  encode/decode pair both ends share.

The schema is compiled to CommonJS so a CJS consumer (the extension) uses it
natively and the ESM CLI imports it.

## Where it fits

This package is a leaf contract: it depends only on `sury` and the ReScript
runtime — no framework runtime, no storage adapter. The
[`reventless-gwt`](https://www.npmjs.com/package/@reventlessdev/reventless-gwt)
CLI depends on it to emit its `vscode` NDJSON stream; editor and graph tooling
depend on it to decode that stream. Keeping the codec in one package is what lets
producer and consumer evolve in lockstep.

## Install

```bash
pnpm add @reventlessdev/reventless-domain-protocol
```

For ReScript consumers, register it as a dependency in `rescript.json`:

```json
{
  "dependencies": ["@reventlessdev/reventless-domain-protocol"]
}
```

Requires ReScript `^12.3.0`. TypeScript consumers can import the generated
`.gen.ts` types directly.

## Links

- 📚 Documentation — [docs.reventless.dev](https://docs.reventless.dev)
- 📦 Repository — [ReventlessDev/reventless-core](https://github.com/ReventlessDev/reventless-core)
- 📋 [Changelog](./CHANGELOG.md)

## License

[Apache-2.0](https://opensource.org/licenses/Apache-2.0)
