[![npm](https://img.shields.io/npm/v/@reventlessdev/reventless-seed.svg?label=npm)](https://www.npmjs.com/package/@reventlessdev/reventless-seed)
[![License: Apache-2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)
[![Docs](https://img.shields.io/badge/docs-reventless.dev-blue)](https://docs.reventless.dev)

# @reventlessdev/reventless-seed

> ⚠️ **Alpha.** APIs and on-disk formats can change without notice between releases.
> Pin exact versions and expect breaking changes.

**A harness for seeding a [Reventless](https://docs.reventless.dev) platform
through its own GraphQL command API.** It sends real commands rather than writing
to the store, so the data it produces is data the domain can actually reach — and
a seed run doubles as a smoke test of the append path, projections, extension
points and automations.

Nothing here knows about any particular domain. It knows the shapes the
framework *generates* — the `CommandResult` union, Relay-style connections — and
leaves the mapping from your plugin's command types onto mutations to a small
adapter you write.

## Why drive the public API

Writing directly into the event log is faster to implement and ages badly: it can
produce states no command could ever create, and it keeps working after the
command that used to produce them is renamed or removed. Driving the public API
means a changed command signature surfaces immediately, and the seed exercises
every downstream path a real client would.

The cost is that seeding is domain-coupled by design. That coupling is worth
concentrating in one file — see the adapter below.

## What it provides

### `Seed.Client` — transport

Authentication, mutation dispatch, and the query helpers a seed run needs to
observe what it produced:

- **`send`** — issues one command and insists it was accepted. A rejection aborts
  the run unless its error code is listed in `~tolerate`, in which case the code
  is returned so the caller can report on it.
- **`queryAllNodes`** — walks a connection to the end. Connections page at 50 by
  default, so any count taken from a single request silently truncates.
- **`waitForIds`** — polls a `<View>ByIds` field until every id is present.
  Cross-plugin propagation (extension point → extension → command) is
  asynchronous; waiting on the observable result beats sleeping and hoping.
- **`sendInboundTranslation`** — dispatch for InboundTranslationSlice mutations,
  which currently cannot report their own outcome (see *Known gaps*).

### `Seed.Random` — deterministic generation

A seeded generator rather than `Math.random`, so two runs against a fresh store
produce identical rows and a seeded store is a usable baseline for comparison.
Includes weighted sampling without replacement and Zipf weights, for datasets
with a realistic head and a long tail rather than a flat distribution.

### `Seed.Runner` — orchestration

Phase progress, failure reporting, and view verification. Views are declared as
either `Seeded` or `Unfillable`:

```rescript
let views = [
  Seed.Runner.Seeded("Catalog_Products"),
  Seed.Runner.Unfillable("Ordering_PendingTodos", "that slice does not run locally"),
]
```

An unexpectedly empty `Seeded` view **fails the run**. That is the point: with an
empty store, "the component is broken" and "there is no data" look identical, and
seeding exists to remove that ambiguity. `Unfillable` records a view no volume of
seed data can reach, with the reason, so a zero is never read as a gap.

### `Seed` — values and mutations

`Seed.value` carries the argument types GraphQL needs, including `Enum`, which
renders as a bare identifier — quoting an enum is rejected by the server.

## A minimal seed

Three parts: the data, the adapter, and the run.

**The adapter** maps your plugin's command values onto mutations. Pattern-matching
the real variant is what makes the seed break at compile time when a command
changes, instead of failing against a half-seeded store:

```rescript
open ReventlessSeed

let addProduct = (command: CatalogPlugin.AddProduct.command): Seed.mutation =>
  switch command {
  | AddProduct({productId, name, price, categoryId}) =>
    Seed.mutation(
      "Catalog_AddProduct",
      [
        ("productId", Id(productId)),
        ("name", String(name)),
        ("price", Float(price)),
        ("categoryId", Id(categoryId)),
      ],
    )
  }
```

**The run** wires phases together:

```rescript
let client = Seed.Client.make(
  ~config={
    endpoint: Seed.Runner.envOr("REVENTLESS_GRAPHQL_ENDPOINT", "http://localhost:4000/graphql"),
    loginEndpoint: Seed.Runner.envOr("REVENTLESS_LOGIN_ENDPOINT", "http://localhost:4000/__inmemory/login"),
    username: "admin",
    password: "admin",
  },
)

let main = async () => {
  await client->Seed.Client.login
  await client->Seed.Client.sendAll(products->Array.map(p => addProduct(AddProduct(p))))
  Seed.Runner.report(`products: ${(products->Array.length)->Int.toString} added`)
  let counts = await Seed.Runner.verifyViews(client, ~views)
  Seed.Runner.warn(Seed.Runner.unfillableWarnings(~views, ~counts))
}

Seed.Runner.run(main)->ignore
```

`Seed.Runner.run` catches failures, prints the cause, and exits non-zero — saying
plainly that the store is now half-seeded, because recovery is a reset rather
than a re-run. There is deliberately no idempotence logic: seed against a fresh
store.

A complete worked example — dataset, adapter and run as three files — is the
`online-shop-hybrid` example's `platform-local/src/Demo*.res`.

## Known gaps

InboundTranslationSlice mutations are declared as returning `CommandResult!` but
their resolver returns the translated target-id array, so the GraphQL runtime
cannot resolve the union and **every call comes back as an error even when the
import succeeded**. `sendInboundTranslation` tolerates exactly that shape;
verify the outcome through the slice's audit view instead. The carve-out should
be removed once the resolver is fixed.

## Where it fits

`reventless-seed` has no Reventless dependencies — it speaks HTTP and GraphQL, so
it works against a local platform or a deployed one. Point it elsewhere with
`REVENTLESS_GRAPHQL_ENDPOINT`. It complements
[`@reventlessdev/reventless-gwt`](https://www.npmjs.com/package/@reventlessdev/reventless-gwt):
GWT tests a component in isolation, a seed run exercises a whole platform end to
end and leaves the result behind to look at.

## Install

```bash
pnpm add -D @reventlessdev/reventless-seed
```

Register it as a ReScript dependency in `rescript.json`:

```json
{
  "dependencies": ["@reventlessdev/reventless-seed"]
}
```

Requires ReScript `^12.3.0` (peer dependency).

## Links

- 📚 Documentation — [docs.reventless.dev](https://docs.reventless.dev)
- 📦 Repository — [ReventlessDev/reventless-core](https://github.com/ReventlessDev/reventless-core)
- 📋 [Changelog](./CHANGELOG.md)

## License

[Apache-2.0](https://opensource.org/licenses/Apache-2.0)
