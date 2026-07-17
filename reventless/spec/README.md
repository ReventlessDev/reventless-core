[![npm](https://img.shields.io/npm/v/@reventlessdev/reventless-spec.svg?label=npm)](https://www.npmjs.com/package/@reventlessdev/reventless-spec)
[![License: Apache-2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)
[![Docs](https://img.shields.io/badge/docs-reventless.dev-blue)](https://docs.reventless.dev)

# @reventlessdev/reventless-spec

> ⚠️ **Alpha.** APIs and on-disk formats can change without notice between releases.
> Pin exact versions and expect breaking changes.

The **specification layer** of [Reventless](https://docs.reventless.dev) — a
spec-driven, event-sourced CQRS framework written in [ReScript](https://rescript-lang.org).
This package holds the type specifications and module-type interfaces that the rest of the
framework is built on: the contracts application domain code implements (commands, events,
behaviors, projections) and the component-kind vocabulary the whole framework shares. It
has **no** runtime, cloud, or storage dependency, so domain code can declare its shape
against `reventless-spec` without pulling in an implementation. Modules are exposed under
the `Reventless` namespace.

## What it provides

ReScript modules, consumed by adding the package to your `rescript.json` `dependencies`.

**Domain contracts (`types/`)**

- **`Message`** — the envelope metadata carried by every event and command (`meta`,
  `event'<>`, `command'<>`), used for audit, correlation, tracing, and routing.
- **`Behavior`** — the module type application code implements to define aggregate business
  logic: `initialState`, `evolve(state, event)`, and `decide(command, state)`.
- **`Projection`** — `Source` / `Target` module types describing a read model projected
  from an aggregate's events.
- **`Handler`** — function signatures for handling commands, events, and errors.
- **`SideEffect`** — module type for an imperative side effect triggered by aggregate events
  (read-only access to the query engine; emits no events).
- **`StoredEvent`** — the logical envelope for an event as it lives in storage; single
  source of truth for the on-disk event shape.
- **`Authorization`** / **`Identity`** — provider-agnostic permission rules evaluated against
  a resolved identity.
- **`QueryEngine`** — typed filter values and operations for read-model queries.
- **`Id`**, **`EventMapping`**, **`ReadConsistency`**, **`Schedule`**, **`Visibility`** —
  supporting spec types for identifiers, event translation, consistency, scheduling, and
  exposure.

**Component vocabulary (`components/`)**

- **`ComponentKind`** — the single source of truth for the Reventless component-kind
  vocabulary (aggregates, read models, tasks, extension points, DCB slices), including every
  accepted folder spelling and body-file suffix.
- Per-kind spec modules: `Aggregate`, `ReadModel`, `Task`, `ExtensionPoint`, `Plugin`, and
  the DCB slices (`StateChangeSlice`, `StateViewSlice`, `AutomationSlice`,
  `InboundTranslationSlice`, `OutboundTranslationSlice`), plus DCB tagging/validation helpers.

**`generate-plugin` CLI**

`reventless-spec` ships a `generate-plugin` binary that auto-generates `src/Plugin.res` from
a plugin's folder structure, classifying `.res` files by their parent folder name — no
hand-authored composition root required.

```bash
generate-plugin src/          # generate src/Plugin.res from the src/ folder
```

Wire it into your build via a `prebuild` script so it runs before `rescript build`. The
generated `Plugin.res` is committed to git, so CI compiles it directly.

## Where it fits

`reventless-spec` is the foundation package in the Reventless framework:

```
reventless-spec (specifications)  ← this package
  ↓
reventless-core (provider-agnostic framework)
  ↓
reventless-aws / reventless-postgres / reventless-local (storage & deployment adapters)
```

- [`@reventlessdev/reventless-core`](https://www.npmjs.com/package/@reventlessdev/reventless-core)
  builds on these specs to provide the runtime building blocks.
- [`@reventlessdev/reventless-infra`](https://www.npmjs.com/package/@reventlessdev/reventless-infra)
  layers deploy-time infrastructure types on top of the same specs.

You normally obtain `reventless-spec` transitively by scaffolding an app rather than
installing it on its own.

## Install

```bash
pnpm add @reventlessdev/reventless-spec
```

Then register it as a ReScript dependency in `rescript.json`:

```json
{
  "dependencies": ["@reventlessdev/reventless-spec"]
}
```

Requires ReScript `^12.3.0` (peer dependency).

## Links

- 📚 Documentation — [docs.reventless.dev](https://docs.reventless.dev)
- 📦 Repository — [ReventlessDev/reventless-core](https://github.com/ReventlessDev/reventless-core)
- 📋 [Changelog](./CHANGELOG.md)

## License

[Apache-2.0](https://opensource.org/licenses/Apache-2.0)
