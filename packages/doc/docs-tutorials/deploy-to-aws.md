---
title: Deploy to your AWS account
sidebar_position: 6
---

# Deploy the online shop to your AWS account

This page takes the **same** hybrid example you ran locally and deploys it to
**your** AWS account with Pulumi. It is the tutorial-sized path; the full
reference (multi-repo, secrets, every config key) lives in the Infrastructure
section's [AWS deployment guide](/infrastructure/aws).

## How it's structured

Each plugin and the platform have an `-aws` deployment package:

| Stack | Package | What it deploys |
|---|---|---|
| Platform | `platform-aws/` | Shared AppSync API, admin components, scheduler, Lambda layer, and the host-shell SPA on CloudFront |
| Catalog | `catalog-aws/` | Catalog DynamoDB / SQS / Lambda / S3 + its AppSync resolvers |
| Ordering | `ordering-aws/` | Ordering infra + resolvers; depends on Catalog's extension point |

Plugins register their GraphQL schema fragment with the platform **at runtime**,
so the platform is deployed once and plugins deploy independently afterwards.

## Prerequisites

- An AWS account + IAM credentials that can create DynamoDB, Lambda, SQS, SNS,
  S3, AppSync, CloudFront, Cognito, and IAM resources.
- [Pulumi CLI](https://www.pulumi.com/docs/install/) and a Pulumi account (free
  tier) or a self-managed backend.
- Node v22.17.1 and pnpm 10.
- A GitHub Package Registry token with `read:packages` to install
  `@reventlessdev/*`.

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
(`alpha` here). Adjust `aws:region` if you don't deploy to `eu-west-1`.

## Step 2 — Cognito: auto-provision or bring your own

The platform needs a Cognito user pool for authentication. By default it
**auto-provisions a fresh pool** — nothing to configure. To reuse an existing
pool, set its ID (it is read with first-match precedence: env var, then
`Pulumi.local.yaml`, then stack config):

```yaml
# platform-aws/Pulumi.local.yaml  (gitignored; bare key, no namespace prefix)
cognitoUserPoolId: eu-west-1_AbCdEfGhI
```

or, for CI: `REVENTLESS_COGNITO_USER_POOL_ID=eu-west-1_AbCdEfGhI`.

## Step 3 — Check the host-shell version pin

The platform serves the host-shell SPA from the published
`@reventlessdev/reventless-host-shell` package, pinned **exactly** in
`platform-aws/package.json`:

```json
"@reventlessdev/reventless-host-shell": "3.0.0-alpha.18"
```

The pin is exact on purpose — bump it deliberately when a newer host-shell is
published. Run `pnpm install` after changing it.

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
The host-shell SPA is uploaded to S3 behind CloudFront under stable file names
(`index.html`, bootstrap entry). A deploy uploads the new bundle but does **not**
invalidate CloudFront, so the browser keeps serving the cached old bundle and a
UI fix can look like it "didn't deploy". After any deploy that changes the host
UI, create an invalidation:

```bash
aws cloudfront create-invalidation --distribution-id <DIST_ID> --paths '/*'
```

Read `<DIST_ID>` from the platform stack outputs (`pulumi stack output`).
:::

---

**Next:** [Test it on AWS →](./test-on-aws) — read the deployed URLs, log in, and
run a subscription smoke test against the live stack.
