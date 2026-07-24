# Seeding Guide

This guide covers filling a running platform with data — for a demo, for manual
exploration, or as an end-to-end smoke test. It is for application developers who
have a platform running locally and are looking at nine empty grids.

The `online-shop-hybrid` example is the running illustration; its seeder lives in
`platform-local/src/` and is built on
[`@reventlessdev/reventless-seed`](https://www.npmjs.com/package/@reventlessdev/reventless-seed).

## 1. Why an empty store is a problem

Auto UI generates a page per queryable component. Before there is data, every one
of them renders an empty grid — and an empty grid is indistinguishable from a
broken projection, a mis-wired extension point, or a component that never
deployed. "The component is broken" and "there is no data" look the same.

Seeding removes that ambiguity. Everything else in this guide follows from
wanting to keep it removed.

## 2. Drive the command API, not the store

The tempting shortcut is to write events straight into the log, or rows into the
query database. It is faster to write and it ages badly:

- it can produce states no command could ever create, so the UI ends up
  displaying situations the domain considers impossible;
- it keeps working after the command that used to produce those states is
  renamed or deleted, so the seed silently drifts away from the domain;
- it skips projections, the append path, extension points and automations — the
  parts most likely to actually be broken.

Sending real commands through the public GraphQL API costs a little more and buys
all three back. A seed run becomes a smoke test: in the hybrid example, seeding
150 orders exercises the DCB append path, both extension points, the
`AutoShipOrder` automation, and every projection, because the data has to travel
those paths to exist at all.

It also means no privileged back door has to exist for seeding.

## 3. Split the seed three ways

Seeding is domain-coupled by design — that is the point. Concentrate the coupling
rather than spreading it:

| Part | Holds | Example |
|---|---|---|
| **Data** | *What* to seed: literal data and the generation that turns it into entities | `DemoData.res` |
| **Adapter** | How your command values map onto mutation fields and arguments | `DemoCommands.res` |
| **Run** | Phases, view verification, summary | `DemoSeed.res` |

Everything domain-agnostic — transport, deterministic randomness, view checks,
failure reporting — comes from the `reventless-seed` package and needs no
per-project code.

### The adapter is where type safety lands

Build commands as **real plugin command values**, then pattern-match them in the
adapter:

```rescript
let addProduct = (command: CatalogPlugin.AddProduct.command): Seed.mutation =>
  switch command {
  | AddProduct({productId, name, description, price, categoryId}) =>
    Seed.mutation(
      "Catalog_AddProduct",
      [
        ("productId", Id(productId)),
        ("name", String(name)),
        ("description", String(description)),
        ("price", Float(price)),
        ("categoryId", Id(categoryId)),
      ],
    )
  }
```

Rename a field on the command, and this stops compiling. Compare that with a seed
built from hand-written GraphQL strings, which compiles happily and fails
mid-run, leaving a half-seeded store behind.

The same trick catches commands that should not be seeded at all. A `@noApi`
variant has no mutation field to encode to, so the adapter can say so explicitly:

```rescript
| ReopenOrder(_) =>
  throw(Seed.Failed("ReopenOrder is @noApi — it cannot be seeded through the GraphQL API"))
```

## 4. Make it deterministic

Use a fixed seed and fixed literal data. No `Date.now()`, no unseeded randomness:

```rescript
let random = ReventlessSeed.Seed.Random.make(~seed=0x5eed)
```

Two runs against a fresh store then produce byte-identical rows, which is what
makes a seeded store usable as a baseline — for screenshots, for comparing two
branches, or for a future visual regression check. Determinism is per
implementation: changing how the generator is consumed changes the dataset, so
verify by resetting and re-running, then diffing a dump of every view.

## 5. Shape the data deliberately

Volume alone demonstrates nothing. A board with every card in one column, a
leaderboard with a flat line, or a dashboard reading zero everywhere is as
uninformative as an empty grid. Decide the shape:

- **Status mixes that read on a board.** Check what your domain actually allows.
  If an automation moves every entity out of its initial state immediately, that
  state is unreachable and no seed can show it — the fix is in the domain, not
  the seeder.
- **Head-and-tail distributions.** `Seed.Random.zipfWeights` over a shuffled
  array gives a clear leader and a long tail, so a top-N view looks like a real
  leaderboard.
- **Long-tailed numerics.** A log-uniform price spread reads better than a linear
  one, which clusters in the middle of its range.
- **Some post-creation churn.** Rename, reprice, archive a few entities so views
  are not uniformly "created once and never touched".

## 6. Verify what you produced

Declare every queryable view, and split them by whether the seed can fill them:

```rescript
let views = [
  Seed.Runner.Seeded("Catalog_Products"),
  Seed.Runner.Seeded("Ordering_Orders"),
  Seed.Runner.Unfillable(
    "Ordering_SendOrderConfirmationTodos",
    "that OutboundTranslationSlice does not run on the local platform",
  ),
]

let counts = await Seed.Runner.verifyViews(client, ~views)
Seed.Runner.warn(Seed.Runner.unfillableWarnings(~views, ~counts))
```

An unexpectedly empty `Seeded` view fails the run — it means the seed missed a
component, which is exactly the ambiguity you are trying to remove. `Unfillable`
is not a way to silence that: it records a view no volume of data can reach,
along with the reason, so a zero there is never misread as a gap. If you find
yourself adding `Unfillable` entries, you have found a defect worth writing down.

## 7. Fail loudly, recover by resetting

A GraphQL error or an unexpected rejection aborts the run and prints the
offending mutation with the response. Half-seeded data is worse than none,
because it looks like a working dataset.

There is deliberately no idempotence logic. Seed against a fresh store:

```bash
pnpm run serve:reset     # in one shell
pnpm run demo-data       # in another
```

## 8. Pitfalls

Four things that are easy to get wrong and quiet when you do:

- **GraphQL enums are bare identifiers.** `shippingMethod: Express`, not
  `shippingMethod: "Express"` — a quoted enum is rejected. Use `Seed.Enum`.
- **Connections page at 50.** Any count taken from a single request silently
  truncates. Use `queryAllNodes`, which walks the cursors, before believing a
  total.
- **Cross-plugin propagation is asynchronous.** Events travelling extension point
  → extension → command have not landed when the originating mutation returns. A
  command depending on the result will be rejected. Use
  `Seed.Client.waitForIds` to wait on the observable result rather than sleeping
  for a guessed interval.
- **Seeding is in the review scope of command changes.** With typed commands the
  build tells you, but only if the seeder is built — keep it in CI or in the
  workspace build.

## 9. Where to put it

The seeder belongs with the platform package that serves the API — for the hybrid
example, `platform-local/src/` — and gets wired as a script:

```json
{
  "scripts": {
    "demo-data": "node src/DemoSeed.res.mjs"
  }
}
```

Point it at a different platform with `REVENTLESS_GRAPHQL_ENDPOINT` and
`REVENTLESS_LOGIN_ENDPOINT`; nothing in the harness assumes a local runtime.

## Related

- [Generated GraphQL API Guide](graphql-api-guide.md) — the mutation names and
  argument shapes an adapter encodes to
- [Writing Unit Tests](writing-unit-tests.md) — component-level testing, which a
  seed run complements rather than replaces
- [Build your own app](platform-and-plugin-guide.md)
