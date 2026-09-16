---
title: Deploy to your AWS account
---

# Deploy the online shop to your AWS account

This page puts the online shop into **your** AWS account: a web shop you open in a
browser, four demo accounts to sign in with, and everything behind them. One
command deploys it, and one removes it again. You do not need to have read the
code walkthrough or run the shop locally first.

Budget about twenty minutes for a first run, most of it waiting for AWS.

## What you need

- **An AWS account**, and credentials on your machine that can create DynamoDB,
  Lambda, SQS, SNS, S3, AppSync, CloudFront, Cognito, IAM, SSM and Amazon Location
  resources. Give your AWS profile a region, or set `AWS_REGION` — the shop is
  deployed there.
- **The [Pulumi CLI](https://www.pulumi.com/docs/install/)**, logged in. A free
  Pulumi Cloud account works (`pulumi login`), and so does a backend of your own
  (`pulumi login --local`); on your own backend, also set
  `PULUMI_CONFIG_PASSPHRASE` (it may be empty).
- **Node 22.17.1 and pnpm 10**, and a checkout of this repository:

```bash
git clone https://github.com/ReventlessDev/reventless-core && cd reventless-core
pnpm run setup
```

The AWS CLI is not needed.

### What it will cost

Everything the shop deploys is pay-per-request and scales to zero: DynamoDB
on-demand tables, Lambda functions, SQS queues, SNS topics, an AppSync API, S3
buckets, a CloudFront distribution and a Cognito user pool. There is no
always-on server, cluster or NAT gateway.

An idle deployment costs cents per month, mostly for stored files and logs.
Trying it out by hand stays inside the free tier for most accounts.

## Deploy it

```bash
pnpm run shop:up
```

It deploys a try-out stack named `dev`, in this order:

1. **Checks** that Node, your AWS credentials and region, and the Pulumi login are
   in order, before anything is created. Each problem it finds says how to fix it.
2. **Publishes the Lambda layer** — the framework code every function shares — from
   the release that matches your checkout, into your account and region. A layer
   already published for this version is reused.
3. **Deploys the three stacks**: the platform first, then the Catalog and Ordering
   plugins. You see Pulumi's own progress as it goes.
4. **Writes the component manifest**, the file that tells the web app which pages
   each kind of user sees. It waits until both plugins have registered with the
   platform, and says which one it is waiting for.
5. **Creates the four demo accounts** in the shop's user pool.
6. **Prints the web address and the sign-ins**:

```
── Ready ──

  Open:    https://d3ujt15if7d1jl.cloudfront.net
  Sign in:
    admin@example.com    [Admin, Shopper]
    shopper@example.com  [Shopper]
    merch@example.com    [Merchandiser, Shopper]
    fulfil@example.com   [Fulfilment, Shopper]
  The passwords are in …/platform-aws/.reventless/users.dev.yaml.
```

The passwords are generated for your deployment and kept in that file rather than
printed. The addresses are under `example.com`, which is reserved, so no mail
reaches anyone.

**If it stops**, fix what it names and run `pnpm run shop:up` again. Everything it
already created is kept and reused, so a second run only does what is left. A
temporary AWS error ("Internal KMS service error. Try again.") needs nothing but
the second run.

The try-out stack's settings are written to `Pulumi.dev.yaml` in each stack folder.
Those files are ignored by git.

## What you have now

- **The shop, in a browser.** The printed address serves the web app, with screens
  generated from the shop's views and commands. Sign in as `admin@example.com`,
  create a category and a product, place an order — and watch the views update
  live while you do it.
- **Four roles.** Each account sees a different part of the shop: the shopper only
  their own orders, the merchandiser the catalog, fulfilment every order and the
  shipping actions, the administrator everything.
- **A GraphQL API.** Every command is a mutation and every view a query and a
  subscription, with fields prefixed per plugin (`Catalog_…`, `Ordering_…`).
  Anything the web app can do, your own client can do.
- **The complete event history**, in DynamoDB tables in your account, readable with
  ordinary AWS tooling.

The shop starts empty. [Test it on AWS](./test-on-aws) fills it with demo data and
checks the live updates. The MCP endpoint that lets AI assistants drive the shop is
available on the local platform only.

## Remove it again

```bash
pnpm run shop:down
```

This removes the three stacks in reverse order, then the Lambda layer and the SSM
parameter that `shop:up` published. Nothing else needs cleaning up: a try-out stack
is marked disposable, so its storage is emptied and removed with it.

It removes only stacks that `shop:up` created. A stack without the disposable
marking — `alpha`, or a real deployment — is refused, and nothing is removed.
If a removal is interrupted, run it again; it continues where it stopped.

`.reventless/users.dev.yaml` stays. The next `shop:up` reuses its passwords for the
new accounts.

## Deploying your own stacks

`shop:up` is `deploy-app up` from `@reventlessdev/reventless-aws`, run for this
example. It reads the app's `deploy-manifest.yaml`, so it works for your own app
too. To deploy stack by stack instead — for a long-lived environment, your own
identity provider, or CI — see [Getting Started with AWS](/infrastructure/aws/get-started)
and the [deployment guide](/infrastructure/deployment-guide).

---

**Next:** [Test it on AWS →](./test-on-aws) — sign in, seed demo data, and check
the live channels.
