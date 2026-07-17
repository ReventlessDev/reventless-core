# Custom Domain for the Host UI Shell — Analysis

**Status:** Analysis (no implementation steps here — to be lifted into a plan when scheduled)
**Date:** 2026-05-14
**Scope:** Replacing the default `*.cloudfront.net` URL on the host-shell CloudFront distribution with a stack-specific FQDN like `online-shop-hybrid-alpha.app.reventless.dev`. Includes a convention for auto-deriving the FQDN per Pulumi stack so newly-deployed apps get a nice URL with zero per-stack wiring.

---

## TL;DR

- Today the host UI is served at the CloudFront-assigned `https://d123abc.cloudfront.net` (see [Plugin_Stack.res:137-139](../../reventless/aws/src/Plugin_Stack.res#L137-L139) — `cloudfrontDefaultCertificate: true`). Functional but ugly and impossible to remember.
- A custom domain on CloudFront requires four things: a Route53 hosted zone you own, an ACM certificate **in us-east-1** (CloudFront only consumes certs from us-east-1), the distribution configured with `aliases` + `viewerCertificate`, and a Route53 A-alias record pointing the FQDN at the distribution. CloudFront's global hosted zone ID for alias records is the fixed constant `Z2FDTNDATAQYW2`.
- Most of the Pulumi resources needed are **not yet bound in `rescript-pulumi-aws`** — `Acm.Certificate`, `Acm.CertificateValidation`, `Route53.Record`, and `Provider.make` (for the alt-region us-east-1 provider) all need ReScript bindings before any of this compiles.
- Three configuration shapes are viable: (A) hard-code FQDN per stack, (B) auto-derive FQDN from `${projectName}-${stackName}.${baseDomain}` with only the base domain + zone ID configured once globally, (C) hybrid (auto by default, explicit override). **Recommendation: C** — auto-derived covers 95% of deploys with zero ceremony, explicit override stays for the occasional vanity URL.
- **Production stacks drop the stack suffix.** When the Pulumi stack name is `prod` or `main`, the FQDN is `${baseName}.${baseDomain}` (no stack segment); every other stack keeps the `-${stack}` suffix. So `online-shop-hybrid-platform/main` → `online-shop-hybrid-platform.app.reventless.dev`, while `online-shop-hybrid-platform/alpha` → `online-shop-hybrid-platform-alpha.app.reventless.dev`. The set of "prod" stack names is configurable (default `["prod", "main"]`) so teams using `production` or similar can opt in.
- The mechanism is generic — once `Plugin_Stack.makeUiBundleDistribution` takes a custom-domain parameter, every UI bundle it provisions (host shell, per-plugin SPAs) gets the same treatment automatically. No per-app code change in Main.res once the framework default is set.
- Effort estimate: **3-5 hours** including bindings, framework wiring, docs, and verification on one stack. Linear scaling for additional UI bundles is zero because the framework handles them all.

---

## 1. Where things stand today

### 1.1 The current distribution

[`Plugin_Stack.makeUiBundleDistribution`](../../reventless/aws/src/Plugin_Stack.res#L37) creates the bundle's CloudFront distribution with:

```rescript
viewerCertificate: Pulumi.Input.make({
  PulumiAws.CloudFront.Distribution.cloudfrontDefaultCertificate: Pulumi.Input.make(true),
}),
```

No `aliases` field is set, so CloudFront only serves the request at its default `*.cloudfront.net` hostname. The exported `distributionUrl` ([Plugin_Stack.res:199](../../reventless/aws/src/Plugin_Stack.res#L199)) is `https://${distribution.domainName}` — the CloudFront-assigned URL.

That URL flows downstream into:
- `hostShellUrl` stack output ([Platform.res:1487](../../reventless/aws/src/Platform.res#L1487))
- The host-shell `config.json` indirectly (the SPA bootstraps from its own URL via `window.location`, but `apiEndpoint` / `platformApiEndpoint` are AppSync endpoints, not the SPA URL)

### 1.2 What CloudFront needs to serve a custom domain

| Resource | Region | Notes |
|---|---|---|
| `aws.acm.Certificate` | **us-east-1** (mandatory) | Cert with `validationMethod: "DNS"` covering the FQDN |
| `aws.route53.Record` (×N) | — | DNS-01 validation records ACM emits to prove ownership |
| `aws.acm.CertificateValidation` | us-east-1 | Synthetic resource that waits for ACM to mark the cert `ISSUED` |
| `aws.cloudfront.Distribution.aliases` | — | Set to `[fqdn]` |
| `aws.cloudfront.Distribution.viewerCertificate` | — | `{ acmCertificateArn, sslSupportMethod: "sni-only", minimumProtocolVersion: "TLSv1.2_2021" }` |
| `aws.route53.Record` (alias) | — | A-type alias pointing the FQDN at the distribution. Target zone ID is the fixed CloudFront global value `Z2FDTNDATAQYW2` |

us-east-1 is non-negotiable for the cert. The CloudFront API rejects certificate ARNs from any other region (`InvalidViewerCertificate`).

### 1.3 What's missing in our ReScript bindings

A grep of [rescript-pulumi-aws/src](../../rescript/rescript-pulumi-aws/src) shows the current binding surface covers `S3`, `SQS`, `SNS`, `Lambda`, `DynamoDb`, `Cognito`, `CloudFront.Distribution`, `IAM`, `AppSync`, `ECS`, `EC2`, `SES`, `Kinesis`, `Cloudwatch`, `SecretsManager`, plus `AwsNative.AppSync`. **Missing:**

- `Acm.Certificate`, `Acm.CertificateValidation`
- `Route53.Record` (with the `aliases` field shape — the alias-target sub-record is non-trivial)
- `Provider.make` for declaring an alt-region provider instance (only one usage of an alternate region today: `@module("@aws-sdk/credential-provider-node")` in [Util_AppSync_Caller.res](../../reventless/aws/src/util/Util_AppSync_Caller.res), which is an SDK call, not a Pulumi provider)

Adding these bindings is straightforward — they follow the same `args: t` + `make` pattern as existing bindings — but it's prep work that must land before any of the framework wiring compiles.

---

## 2. Goal: every deployed app gets a pretty URL for free

The bar is higher than "make this one stack pretty." The framework should let `Pulumi.up` produce a nice URL for *any* app that hooks into `Platform.deployPlatform` (or `Platform.deployPlugin`), without each app's Main.res hardcoding its own FQDN.

The pieces needed for that:

1. **A base domain owned by the deploying team**, e.g. `app.reventless.dev` (or `app.example.com` for downstream framework users), with a Route53 hosted zone ID known to the framework.
2. **A naming convention** that maps `(project, stack)` → unique FQDN deterministically.
3. **An automatic apply path** that hooks `Plugin_Stack.makeUiBundleDistribution` so every UI bundle in every plugin gets the pretty URL by default.
4. **An explicit override hatch** for stacks that want a vanity URL or to disable the automation.

If the framework reads `(baseDomain, hostedZoneId)` from one well-known source (env var → sidecar → stack config), then **every** new app deployed from this codebase automatically gets a working URL on `pulumi up`. Configuration burden per app drops to zero.

---

## 3. Three configuration shapes

### Option A — Explicit per-stack FQDN (manual)

Each stack's Main.res passes `~hostUiDomain={fqdn, hostedZoneId}` to `Platform.deployPlatform`. Caller-driven.

- **Pro:** maximally explicit; vanity URLs trivial; no convention to remember.
- **Con:** N stacks = N edits; adding a new app means another Main.res to update; the framework never "just works" with a nice URL.

### Option B — Auto-derive from project + stack + base domain (zero per-stack work)

Framework reads two values once: `baseDomain` (e.g. `app.reventless.dev`) and `hostedZoneId`. Then derives the FQDN for every UI bundle:

```
fqdn = stackName ∈ prodStacks
  ? "${projectName}.${baseDomain}"
  : "${projectName}-${stackName}.${baseDomain}"
```

`prodStacks` defaults to `["prod", "main"]` and is configurable (see §3.1). For `online-shop-hybrid-platform/alpha` → `online-shop-hybrid-platform-alpha.app.reventless.dev`; for `online-shop-hybrid-platform/main` → `online-shop-hybrid-platform.app.reventless.dev`.

- **Pro:** Zero configuration per app. Adding a new app, branch, or environment immediately produces a working pretty URL. Prod stacks land on a clean apex-style URL with no stack noise. Predictable from project + stack alone — no lookups needed to find where an env lives.
- **Con:** FQDN includes Pulumi project naming choices, so `online-shop-hybrid-platform-alpha…` rather than the user's preferred `online-shop-hybrid-alpha…`. Renaming a Pulumi project changes the URL (cert + Route53 record get re-created). Long names get long URLs. Renaming a stack from `alpha` to `main` (promotion) also rewrites the cert + Route53 record under the shorter FQDN — by design, but it is a destroy/replace.

### Option C — Auto-derive by default, explicit override per stack (recommended)

Framework auto-derives unless the caller passes `~hostUiDomain={fqdn}` explicitly, in which case the explicit value wins. The `~hostUiDomain` arg becomes optional and accepts a partial record:

```rescript
type hostUiDomain =
  | Auto                           // Default — use project-stack-base convention
  | Custom({fqdn: string})         // Explicit override
  | Disabled                       // Keep cloudfront.net default
```

- **Pro:** Best of both. 95% of deploys get a URL for free. Vanity stays available. Easy to disable entirely (legacy stacks, cost-conscious dev environments).
- **Con:** Three states instead of two; slightly more API surface.

**Recommendation: C, defaulting to `Auto`.** Existing stacks that don't want the change can pass `Disabled` once to keep their cloudfront.net URL.

### 3.1 Prod-stack handling

Auto-derivation special-cases stack names that represent production. When `stackName ∈ prodStacks`, the FQDN drops the `-${stackName}` segment so the URL reads as a clean apex-style hostname (e.g. `online-shop-hybrid-platform.app.reventless.dev`). For every other stack the FQDN keeps `-${stackName}` (`online-shop-hybrid-platform-alpha.app.reventless.dev`).

Default `prodStacks = ["prod", "main"]`. Override via `Util_LocalConfig` key `hostUiProdStacks` (CSV: `REVENTLESS_HOST_UI_PROD_STACKS=production,live`) for teams using different conventions. Same precedence ladder as the other host-UI keys.

`Custom({fqdn})` short-circuits this logic entirely — explicit override always wins.

---

## 4. URL pattern choices (within Option B/C auto-derivation)

The default convention `${projectName}-${stackName}` (with the stack segment dropped for prod stacks) is one of several reasonable shapes. Each trade-off:

| Pattern | Non-prod example | Prod example (`main`/`prod`) | Trade-off |
|---|---|---|---|
| `${projectName}[-${stack}]` | `online-shop-hybrid-platform-alpha` | `online-shop-hybrid-platform` | Mechanical; includes "-platform" suffix from Pulumi project name; prod gets a clean apex-style URL |
| `${stack}.${projectName}` | `alpha.online-shop-hybrid-platform` | `online-shop-hybrid-platform` (stack segment omitted) | Two-segment; reads as a sub-path; nested zones get awkward fast |
| Manifest-derived (`name` in deploy-manifest.yaml) | `online-shop-hybrid-alpha` (where manifest `name: online-shop-hybrid`) | `online-shop-hybrid` | Cleanest URLs; requires the framework to read the manifest at deploy time, which it doesn't today (the manifest is consumed by the GitHub Actions workflow, not by Main.res) |
| Caller-provided prefix override | `${prefix}-${stack}` with prefix set in stack config | `${prefix}` (stack segment omitted) | Combines auto + per-app control; small extra wiring |

A pragmatic middle path: **auto-derive from project + stack by default with the prod-stack stripping rule, allow a `baseName` override in stack config**. So `online-shop-hybrid-platform/alpha` becomes `online-shop-hybrid-platform-alpha.app.reventless.dev` unless `platform:hostUiBaseName: online-shop-hybrid` is set, in which case it becomes `online-shop-hybrid-alpha.app.reventless.dev`. For the same project on stack `main`, the FQDN is `online-shop-hybrid.app.reventless.dev`. Same precedence ladder as `cognitoUserPoolId`: env → sidecar → stack config → derived default.

---

## 5. Source of `baseDomain` and `hostedZoneId`

Both values are essentially per-AWS-account / per-team constants. They almost never change. Three places they could live:

1. **`Util_LocalConfig` keys**: same precedence ladder as `cognitoUserPoolId`. Env var (`REVENTLESS_HOST_UI_BASE_DOMAIN`, `REVENTLESS_HOST_UI_HOSTED_ZONE_ID`, optional `REVENTLESS_HOST_UI_PROD_STACKS`) → `Pulumi.local.yaml` → `Pulumi.<stack>.yaml`. Composes with what's already built.
2. **Dedicated framework config file** at repo root (e.g. `reventless.yaml`). Cleaner for "everyone in this repo deploys to the same base domain"; redundant given the sidecar.
3. **Hardcoded fallback to `null`** = "feature off." If neither is set, framework keeps the cloudfront.net default. No automatic provisioning until the user opts in by setting the base domain.

**Recommendation:** (1) + (3). The sidecar pattern is already used and tested; if the values are absent, the framework silently keeps the old behavior. No surprise opt-in. `hostUiProdStacks` defaults to `"prod,main"` and only needs to be set when a team uses a different convention (`"production,live"` etc.).

---

## 6. Domain ownership & multi-tenancy

`baseDomain` and `hostedZoneId` are **deployer-supplied configuration**, not framework constants. The framework never hardcodes a default — it reads both values from `Util_LocalConfig` (env → sidecar → stack config) at deploy time. The Reventless team and downstream users run the same code path with different values.

### 6.1 Two scenarios, same mechanism

**Reventless team deploying its own examples** (`examples/online-shop-hybrid` etc.):

- The Reventless team owns `reventless.dev` (Route53 zone in the Reventless AWS account).
- Repo-level GitHub Actions variables `HOST_UI_BASE_DOMAIN=app.reventless.dev` + `HOST_UI_HOSTED_ZONE_ID=Z...` flow into the deploy job.
- Framework auto-derives `online-shop-hybrid-platform-alpha.app.reventless.dev` and provisions cert + alias in the Reventless account.
- ACM cert lives in us-east-1 of the same AWS account as the rest of the stack — no cross-account dance.

**Downstream framework user** (e.g. Acme Corp deploying its own app on Reventless):

- Acme owns `acme.com` with a Route53 hosted zone in their AWS account.
- Acme's CI exports `REVENTLESS_HOST_UI_BASE_DOMAIN=app.acme.com` + `REVENTLESS_HOST_UI_HOSTED_ZONE_ID=Z...` (or sets them in `Pulumi.<stack>.yaml`).
- Framework derives `acme-orders-prod.app.acme.com` and provisions in Acme's AWS account.
- Reventless's `reventless.dev` zone is never touched — Acme couldn't reach it anyway (different account).

The natural permission boundary (Route53 + ACM are AWS-account-scoped) means there is no accidental cross-team provisioning even if env vars were misconfigured.

### 6.2 Framework's responsibility

1. **Never hardcode a domain in framework code.** Treat `reventless.dev` as Reventless's *deployment-time choice for its own example apps*, configured the same way downstream users configure theirs.
2. **Default to "feature off"** when no domain is configured — keep the cloudfront.net URL. No surprise opt-in for forks.
3. **Document the protocol, not the values.** Deployment guides should state which env vars exist, what AWS prerequisites the deployer needs (a Route53 zone they own, IAM permissions to issue ACM certs in us-east-1 + create records in that zone), and what URL convention the framework produces. Concrete domain values (`reventless.dev` etc.) belong in deployment-time secrets/variables, never in committed source or sample configs.
4. **Example stack configs in this repo ship without a base domain.** The Reventless team sets the values via GitHub Actions repo variables on this repo; a fork that wants its own demo URL sets different values on its own fork.

### 6.3 Subtleties

**Hosted zone auto-discovery.** `aws.route53.getZone({name: baseDomain})` can resolve the zone ID at deploy time, dropping `hostedZoneId` from config. Reduces config burden to one value but assumes the zone name matches `baseDomain` literally — works if the zone is for `app.acme.com`, surprises users who own `acme.com` and host `app.acme.com` records there. Probably worth supporting both (auto-lookup by default, explicit zone ID override).

**Cross-account / delegated subdomains.** Some orgs keep their public Route53 zone in a "shared services" account and deploy workloads to per-environment accounts. The framework would need a second AWS provider (for the zone account) to write validation + alias records, plus cross-account IAM. Out of scope for v1; documentable as: "if you need this, delegate a subdomain like `app.acme.com` to a hosted zone in the app's own account and point `baseDomain` at the delegated subdomain."

**Shared-apex blast radius.** Any policy applied at the apex (HSTS preload, CAA records, DNSSEC, WAF web ACL on a shared CloudFront) affects every subdomain underneath. If Reventless ever runs customer-facing content on `reventless.dev`, keep framework demo URLs on a dedicated apex (e.g. `demos.reventless.dev`) so demo-only churn can't drag prod with it.

**Template/placeholder discipline in docs.** When deployment guides show example env-var values, use a generic placeholder like `app.example.com` and explicitly call out the Reventless-team-specific values (`app.reventless.dev`) as illustrative of the protocol, not a default to copy. Avoids the failure mode where a fork copy-pastes `reventless.dev` and silently tries to provision in someone else's domain.

---

## 7. Wiring path through the framework

Once bindings exist and `(baseDomain, hostedZoneId)` are sourced from config:

### 7.1 `Plugin_Stack.makeUiBundleDistribution`

Extend the signature:

```rescript
type customDomain = {
  fqdn: string,
  hostedZoneId: string,
}

let makeUiBundleDistribution = (
  ~pluginId,
  ~bundleVersion,
  ~assetsDir=?,
  ~spaFallback=false,
  ~indexDocument="index.html",
  ~customDomain: option<customDomain>=?,    // NEW
)
```

When `customDomain` is `Some({fqdn, hostedZoneId})`:

1. Create a us-east-1 Provider instance (`PulumiAws.Provider.make(~name="us-east-1", ~args={region: "us-east-1"})`). Wrap in a top-level module-level singleton so multiple UI bundles in the same stack share one provider.
2. `Acm.Certificate.make` with `domainName: fqdn`, `validationMethod: "DNS"`, `~opts={provider: Some(usEast1Provider)}`.
3. Read `domainValidationOptions[0].{resourceRecordName, resourceRecordType, resourceRecordValue}` from the cert.
4. `Route53.Record.make` for each validation record (typically just one for a single-name cert; multi-SAN certs have multiple).
5. `Acm.CertificateValidation.make` referencing the cert ARN and validation record FQDNs. This blocks until ACM marks the cert ISSUED.
6. CloudFront distribution gets `aliases: [fqdn]` and `viewerCertificate: { acmCertificateArn: validatedCert.certificateArn, sslSupportMethod: "sni-only", minimumProtocolVersion: "TLSv1.2_2021" }`.
7. `Route53.Record.make` for the A-alias record: `name: fqdn`, `type_: "A"`, `aliases: [{ name: distribution.domainName, zoneId: "Z2FDTNDATAQYW2", evaluateTargetHealth: false }]`.
8. Return `https://${fqdn}` as `distributionUrl` so downstream consumers (the `hostShellUrl` export, `Platform_UIFragments` registration, host-shell `config.json` cross-references) all get the pretty URL.

**Resource naming**: the cert + alias record are stable across deploys, so they must **not** include `bundleVersion` in their Pulumi names (the bucket + asset objects already do; that's correct for cache-busting). Use `${pluginId}-domain-cert`, `${pluginId}-domain-alias`, etc.

### 7.2 `Platform.deployPlatform`

Reads the auto-derived FQDN at the call site, passes through:

```rescript
let baseDomain   = Util_LocalConfig.get("hostUiBaseDomain")
let hostedZoneId = Util_LocalConfig.get("hostUiHostedZoneId")
let baseName     = Util_LocalConfig.get("hostUiBaseName")
                    ->Option.getOr(Pulumi.Pulumi.getProjectName())
let prodStacks   = Util_LocalConfig.get("hostUiProdStacks")
                    ->Option.map(s => s->String.split(","))
                    ->Option.getOr(["prod", "main"])

let customDomain = switch (baseDomain, hostedZoneId) {
  | (Some(bd), Some(hz)) =>
    let stack = Pulumi.Pulumi.getStackName()
    let fqdn = prodStacks->Array.includes(stack)
      ? `${baseName}.${bd}`
      : `${baseName}-${stack}.${bd}`
    Some({fqdn, hostedZoneId: hz})
  | _ => None
}
```

Pass `customDomain` into `Plugin_Stack.makeUiBundleDistribution`. Same pattern for `Platform.deployPlugin`, so per-plugin UI bundles automatically get their own subdomain too (`${pluginId}-${stack}.${baseDomain}` non-prod, `${pluginId}.${baseDomain}` on prod stacks — or whatever per-plugin convention is chosen in §7.3).

### 7.3 Generalization: every UI bundle gets the same treatment

Because `Plugin_Stack.makeUiBundleDistribution` is the single funnel for all UI bundles (host-shell today, per-plugin SPAs tomorrow), wiring `customDomain` once at that function means every caller — including future ones — picks up the auto-domain behavior automatically. No per-call-site duplication.

The exact URL convention can differ per bundle type (in all cases the `-${stack}` segment is dropped when `stack ∈ prodStacks`):
- **Host shell**: `${baseName}-${stack}.${baseDomain}` (non-prod) / `${baseName}.${baseDomain}` (prod) — no plugin component
- **Per-plugin UIs**: `${pluginId}-${baseName}-${stack}.${baseDomain}` (non-prod) / `${pluginId}-${baseName}.${baseDomain}` (prod), or `${pluginId}.${baseName}-${stack}.${baseDomain}` / `${pluginId}.${baseName}.${baseDomain}` for multi-level zones

The two-level zone form (`catalog.online-shop-hybrid-alpha.app.reventless.dev`) is nicer but requires a wildcard cert (`*.online-shop-hybrid-alpha.app.reventless.dev`), one of:
- A SAN cert with all plugin subdomains listed (need to know plugin names at deploy time — works since deploy-manifest already enumerates them)
- A wildcard cert (single `*.online-shop-hybrid-alpha.app.reventless.dev`)
- Per-plugin certs (each provisions its own; works without coordination at the cost of more ACM records)

Single-level (`catalog-online-shop-hybrid-alpha.app.reventless.dev`) is simpler and matches the "every cert is its own thing" model. Acceptable starting point; nested zones can come later.

---

## 8. CI flow

The CI workflow (`deploy-online-shop-hybrid.yml` → `deploy-reventless-aws.yml`) needs **no changes** beyond what's already in place after the recent env-var work:

- `REVENTLESS_HOST_UI_BASE_DOMAIN`, `REVENTLESS_HOST_UI_HOSTED_ZONE_ID`, and optional `REVENTLESS_HOST_UI_PROD_STACKS` flow through `Util_LocalConfig` automatically as long as they're exported in the deploy job's `env:` block.
- Add them next to `REVENTLESS_COGNITO_USER_POOL_ID` in [`deploy-reventless-aws.yml`](../../.github/workflows/deploy-reventless-aws.yml) (deploy-platform + deploy-plugins jobs), sourced from `vars.HOST_UI_BASE_DOMAIN` / `vars.HOST_UI_HOSTED_ZONE_ID` / `vars.HOST_UI_PROD_STACKS` (none are secret).
- The caller workflow forwards them via `inputs:` (or `vars.` directly) since none of the values are sensitive.

Two-to-three repo-level GitHub Actions **variables** (not secrets) cover it: `HOST_UI_BASE_DOMAIN`, `HOST_UI_HOSTED_ZONE_ID`, and `HOST_UI_PROD_STACKS` (optional — only set when the default `"prod,main"` doesn't match the team's naming). Set once; every workflow deploy picks them up.

---

## 9. Special-case: out-of-band cert (BYO ARN, no in-stack provisioning)

If the team prefers to provision one wildcard cert (`*.app.reventless.dev`) by hand or in a separate "domain-aws" stack and reuse it everywhere, the framework can support that with a slightly different signature:

```rescript
type customDomain =
  | InStackCert({fqdn: string, hostedZoneId: string})    // Provision cert inside this stack
  | ByoCert({fqdn: string, hostedZoneId: string, certArn: string})   // External cert
```

`ByoCert` skips steps 1-5 above (no us-east-1 provider needed, no `Acm.Certificate`, no validation dance), drops the cert ARN straight into `viewerCertificate`, and only creates the Route53 alias record. Simpler, faster `pulumi up`, but cert lifecycle is now manual.

Wildcard certs are also re-usable across stacks — one cert covers `*.app.reventless.dev` and serves alpha + beta + main + any per-dev environment without per-stack ACM churn. Trade-off: the wildcard's revocation blast radius is wider.

For a project at this stage (alpha, frequent stack churn), **InStackCert is easier** despite the per-stack cert proliferation. Switch to wildcard ByoCert when cert count starts hurting (>~50, which is well past the ACM soft limits anyway).

---

## 10. Gotchas to know up front

1. **First-deploy propagation delay.** CloudFront takes ~15 minutes to globally propagate `aliases` and `viewerCertificate` changes after the first `pulumi up`. Browsers caching the old cert may see TLS errors during the transition.
2. **ACM validation can race.** `aws_acm_certificate_validation` is a synthetic resource that *waits* for ACM to issue the cert. Most validations succeed in 1-5 minutes but can take up to ~30. Pulumi will sit on the resource until it completes; long deploys are normal on first run.
3. **Renaming the Pulumi project or promoting a stack to prod breaks the URL.** Because the FQDN is derived from `projectName` + `stackName`, changing the project (e.g. renaming `online-shop-hybrid-platform`) destroys and recreates the cert + Route53 records under the new FQDN. The same destroy/replace happens when a stack name crosses the prod boundary — e.g. renaming `alpha` to `main` drops the `-alpha` segment and rewrites the cert under the shorter FQDN. The old FQDN is orphaned with a 404 until the next deploy or manual cleanup. Mitigation if seamless promotion matters: keep a stable stack name across environments and switch DNS at the apex level instead of renaming.
4. **CloudFront's hosted zone ID is fixed.** Pulumi docs sometimes show `${cloudfront_zone_id}` references; in alias records, hardcode `Z2FDTNDATAQYW2` (or `Z2FDTNDATAQYW2` for IPv6 too — same value). This is a global CloudFront constant.
5. **Multi-region certs are not interchangeable.** A cert provisioned in eu-west-1 will not work for CloudFront, even if the rest of the stack is eu-west-1. The alternate-region provider is the only way to get an us-east-1 cert.
6. **DNS-01 validation records are stable across cert renewals.** ACM uses the same validation token name + value for all renewals on the same cert, so the validation Route53 records can stay forever — no rotation needed.
7. **`viewerCertificate` flip drops the cloudfront.net hostname**. The default `*.cloudfront.net` URL stops accepting requests once `aliases` is set (it returns 403). If anything in the world has linked to or cached that URL, it breaks. Should be fine for us — `hostShellUrl` is the only consumer and it'll update on the same deploy.

---

## 11. Effort estimate

| Step | Effort |
|---|---|
| Add Pulumi bindings: `Acm.Certificate`, `Acm.CertificateValidation`, `Route53.Record`, `Provider.make` | 60-90 min |
| Extend `Plugin_Stack.makeUiBundleDistribution` with `~customDomain` + cert provisioning | 90-120 min |
| Auto-derive FQDN in `Platform.deployPlatform` + sidecar/env keys | 30 min |
| `Util_LocalConfig` test coverage for new keys | 20 min |
| Docs (`ui-fragments-deployment.md`, `deployment-guide.md`) | 30-45 min |
| CI workflow env wiring | 15 min |
| End-to-end verification on alpha + one other stack | 60 min |
| **Total** | **~5-6 hours of focused work** |

Linear scaling for additional UI bundles is zero — the framework handles them transparently.

---

## 12. Open questions

- **Subdomain naming for plugin UIs**: single-segment (`catalog-online-shop-hybrid-alpha.app.reventless.dev`) or nested (`catalog.online-shop-hybrid-alpha.app.reventless.dev`)? Nested is nicer but needs a wildcard cert.
- **Per-plugin UIs in scope yet?** Currently only the host-shell is deployed; plugin UIs use Auto UI generated from the GraphQL schema. The framework should support per-plugin custom URLs *when* per-plugin UIs land, but the work doesn't have to happen now.
- **HSTS preload**: if the apex `reventless.dev` is on the HSTS preload list, every subdomain inherits forced HTTPS. Fine for production, mildly annoying for local debugging if you ever need an HTTP fallback. Document but don't gate the work on it.
- **Prod-stack vocabulary**: default `prodStacks = ["prod", "main"]` covers Reventless's own conventions. Should the framework recognise additional canonical names out of the box (`production`, `live`, `release`) so downstream users rarely need to set the override, or is the override hatch enough? Bias toward "small default, easy override" — adding aliases later is non-breaking, removing them is.

---

## Cross-references

- [docs/guides/ui-fragments-deployment.md](../guides/ui-fragments-deployment.md) — current host-shell deployment guide; the "What `platform-aws` provisions" section is what gets extended.
- [docs/guides/deployment-guide.md](../guides/deployment-guide.md) — `Per-instance overrides` section already lists `cognitoUserPoolId`; `hostUiBaseDomain` + `hostUiHostedZoneId` + `hostUiBaseName` would extend the same table.
- [docs/plans/done/host-ui-login-core.md](../plans/done/host-ui-login-core.md) — the prior plan that established the `Util_LocalConfig` + env-var pattern this proposal builds on.
- [reventless/aws/src/Plugin_Stack.res](../../reventless/aws/src/Plugin_Stack.res) — primary code location for the change.
- [reventless/aws/src/Platform.res](../../reventless/aws/src/Platform.res) — secondary, for wiring auto-derived FQDN.
- [rescript/rescript-pulumi-aws/src/](../../rescript/rescript-pulumi-aws/src/) — where the new ACM / Route53 / Provider bindings would go.
