[![npm](https://img.shields.io/npm/v/@reventlessdev/reventless-gwt.svg?label=npm)](https://www.npmjs.com/package/@reventlessdev/reventless-gwt)
[![License: Apache-2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)
[![Docs](https://img.shields.io/badge/docs-reventless.dev-blue)](https://docs.reventless.dev)

# @reventlessdev/reventless-gwt

> ⚠️ **Alpha.** APIs and on-disk formats can change without notice between releases.
> Pin exact versions and expect breaking changes.

**Given-When-Then test DSLs and a CLI runner** for slice-level testing in
[Reventless](https://docs.reventless.dev) — a spec-driven, event-sourced CQRS
framework written in [ReScript](https://rescript-lang.org). Each DSL wraps one
kind of framework component (aggregate, slice, projection, automation,
translation, flow) in a declarative triple-A (`given / when / then`) surface, and
the `reventless-dev` CLI discovers and runs those tests across a workspace.

## What it provides

### ReScript test DSLs

Every component kind has a functor that produces the same
`describe / test / given* / when* / then*` combinator surface:

- **`Behavior_GWT`** — event-sourced behavior tests for aggregates and
  StateChangeSlices (`givenEvents → whenCmd → thenEmits`), including DCB
  append-condition assertions.
- **`Projection_GWT`** / **`MultiSourceProjection_GWT`** — single-source
  (StateViewSlice) and multi-source (ReadModel) projection tests.
- **`Query_GWT`** — the read side: which query patterns the projected state must
  support (indexes, sub-ids, resolvers).
- **`Automation_GWT`** — AutomationSlice reaction tests (event → command).
- **`InboundTranslation_GWT`** / **`OutboundTranslation_GWT`** /
  **`EventMapping_GWT`** / **`Mapping_GWT`** — cross-component translation tests.
- **`Flow_GWT`** — cross-slice / end-to-end tests that thread one event log
  through a chain of slices, verifying the wiring between tiles of an Event
  Modeling board.

### CLI runner

The package installs the `reventless-dev` command (alias: `reventless-gwt`):

```
reventless-dev run [--format=<fmt>] [--filter=<id>] [--stream] [--watch] [path...]
reventless-dev discover [--format=vscode] [path...]
reventless-dev watch [--format=<fmt>] [--filter=<id>] [path...]
reventless-dev platform [--format=vscode] [--backend=<b>] [--ui-ports] [path...]
```

It walks a workspace to discover compiled GWT tests, runs them, and reports
through pluggable formatters — `human`, `json`, `tap`, `junit`, and `vscode`
(NDJSON). It also emits the domain graph / component inventory used by editor
surfaces and can launch a local platform for integration runs.

## Where it fits

`reventless-gwt` builds on
[`@reventlessdev/reventless-core`](https://www.npmjs.com/package/@reventlessdev/reventless-core)
and [`@reventlessdev/reventless-spec`](https://www.npmjs.com/package/@reventlessdev/reventless-spec):
the DSLs test the same component specs you write against core, with no storage or
cloud adapter required. Its `--format=vscode` output speaks the
[`@reventlessdev/reventless-domain-protocol`](https://www.npmjs.com/package/@reventlessdev/reventless-domain-protocol)
NDJSON contract, so the same runs drive the VS Code extension's test tree and
domain views.

## Install

```bash
pnpm add -D @reventlessdev/reventless-gwt
```

Register it as a ReScript dependency in `rescript.json`:

```json
{
  "dependencies": ["@reventlessdev/reventless-gwt"]
}
```

Requires ReScript `^12.3.0` (peer dependency). Run the CLI with `pnpm exec
reventless-dev run` (or add it to a package script).

## Links

- 📚 Documentation — [docs.reventless.dev](https://docs.reventless.dev)
- 📦 Repository — [ReventlessDev/reventless-core](https://github.com/ReventlessDev/reventless-core)
- 📋 [Changelog](./CHANGELOG.md)

## License

[Apache-2.0](https://opensource.org/licenses/Apache-2.0)
