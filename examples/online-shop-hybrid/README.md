# Online Shop — Hybrid example

A complete, working Reventless application: a small online shop modelled with a
**hybrid** plugin style — aggregates for self-contained entities (Customer) and
DCB slices for entities that take part in cross-slice invariants (Category,
Product + ProductDemand, Order + CatalogProduct). Adding a product verifies —
inside its decision model — that the referenced category exists and is active,
which is exactly why Category is modelled as DCB slices writing to the shared
catalog event log: a DCB slice can read a sibling slice's events, but not an
aggregate's isolated log. It runs locally on the local platform and deploys to
AWS with Pulumi, exercising commands, events, projections, live subscriptions,
and cross-plugin extension points end to end.

This is the package behind the documentation
[Tutorial spine](../../packages/doc/docs-tutorials/get-started.md).

## Packages

| Package | Role |
|---|---|
| `catalog-spec/` | Catalog's public extension-point contract (`Products`) — depended on by Ordering |
| `ordering-spec/` | Ordering's public extension-point contract (`Orders`) — depended on by Catalog |
| `catalog/` | Catalog plugin: Category, Product, and ProductDemand DCB slices (AddProduct verifies the referenced category exists); StateView stream views; task; EP + extension |
| `ordering/` | Ordering plugin: Customer aggregate; Order/CatalogProduct DCB slices; the `Customers` mixed aggregate+DCB read model (profile + order count); automation; outbound email; EP + extension |
| `catalog-aws/`, `ordering-aws/` | AWS deployment entry points for each plugin |
| `platform-local/` | Local dev runtime — GraphQL server + in-memory stores |
| `platform-aws/` | AWS platform: shared AppSync API, admin components, scheduler, host-shell SPA |

`src/Plugin.res` in each plugin is **generated** by `generate-plugin src/` (a
`prebuild` step) — it is committed but never hand-edited.

## Run it locally

On a fresh clone, bootstrap once from the **repo root** (creates the workspace
config, installs, ensures the PPX binary, seeds dev users, builds this example):

```bash
pnpm run setup        # see the root README "Getting Started"
```

Then, from this example:

```bash
cd platform-local
pnpm run serve        # backend only: GraphQL (:4000/:4001) + MCP (:3001/:3002)
# or, with the host-shell UI (requires reventless-host-shell):
pnpm run dev:full     # backend + host-shell UI (:5180), with live reload
```

`dev:full` recompiles and restarts the backend on any `.res` change (live
reload). Stores default to **on-disk SQLite** (`./.reventless/local.db`, persists
across restarts); use `serve:memory` / `dev:full:memory` for stateless runs or
`serve:reset` / `dev:full:reset` for a clean boot. The backend logs at
`LOG_LEVEL=debug` by default (set `LOG_LEVEL=info` to quieten). See
[docs/guides/local-dev.md](../../docs/guides/local-dev.md) for the full matrix.

`pnpm run build` rebuilds after source changes. Sign in as `admin` / `admin`
(or `user` / `user`) — `setup` seeds these into `platform-local/.reventless/users.yaml`
from the committed [`users.example.yaml`](platform-local/users.example.yaml).
Via the UI, use the LoginPage; against the backend directly:

```bash
curl -s -X POST http://localhost:4000/__inmemory/login \
  -H 'content-type: application/json' -d '{"username":"admin","password":"admin"}'
```

Walkthrough: [Run it locally](../../packages/doc/docs-tutorials/run-locally.md) ·
[Test it locally](../../packages/doc/docs-tutorials/test-locally.md).

## Seed demo data

Every view starts empty, which makes "the component is broken" and "there is no
data" look identical. `seed` fills them — the `full` set is 8 categories, 64
products, 20 customers and 150 orders — by driving the example's own GraphQL
mutations. The provider is **where you run it**, not a prompt: `pnpm run seed` in
`platform-local/` seeds the local dev platform, and in `platform-aws/` it seeds
the deployed stack.

```bash
cd platform-local
pnpm run serve:reset     # in one shell — a clean store
pnpm run seed            # in another — pick a data set, log in as admin/admin
```

Two data sets ship, so the run first asks which to seed: `full` (above) and a
compact `sample` (16 products, 8 customers, 40 orders) for a quick check. It then
prompts for a **username and password**. Local authenticates against the dev
`/__inmemory/login` route (the seeded `admin`/`admin` by default). A single
shared prompt handles the whole run.

Generation is deterministic (fixed PRNG seed, fixed literal data), so a reset
plus a re-run reproduces the same rows. There is no idempotence logic: run it
against a fresh store, not on top of an existing one.

For a non-interactive run (CI), set `SEED_SET` (`full` or `sample`) plus
`REVENTLESS_DEMO_USER`/`REVENTLESS_DEMO_PASSWORD` to skip every prompt. Add
`SEED_SKIP_UPLOADS=1` to seed the domain data without product images (leaving
`imageUrl` empty) — handy when a deployment serves no upload endpoint.

Because it goes through the public command API rather than writing to the store,
it doubles as a smoke test — and it is **domain-coupled by design**. The seed is
built from real plugin command values (`AddProduct.command`,
`PlaceOrder.command`, …), so a renamed or re-shaped command breaks the build
rather than seeding states the domain can no longer reach.

The domain data is a shareable package, [`online-shop-hybrid-seed`](seed-data),
so both platform scripts import the same sets:

| File | Role |
|---|---|
| `seed-data/src/DemoData.res` | *What* to seed — literal data and the deterministic generation that turns it into categories, products, customers and orders |
| `seed-data/src/DemoCommands.res` | The adapter — how this example's command values map onto GraphQL mutation fields and arguments |
| `seed-data/src/HybridSeedData.res` | The data sets — phases, view verification, and the summary, exported as `Seed.dataSet` values |
| `platform-local/src/SeedLocal.res` | Thin entry — `Seed.Runner.seed` with the local connection |
| `platform-aws/src/SeedAws.res` | Thin entry — `Seed.Runner.seed` with the AWS connection |

The transport, prompts, connection, deterministic randomness, view checks and
failure reporting are generic and live in
[`@reventlessdev/reventless-seed`](../../reventless/seed); the AWS connect (stack
discovery + Cognito login) lives in
[`@reventlessdev/reventless-seed-aws`](../../reventless/seed-aws). Neither package
knows about this domain.

The order data is shaped by the shipping method each order is placed with, which
is what makes the lifecycle visible: `Express` orders are auto-shipped by the
`AutoShipOrder` automation, most `Standard` orders are shipped by a batch-dispatch
phase, and the remaining `Standard` and `Pickup` orders stay `Placed` — so a
share of them can then be cancelled. The run prints the resulting
`status` × `shippingMethod` breakdown.

Every queryable view ends the run non-empty, including
`SendOrderConfirmationTodos` — one row per placed order, each `Completed` once
the `SendOrderConfirmation` OutboundTranslationSlice has called `EmailService`.

## Deploy it to AWS

Deploy the platform stack first, then the plugins (Pulumi):

```bash
pnpm install && pnpm run build          # from the repo root

cd platform-aws && pulumi up --stack alpha
cd ../catalog-aws && pulumi up --stack alpha
cd ../ordering-aws && pulumi up --stack alpha   # depends on catalog
```

Before deploying, point the stack configs at your own Pulumi org and review the
Cognito + host-shell settings — see
[Deploy to your AWS account](../../packages/doc/docs-tutorials/deploy-to-aws.md)
and [Test it on AWS](../../packages/doc/docs-tutorials/test-on-aws.md).

## Seed the deployed shop

Run [`pnpm run seed`](#seed-demo-data) from `platform-aws/` — it targets AWS by
construction. It picks the stack (or `SEED_STACK`), discovers the endpoints from
the stack's published `config.json` (or its stack outputs), and signs in against
Cognito. The user must exist with a permanent password — see
[Test it on AWS](../../packages/doc/docs-tutorials/test-on-aws.md). As locally,
the seed is **non-idempotent** — run it against a fresh deployment.

```bash
cd platform-aws
pnpm run seed            # pick a data set and stack, then log in
```

## Learn the model

Read the [Hybrid walkthrough](../../packages/doc/docs-tutorials/hybrid-based.md)
for the full domain model — every command, event, read model, slice, and the
cross-plugin extension-point protocol.
