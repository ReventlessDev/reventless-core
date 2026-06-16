# Online Shop — DCB example

A complete, working Reventless application: a small online shop modelled with
a **DCB-only** plugin style — every entity (Category, Product, Customer,
Order, CatalogProduct) lives behind StateChangeSlices, StateViewSlices and
Automations that share a single per-plugin DCB event log. It runs locally on
the local platform and deploys to AWS with Pulumi, exercising commands,
events, projections, live subscriptions, and cross-plugin extension points end
to end.

DCB (Dynamic Consistency Boundary) lets independent slices commit against a
shared log with optimistic-concurrency tags — write models stay small while
still enforcing cross-entity invariants. For the mixed-style example that
pairs DCB slices with aggregates, see
[`examples/online-shop-hybrid/`](../online-shop-hybrid/). For the
aggregate-only counterpart, see
[`examples/online-shop-aggregates/`](../online-shop-aggregates/).

## Packages

| Package | Role |
|---|---|
| `catalog-spec/` | Catalog's public extension-point contract (`Products`) — depended on by Ordering |
| `ordering-spec/` | Ordering's public extension-point contract (`Orders`) — depended on by Catalog |
| `catalog/` | Catalog plugin: Category + Product DCB slices, read models, EP + extension |
| `ordering/` | Ordering plugin: Customer + Order + CatalogProduct DCB slices, automation, outbound email, EP + extension |
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
| StateChangeSlice | `catalog/src/Category/StateChangeSlice/`, `catalog/src/Product/StateChangeSlice/`, `ordering/src/Order/StateChangeSlice/`, … |
| StateViewSlice | `catalog/src/*/StateViewSlice/`, `ordering/src/*/StateViewSlice/` |
| AutomationSlice | `ordering/src/Order/AutomationSlice/` |
| InboundTranslationSlice | `catalog/src/Product/InboundTranslationSlice/` |
| OutboundTranslationSlice | `ordering/src/Order/OutboundTranslationSlice/` |
| Multi-source ReadModel | `catalog/src/CategoryActivity/ReadModel/` |
| ExtensionPoint | `catalog/src/ExtensionPoint/`, `ordering/src/ExtensionPoint/` |
| Extension | `catalog/src/Extension/`, `ordering/src/Extension/` |
| Task | `catalog/src/Task/` |
| `@@reventless.visibility(Internal)` | `ordering/src/CatalogProduct/StateViewSlice/AvailableProducts/` |
| `@authorize` | one Category command annotated for the `Admin` group |
| `@displayName` | Customer's `email` field |
| Cross-plugin Flow test | `platform-local/tests/Flow/DcbFlow_GWT.res` |
