---
title: Test it on AWS
---

# Test the deployed shop

Once `pnpm run shop:up` has finished (see [Deploy to your AWS account](./deploy-to-aws)),
this page signs you in, fills the shop with demo data, and checks the live
channels the web app uses.

## Sign in

Open the address `shop:up` printed. If it has scrolled away, the platform stack
still knows it:

```bash
cd examples/online-shop-hybrid/platform-aws
pulumi stack output hostShellUrl --stack dev
```

Sign in with one of the four printed accounts. Their passwords are in
`platform-aws/.reventless/users.dev.yaml`, beside each username. Each account plays
one role of the shop, and sees a different part of it:

| Account | Role | Sees |
|---|---|---|
| `shopper@example.com` | Shopper | the catalog, and only their own orders |
| `merch@example.com` | Merchandiser | the catalog to maintain: products, categories, prices, images |
| `fulfil@example.com` | Fulfilment | every customer's orders, and the actions to ship them |
| `admin@example.com` | Admin | everything, including the platform's own views |

Sign in as `admin@example.com` and try the same things as locally: add a category
and a product, register a customer, place an order, and watch the views update.

### An administrator of your own

To sign in with your own address instead, make one administrator:

```bash
cd examples/online-shop-hybrid/platform-aws
pnpm exec provision-admin --email you@example.com --stack dev
```

That creates the account, sets a permanent password, puts it in the `Admin` group,
and prints the credentials once. Running it again is safe and mints a new password.
[The first administrator](/app/first-admin) explains why being in the group is only
half of what makes someone an administrator.

## Seed demo data (optional)

To fill the views without clicking through by hand:

```bash
pnpm run shop:seed
```

It seeds the `dev` stack through the same public GraphQL API the web app uses. It
asks which data set to seed (`full` or `sample`) and which account to seed as —
the accounts come from `users.dev.yaml`, so there is nothing to type. The `full`
set takes a few minutes: several hundred requests and about 75 image uploads.

The demo orders, customers and notifications are keyed to the accounts you sign in
with, so after seeding the shopper sees orders of their own — and nobody else's.

The seed runs once per deployment: it refuses a stack that already holds data. To start
over, run `pnpm run shop:down` and `pnpm run shop:up` again.

**Running it by hand.** `shop:seed` is `pnpm run seed` in `platform-aws/` with
`SEED_STACK=dev` and `SEED_USERS_FILE=.reventless/users.dev.yaml`. `SEED_SET`
(`full` or `sample`) answers the first question, `SEED_USER` the second, and
`SEED_SKIP_UPLOADS=1` skips the product images. The seed reads the stack from
whatever backend your `pulumi` CLI is logged into; `SEED_PULUMI_BACKEND` names
another one for a single run.

## Check the live channels

The web app receives changes over a WebSocket, and signed-in users can publish to
their own channels but not to the one the platform's change notifications travel
on. One command checks both from the outside:

```bash
cd examples/online-shop-hybrid/platform-aws
SEED_STACK=dev SEED_USERS_FILE=.reventless/users.dev.yaml pnpm run verify:client-publish
```

It finds the deployment's endpoints by itself and signs in with an account from the
file. A signed-in user subscribes to a channel, publishes to it and receives the
event, and is refused when publishing to the platform's channel. It needs no AWS
credentials.

## What you've proven

The deployed shop runs the identical plugin code you can run locally — now on
DynamoDB, Lambda, SQS, AppSync, CloudFront and Cognito in your own account, with
each role seeing its own part of it.

When you are done, `pnpm run shop:down` removes everything.

---

**Where to next?**

- Build your own application → [App Guide](/app/get-started).
- Point the deployed shell at your own domain →
  [Custom domain for the host UI](/infrastructure/custom-domain).
- Contribute to the framework → [Contributing](/framework/contributing).
