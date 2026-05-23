---
title: Test it locally
sidebar_position: 5
---

# Test the running shop

With the backend and UI running (from [Run it locally](./run-locally)), this page
walks a quick end-to-end smoke test: log in, drive a command, and watch a read
model update live.

## Log in

Reventless is secure by default: commands and queries require an authenticated
user. Locally, authentication is backed by a YAML file —
[`platform-in-memory/.reventless/users.yaml`](https://github.com/ReventlessDev/reventless-core/tree/main/examples/online-shop-hybrid/platform-in-memory/.reventless/users.yaml):

| Username | Password | Groups |
|---|---|---|
| `admin` | `admin` | `Admin` |
| `alice` | `alice` | `Admin` |
| `bob` | `bob` | `Catalog` |
| `carol` | `carol` | _(none)_ |

Open the shell at **http://localhost:5173**, go to the login page, and sign in as
**`admin` / `admin`**. The admin user can reach every plugin's panels plus the
platform admin views.

:::note Anonymous requests
Without an `X-User` header the in-memory platform falls back to an unprivileged
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
Pass a user with the `X-User` header. For example, add a category:

```bash
curl http://localhost:4000/graphql \
  -H 'content-type: application/json' \
  -H 'X-User: admin' \
  -d '{"query":"mutation { Category_AddCategory(id: \"books\", name: \"Books\") }"}'
```

Then query it back:

```bash
curl http://localhost:4000/graphql \
  -H 'content-type: application/json' \
  -H 'X-User: admin' \
  -d '{"query":"query { Categories { id name } }"}'
```

(Exact field and mutation names come from your command/event types — open the
GraphiQL explorer at `http://localhost:4000/graphql` in a browser to discover
them.)

## What you've proven

You've run the full CQRS loop locally: a command was accepted, an event was
written, projections updated, a subscription pushed the change to the UI, and a
cross-plugin extension fired — all on in-memory infrastructure, with the exact
plugin code that will run on AWS.

---

**Next:** [Deploy to your AWS account →](./deploy-to-aws) — take this same example
to the cloud.
