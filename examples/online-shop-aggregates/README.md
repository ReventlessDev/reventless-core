# Online Shop — Aggregates example

A complete, working Reventless application: a small online shop modelled with
an **aggregate-only** plugin style — every entity (Category, Product,
ProductDemand, Customer, Order, CatalogProduct) is its own aggregate root with
its own command/event log. It runs locally on the local platform and deploys to
AWS with Pulumi, exercising commands, events, projections, live subscriptions,
and cross-plugin extension points end to end.

This example shows what classic event-sourced CQRS looks like in Reventless.
For the mixed-style example that pairs aggregates with DCB slices, see
[`examples/online-shop-hybrid/`](../online-shop-hybrid/). For the DCB-only
counterpart, see [`examples/online-shop-dcb/`](../online-shop-dcb/).

## Packages

| Package | Role |
|---|---|
| `catalog-spec/` | Catalog's public extension-point contract (`Products`) — depended on by Ordering |
| `ordering-spec/` | Ordering's public extension-point contract (`Orders`) — depended on by Catalog |
| `catalog/` | Catalog plugin: Category, Product, ProductDemand aggregates; read models; EP + extension |
| `ordering/` | Ordering plugin: Customer, Order, CatalogProduct aggregates; outbound email translation; EP + extension |
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
pnpm run dev:full     # backend + host-shell UI (:5173), with live reload
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

## Deploy it to AWS

Deploy the platform stack first, then the plugins (Pulumi):

```bash
pnpm install && pnpm run build          # from the repo root

cd platform-aws && pulumi up --stack alpha
cd ../catalog-aws && pulumi up --stack alpha
cd ../ordering-aws && pulumi up --stack alpha   # depends on catalog
```

Before deploying, point the stack configs at your own Pulumi org and review the
Cognito + host-shell settings.

## Pattern coverage

| Pattern | Where |
|---|---|
| Aggregate | `catalog/src/Category/Aggregate/`, `catalog/src/Product/Aggregate/`, `ordering/src/Order/Aggregate/`, … |
| ReadModel | `catalog/src/*/ReadModel/`, `ordering/src/*/ReadModel/` |
| ExtensionPoint | `catalog/src/ExtensionPoint/`, `ordering/src/ExtensionPoint/` |
| Extension | `catalog/src/Extension/`, `ordering/src/Extension/` |
| SideEffect | `ordering/src/Order/SideEffect/Order_EmailNotification.res` (aggregate-side egress; DCB uses `OutboundTranslationSlice` instead) |
| Task | `ordering/src/Task/` — hosts the SideEffect |
| `@authorize` | one Category command annotated for the `Admin` group |
| Per-aggregate Behavior GWTs | `ordering/tests/*/Aggregate/*_GWT.res` (cross-plugin `Flow_GWT` is DCB-only today — see the hybrid example for a cross-plugin flow) |
