---
title: Test it locally
---

# Test the running shop

With the backend and UI running (from [Run it locally](./run-locally)), this page
walks a quick end-to-end smoke test: log in, drive a command, and watch a read
model update live.

## Log in

Reventless is secure by default: commands and queries require an authenticated
user. Locally, authentication is backed by a YAML file at
`platform-local/.reventless/users.yaml`. That file is gitignored; it is seeded from the
committed template
[`platform-local/users.example.yaml`](https://github.com/ReventlessDev/reventless-core/tree/alpha/examples/online-shop-hybrid/platform-local/users.example.yaml)
by `pnpm run setup` (run from the repo root — see
[Run it locally](./run-locally#bootstrap-the-checkout)), or by hand with
`cp users.example.yaml .reventless/users.yaml` from `platform-local/`. The seeded
users are:

| Username | Password | Groups | What it is for |
|---|---|---|---|
| `admin` | `admin` | `Admin`, `Shopper` | Everything, including the platform's own admin views |
| `shopper` | `shopper` | `Shopper` | Browses the catalogue and places their own orders |
| `merch` | `merch` | `Merchandiser`, `Shopper` | Maintains products, categories, prices, images |
| `fulfil` | `fulfil` | `Fulfilment`, `Shopper` | Works the order board and ships other people's orders |

Open the shell at **http://localhost:5180**, go to the login page, and sign in as
**`admin` / `admin`**. Add your own entries to `.reventless/users.yaml` (restart
the server after editing).

The four accounts exist to show two different questions being answered
separately. `merch` and `fulfil` both operate the shop, but only `fulfil` reads
orders that belong to *other* people — so only `fulfil` is exempt from
owner-scoped reads. Sign in as `shopper` and you see your own orders and nobody
else's; sign in as `fulfil` and you see the board.

:::note Anonymous requests
Without an `X-User` header the local platform falls back to an unprivileged
`defaultUser` so casual local browsing "just works". To exercise admin features,
log in through the login page rather than relying on that fallback — `admin/admin`
is the dev admin path.
:::

## Smoke test in the UI

1. **Add a category** — e.g. "Books".
2. **Add a product** in that category — name, description, price.
3. Watch the **Products** view update **live** — it is a `StateViewSliceStream`,
   so the new row appears without a refresh (a GraphQL subscription pushes it).
4. **Register a customer**, then **place an order** referencing the product.
5. Observe the cross-plugin effects: the order's `ItemOrdered` event drives
   Catalog's `ProductDemand`, and the `AutoShipOrder` automation ships the order.

## Smoke test over GraphQL

Prefer the API directly? The domain endpoint is `http://localhost:4000/graphql`.
Fields are **plugin-prefixed** (`Catalog_…`, `Ordering_…`). Command mutations return a
`CommandResult` union, so they need a selection set; read queries return a Relay-style
connection (`edges { node { … } }`). For example, add a category:

```bash
curl http://localhost:4000/graphql \
  -H 'content-type: application/json' \
  -H 'X-User: admin' \
  -d '{"query":"mutation { Catalog_AddCategory(categoryId: \"books\", name: \"Books\") { __typename } }"}'
```

Then query it back:

```bash
curl http://localhost:4000/graphql \
  -H 'content-type: application/json' \
  -H 'X-User: admin' \
  -d '{"query":"query { Catalog_Categories { edges { node { id name } } } }"}'
```

The `X-User` header selects the user (and their groups) for authorization; omit it and the
local platform falls back to an unprivileged `defaultUser`. Exact field names come from your
command/event types — open the GraphiQL explorer at `http://localhost:4000/graphql` in a
browser to discover them.

## What you've proven

You've run the full CQRS loop locally: a command was accepted, an event was
written, projections updated, a subscription pushed the change to the UI, and a
cross-plugin extension fired — all on the local platform (a SQLite-backed store by
default), with the exact plugin code that will run on AWS.

---

**Next:** [Deploy to your AWS account →](./deploy-to-aws) — take this same example
to the cloud.
