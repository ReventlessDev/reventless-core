---
title: Custom domain for the host UI
---

# Point the deployed host UI at your own domain

By default the platform serves the host-shell SPA at the CloudFront-assigned
`https://<id>.cloudfront.net` URL — functional, but not memorable. When you set a
**base domain you own** plus its **Route53 hosted zone ID**, the framework
auto-provisions a TLS certificate and DNS so the shell is served at a stable,
per-stack hostname instead. This is the journey-E "deploy your app to your own
domain" step, building on [Deploy to your AWS account](/tutorials/deploy-to-aws).

## How the URL is derived

Set the base domain and the framework derives the FQDN from the Pulumi project
and stack:

| Stack | FQDN |
|---|---|
| non-prod (e.g. `alpha`) | `${baseName}-${stack}.${baseDomain}` |
| prod (`main` / `prod`) | `${baseName}.${baseDomain}` — the stack segment is dropped |

`baseName` defaults to the Pulumi **project name**; override it with
`hostUiBaseName`. The set of "prod" stack names defaults to `["prod", "main"]`;
override with `hostUiProdStacks`.

Example with `baseName=online-shop-hybrid` and `baseDomain=app.example.com`:

- `…/alpha` → `online-shop-hybrid-alpha.app.example.com`
- `…/main` → `online-shop-hybrid.app.example.com`

## Configure it

Both `hostUiBaseDomain` **and** `hostUiHostedZoneId` must be set together — if
either is missing, the framework keeps the default `*.cloudfront.net` URL (the
feature is off by default, so forks don't accidentally provision in a domain they
don't own). Values are read with first-match precedence:

| Precedence | Source | Typical use |
|---|---|---|
| 1 | Env var `REVENTLESS_<KEY>` | CI deploys (repo variables) |
| 2 | `Pulumi.local.yaml` (gitignored) | Dev-local override |
| 3 | `platform:<key>` in `Pulumi.<stack>.yaml` | Shared default |

| Config key | Env var | Meaning |
|---|---|---|
| `hostUiBaseDomain` | `REVENTLESS_HOST_UI_BASE_DOMAIN` | The base domain you own, e.g. `app.example.com` |
| `hostUiHostedZoneId` | `REVENTLESS_HOST_UI_HOSTED_ZONE_ID` | Route53 hosted zone ID for that domain |
| `hostUiBaseName` | `REVENTLESS_HOST_UI_BASE_NAME` | Override the FQDN base (defaults to the Pulumi project name) |
| `hostUiProdStacks` | `REVENTLESS_HOST_UI_PROD_STACKS` | CSV of stack names treated as prod (default `prod,main`) |

For CI, set these as **repository variables** (none are secret) and surface them
in the deploy job's `env:` block next to `REVENTLESS_COGNITO_USER_POOL_ID`.

:::caution Don't commit a real base domain
Keep `hostUiBaseDomain` out of checked-in `Pulumi.<stack>.yaml` in shared
templates — a fork that inherits a real domain would try to provision a
certificate in a Route53 zone it doesn't own. Use repository variables or the
gitignored `Pulumi.local.yaml` sidecar instead.
:::

## Prerequisites

- A Route53 **hosted zone you own** for the base domain, in the **same AWS
  account** you deploy to. (Route53 and ACM are account-scoped, so there is no
  accidental cross-account provisioning.)
- IAM permissions to request ACM certificates in **us-east-1** and to create
  records in that hosted zone.

## What the framework provisions

When both values are set, on `pulumi up` the framework creates:

1. An **ACM certificate in us-east-1** (CloudFront only accepts certs from
   us-east-1), validated via DNS.
2. The **Route53 DNS validation records** for that certificate.
3. The CloudFront distribution's `aliases` + `viewerCertificate` (SNI-only,
   TLS 1.2+).
4. A **Route53 A-alias record** pointing the FQDN at the distribution (CloudFront
   global zone `Z2FDTNDATAQYW2`).

The derived `https://${fqdn}` then flows through to the `hostShellUrl` stack
output and the host-shell config.

## Gotchas

- **First deploy is slow.** ACM DNS validation usually completes in 1–5 minutes
  (occasionally up to ~30), and CloudFront takes ~15 minutes to propagate the new
  certificate globally.
- **The cloudfront.net URL stops serving once aliases are set** — it returns 403.
  The `hostShellUrl` output updates on the same deploy, so this is fine unless
  something external cached the old URL.
- **Renaming the project, or promoting a stack across the prod boundary, rewrites
  the URL.** The FQDN derives from project + stack, so renaming the Pulumi project
  or moving `alpha` → `main` destroys and recreates the cert + Route53 records
  under the new FQDN, orphaning the old one.
- **Still invalidate CloudFront after a UI deploy.** Provisioning a custom domain
  doesn't change the [stale-bundle caching gotcha](/tutorials/deploy-to-aws) —
  run `aws cloudfront create-invalidation --paths '/*'` after any host-UI deploy.

## Related

- [AWS deployment guide](./deployment-guide) — the `Per-instance overrides` table
  lists all `hostUi*` keys.
- [UI fragments deployment](./ui-fragments-deployment) — what `platform-aws`
  provisions for the host shell and Auto UI.
