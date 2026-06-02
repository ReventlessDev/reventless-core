# Online Shop — Hybrid example

A complete, working Reventless application: a small online shop modelled with a
**hybrid** plugin style — aggregates for independent entities (Category,
Customer) and DCB slices for interdependent ones (Product + ProductDemand, Order
+ CatalogProduct). It runs locally on the in-memory platform and deploys to AWS
with Pulumi, exercising commands, events, projections, live subscriptions, and
cross-plugin extension points end to end.

This is the package behind the documentation
[Tutorial spine](../../packages/doc/docs-tutorials/get-started.md).

## Packages

| Package | Role |
|---|---|
| `catalog-spec/` | Catalog's public extension-point contract (`Products`) — depended on by Ordering |
| `ordering-spec/` | Ordering's public extension-point contract (`Orders`) — depended on by Catalog |
| `catalog/` | Catalog plugin: Category aggregate; Product/ProductDemand DCB slices; read models; task; EP + extension |
| `ordering/` | Ordering plugin: Customer aggregate; Order/CatalogProduct DCB slices; automation; outbound email; EP + extension |
| `catalog-aws/`, `ordering-aws/` | AWS deployment entry points for each plugin |
| `platform-in-memory/` | Local dev runtime — GraphQL server + in-memory stores |
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
cd platform-in-memory
pnpm run serve        # backend only: GraphQL (:4000/:4001) + MCP (:3001/:3002)
# or, with the host-shell UI (requires reventless-host-shell):
pnpm run dev:full     # backend + host-shell UI (:5173)
```

`pnpm run build` rebuilds after source changes. Sign in as `admin` / `admin`
(or `user` / `user`) — `setup` seeds these into `platform-in-memory/.reventless/users.yaml`
from the committed [`users.example.yaml`](platform-in-memory/users.example.yaml).
Via the UI, use the LoginPage; against the backend directly:

```bash
curl -s -X POST http://localhost:4000/__inmemory/login \
  -H 'content-type: application/json' -d '{"username":"admin","password":"admin"}'
```

Walkthrough: [Run it locally](../../packages/doc/docs-tutorials/run-locally.md) ·
[Test it locally](../../packages/doc/docs-tutorials/test-locally.md).

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

## Learn the model

Read the [Hybrid walkthrough](../../packages/doc/docs-tutorials/hybrid-based.md)
for the full domain model — every command, event, read model, slice, and the
cross-plugin extension-point protocol.
