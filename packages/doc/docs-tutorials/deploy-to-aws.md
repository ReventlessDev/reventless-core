---
title: Deploy to your AWS account
---

# Deploy the online shop to your AWS account

This page deploys the online shop into **your** AWS account with Pulumi. It is
self-contained: you do not need to have read the code walkthrough, and you do not
need to have run the shop locally first. The full reference (multi-repo, secrets,
every config key) lives in the Infrastructure section's
[AWS deployment guide](/infrastructure/aws).

Budget about an hour for a first run, most of it waiting for AWS.

## Prerequisites

- An AWS account and IAM credentials that can create DynamoDB, Lambda, SQS, SNS,
  S3, AppSync, CloudFront, Cognito, and IAM resources.
- [Pulumi CLI](https://www.pulumi.com/docs/install/) and a Pulumi account (free
  tier) or a self-managed backend.
- Node v22.17.1 and pnpm 10, and a checkout of `reventless-core` bootstrapped
  with `pnpm run setup` from the repo root.
- A GitHub Package Registry token with `read:packages` to install
  `@reventlessdev/*`.

### What it will cost

Everything the shop deploys is pay-per-request and scales to zero: DynamoDB
on-demand tables, Lambda functions, SQS queues, SNS topics, an AppSync API, S3
buckets, a CloudFront distribution, and a Cognito user pool. There is no
always-on instance, cluster, or NAT gateway in this stack.

An idle tutorial deployment therefore costs cents per month, dominated by stored
objects and CloudWatch log retention rather than by the application itself.
Exercising it by hand stays comfortably inside the free tier for most accounts.
The exception is anything you add on top: a custom domain needs a hosted zone,
and a relational store would be always-on.

Pick a region close to you and use it consistently — the example ships
`eu-west-1`; change `aws:region` in the stack configs below if you want another.

## How it's structured

Each plugin and the platform have an `-aws` deployment package:

| Stack | Package | What it deploys |
|---|---|---|
| Platform | `platform-aws/` | Shared AppSync API, admin components, scheduler, Lambda layer, and the host-shell UI on CloudFront |
| Catalog | `catalog-aws/` | Catalog DynamoDB / SQS / Lambda / S3 + its AppSync resolvers |
| Ordering | `ordering-aws/` | Ordering infra + resolvers; depends on Catalog's extension point |

Plugins register their GraphQL schema fragment with the platform **at runtime**,
so the platform is deployed once and plugins deploy independently afterwards.

## Step 1 — Point the stacks at *your* Pulumi org

The checked-in example configs reference the Reventless team's Pulumi org. **You
must change `reventless` to your own Pulumi organization** in the plugin stack
configs, or your deploy will fail looking up a platform stack you don't own.

```yaml
# catalog-aws/Pulumi.alpha.yaml — change "reventless" → "<your-pulumi-org>"
config:
  aws:region: eu-west-1
  platform:stack: <your-pulumi-org>/online-shop-hybrid-platform-aws/alpha
```

```yaml
# ordering-aws/Pulumi.alpha.yaml — change BOTH references
config:
  aws:region: eu-west-1
  platform:stack: <your-pulumi-org>/online-shop-hybrid-platform-aws/alpha
  interstack:
    dependencies:
      - <your-pulumi-org>/online-shop-hybrid-catalog-aws/alpha
```

`platform:stack` and `interstack:dependencies` are Pulumi stack names of the form
`<org>/<project>/<stack>` — the `<stack>` segment matches your branch/environment
(`alpha` here).

## Step 2 — Identity: auto-provision or bring your own

The platform needs a Cognito user pool for authentication. By default it
**auto-provisions a fresh pool** — nothing to configure. To reuse an existing
pool, set its ID (it is read with first-match precedence: env var, then
`Pulumi.local.yaml`, then stack config):

```yaml
# platform-aws/Pulumi.local.yaml  (gitignored; bare key, no namespace prefix)
identityProviderId: eu-west-1_AbCdEfGhI
```

or, for CI: `REVENTLESS_IDENTITY_PROVIDER_ID=eu-west-1_AbCdEfGhI`.

Bringing your own pool also means bringing its **active-role store** — the table
the pool's token trigger reads. Provision both at once, before the first deploy:

```bash
cd platform-aws
pnpm exec provision-identity --provider-id eu-west-1_AbCdEfGhI
```

A stack pointed at a pool whose store is missing fails the deploy. See
[Bringing your own identity provider](/infrastructure/deployment-guide#bringing-your-own-identity-provider)
for why the store belongs to the pool rather than to the stack.

## Step 3 — Check the host-shell version pin

The platform serves the host-shell UI from the published
`@reventlessdev/reventless-host-shell` package, pinned **exactly** in
`platform-aws/package.json`:

```bash
grep host-shell examples/online-shop-hybrid/platform-aws/package.json
```

The pin is exact on purpose — the checked-in value is the version this example
was verified against. Bump it deliberately when a newer host-shell is published,
and run `pnpm install` after changing it.

## Step 4 — Deploy (platform first, then plugins)

```bash
# 1. Build everything from the repo root
pnpm install
pnpm run build

# 2. Platform stack first (it exports the API ID the plugins consume)
cd examples/online-shop-hybrid/platform-aws
pulumi stack init alpha        # first time only
pulumi up --stack alpha

# 3. Catalog (no dependencies)
cd ../catalog-aws
pulumi up --stack alpha

# 4. Ordering (depends on Catalog's extension point)
cd ../ordering-aws
pulumi up --stack alpha
```

Or push to a branch that has matching `Pulumi.<branch>.yaml` files and let the
reusable GitHub Actions workflow (`deploy-manifest.yaml` drives the order) do it.

## Step 5 — Invalidate CloudFront after a host-UI deploy

:::caution Stale UI gotcha
The host-shell UI is uploaded to S3 behind CloudFront under stable file names
(`index.html`, bootstrap entry). A deploy uploads the new bundle but does **not**
invalidate CloudFront, so the browser keeps serving the cached old bundle and a
UI fix can look like it "didn't deploy". After any deploy that changes the host
UI, create an invalidation:

```bash
aws cloudfront create-invalidation --distribution-id <DIST_ID> --paths '/*'
```

Read `<DIST_ID>` from the platform stack outputs (`pulumi stack output`).
:::

## What you have now

Run `pulumi stack output --stack alpha` in `platform-aws/` to get the endpoints.
What is now running in your account:

- **The shop, in a browser.** The CloudFront URL serves the host-shell UI, with
  screens generated from the shop's views and commands. Create a category and a
  product, register a customer, place an order — and watch the views update live
  while you do it, over a WebSocket rather than a polling loop.
- **A GraphQL API.** The AppSync endpoint exposes every command as a mutation and
  every view as a query and a subscription, with fields prefixed per plugin
  (`Catalog_…`, `Ordering_…`). Anything the UI can do, your own client can do.
- **Authentication and authorization.** A Cognito user pool guards the API, and
  per-command rules decide which groups may issue what.
  [Test it on AWS](./test-on-aws) shows how to create your first user — a
  freshly auto-provisioned pool has none.
- **Admin views.** The platform's own components report which plugins are
  connected and what schema each contributes.
- **The complete event history**, in DynamoDB tables in your account, in your
  region, readable with ordinary AWS tooling.

Two things are *not* in this deployment, so you know where the edges are: the MCP
endpoint that lets AI assistants drive the application is available on the local
platform only, and no demo data is seeded until you ask for it (see
[Test it on AWS](./test-on-aws)).

## Tearing it down again

Destroy in the reverse of the deploy order — Ordering, then Catalog, then the
platform:

```bash
cd examples/online-shop-hybrid/ordering-aws && pulumi destroy --stack alpha
cd ../catalog-aws                           && pulumi destroy --stack alpha
cd ../platform-aws                          && pulumi destroy --stack alpha
```

Two things will stop a destroy, both on purpose:

**Protected object stores.** Stacks that are not disposable — anything not named
`pr-*`, which includes `alpha` — get their object-store buckets marked protected,
so a stray refactor cannot delete uploaded files. Pulumi names the protected
resource and refuses. Unprotect deliberately, then destroy again:

```bash
pulumi state unprotect --all --stack alpha
```

**Non-empty buckets.** A protected stack's buckets are also created without force
destroy, so S3 refuses to delete a bucket that still holds objects. Empty it
first:

```bash
aws s3 rm s3://<bucket-name> --recursive
```

Then remove the stacks themselves if you are done with them
(`pulumi stack rm alpha` in each package) — but note that this **deletes the
checked-in `Pulumi.alpha.yaml`** alongside the stack. In a git checkout that is a
tracked file; restore it with `git checkout -- Pulumi.alpha.yaml` if you meant to
keep the config.

Check the console for leftovers before you walk away: CloudWatch log groups
outlive the functions that wrote them, and a CloudFront distribution takes a
while to disable.

---

**Next:** [Test it on AWS →](./test-on-aws) — create a user, sign in, seed demo
data, and run a subscription smoke test against the live stack.
