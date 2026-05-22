# Plan: Custom Domain for the Host UI Shell

**Date:** 2026-05-22

**Status:** Done — 2026-05-22.

**Analysis:** [docs/analysis/host-ui-custom-domain.md](../../analysis/host-ui-custom-domain.md) — rationale, option comparison, and gotchas live there. This document is the implementation roadmap.

---

## Goal

Replace the host-UI shell's default `*.cloudfront.net` URL with a stack-aware FQDN derived from `(projectName, stackName, baseDomain)`. The framework provisions an ACM certificate (in us-east-1), a CloudFront alias, and a Route53 A-alias record automatically when `baseDomain` + `hostedZoneId` are configured. Without those values the framework keeps today's `cloudfront.net` default — no surprise opt-in.

### FQDN convention

```
stack ∈ prodStacks → "${baseName}.${baseDomain}"
otherwise         → "${baseName}-${stack}.${baseDomain}"
```

Default `prodStacks = ["prod", "main"]`. `baseName` defaults to `Pulumi.getProjectName()` and can be overridden per stack via `hostUiBaseName`.

Examples (with `baseDomain=app.reventless.dev`):
- `online-shop-hybrid-platform/alpha` → `online-shop-hybrid-platform-alpha.app.reventless.dev`
- `online-shop-hybrid-platform/main` → `online-shop-hybrid-platform.app.reventless.dev`
- `online-shop-hybrid-platform/alpha` with `hostUiBaseName=online-shop-hybrid` → `online-shop-hybrid-alpha.app.reventless.dev`

### Non-goals

- Wildcard / BYO certificate path (deferred — see §9 in the analysis).
- Per-plugin UI subdomains (per-plugin SPAs don't ship yet; framework should support them once they do, but no work in this plan).
- Cross-account / delegated-zone provisioning.

---

## Phase 1 — Pulumi bindings in `rescript-pulumi-aws`

New binding modules. Each follows the existing `args: t` + `make` pattern (see `CloudFront_Distribution.res` for the canonical shape).

### 1.1 `Provider.make` (alt-region provider)

Single binding for `new aws.Provider(name, {region})`. Needed because ACM certs consumed by CloudFront must live in `us-east-1` regardless of the rest of the stack.

- File: `rescript/rescript-pulumi-aws/src/Aws_Provider.res` (+ `.resi`).
- Surface: `make(~name: string, ~args: {region: string}, ~opts?: Pulumi.ComponentResource.options) => provider` returning an opaque `provider` type usable as `~opts={provider: Some(provider)}` on downstream resources.
- The framework wraps a single us-east-1 provider in a module-level singleton (`Plugin_Stack` internal); the binding stays generic.

### 1.2 `Acm.Certificate`

- File: `rescript/rescript-pulumi-aws/src/Acm/Acm_Certificate.res` (+ folder `src/Acm/` and umbrella `Acm.res`).
- Required fields: `domainName`, `validationMethod` (string — only `"DNS"` exercised here; `"EMAIL"` is technically valid).
- Read-only outputs needed downstream: `arn`, `domainValidationOptions: array<{domainName, resourceRecordName, resourceRecordType, resourceRecordValue}>`.

### 1.3 `Acm.CertificateValidation`

- File: `rescript/rescript-pulumi-aws/src/Acm/Acm_CertificateValidation.res`.
- Required: `certificateArn: Output.t<string>`, `validationRecordFqdns: Output.t<array<string>>`.
- Output: `certificateArn` (resolved-after-issued — the framework uses this to gate `viewerCertificate`).

### 1.4 `Route53.Record`

- File: `rescript/rescript-pulumi-aws/src/Route53/Route53_Record.res` (+ umbrella `Route53.res`).
- Two record shapes the framework needs:
  - **Plain DNS record** (used for cert validation): `{zoneId, name, type_, ttl, records: array<string>}`.
  - **Alias record** (used for the FQDN → distribution mapping): `{zoneId, name, type_, aliases: array<{name, zoneId, evaluateTargetHealth}>}`.
- The two shapes are mutually exclusive in the Pulumi API but conveniently expressed as two optional-field records in one ReScript type — match Pulumi's wire shape (`records?` vs `aliases?`).

### 1.5 Verification

- `pnpm --filter rescript-pulumi-aws run build` compiles clean.
- Add a smoke `src/example/Example_CustomDomain.res` showing the four new bindings composed (cert + validation + alias record on a fictitious distribution). Not deployed; pure compile-time exercise.

---

## Phase 2 — `Plugin_Stack.makeUiBundleDistribution` accepts `~customDomain`

### 2.1 Extend the public signature

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
  ~customDomain: option<customDomain>=?,   // NEW
)
```

When `customDomain` is `None`, behavior is unchanged (today's `cloudfrontDefaultCertificate: true`). When `Some({fqdn, hostedZoneId})`:

1. Resolve a module-level us-east-1 `Aws_Provider` singleton (lazy `ref<option<provider>>` keyed by `"us-east-1"` so multiple UI bundles in the same stack share one provider).
2. Create `Acm_Certificate` with `~opts={provider: Some(usEast1Provider)}` and `domainName=fqdn`, `validationMethod="DNS"`.
3. Read `cert.domainValidationOptions[0]`; create one `Route53_Record` for DNS-01 validation (typed `CNAME`, `ttl=60`, `records=[resourceRecordValue]`, `name=resourceRecordName`).
4. Create `Acm_CertificateValidation` referencing the cert ARN and the validation record's FQDN.
5. Set `aliases=[fqdn]` and `viewerCertificate={acmCertificateArn: validatedCert.certificateArn, sslSupportMethod: "sni-only", minimumProtocolVersion: "TLSv1.2_2021"}` on the existing distribution.
6. Create `Route53_Record` alias: `{zoneId: hostedZoneId, name: fqdn, type_: "A", aliases: [{name: distribution.domainName, zoneId: "Z2FDTNDATAQYW2", evaluateTargetHealth: false}]}`.
7. Return `https://${fqdn}` as `distributionUrl` (instead of `https://${distribution.domainName}`).

### 2.2 Resource naming

Cert + alias + validation record names must be **stable across deploys** — no `bundleVersion` interpolation. Use:

- `${pluginId}-domain-cert`
- `${pluginId}-domain-cert-validation`
- `${pluginId}-domain-validation-record` (one per validation entry; suffix with index if multi-SAN — single-name certs only emit one)
- `${pluginId}-domain-alias`

The shared us-east-1 provider is named `"us-east-1"` (single instance per stack).

### 2.3 Verification

- `pnpm --filter reventless-aws run build` compiles clean.
- No existing test relies on a specific `distributionUrl` shape — searched `tests/` for `cloudfront.net` and `distributionUrl` to confirm before edit.

---

## Phase 3 — Auto-derive FQDN in `Platform.deployPlatform`

### 3.1 New `Util_LocalConfig` keys

Add to [`reventless/reventless-aws/src/util/Util_LocalConfig.res`](../../../reventless/reventless-aws/src/util/Util_LocalConfig.res):

| Config key | Env var | Default |
|---|---|---|
| `hostUiBaseDomain` | `REVENTLESS_HOST_UI_BASE_DOMAIN` | `None` |
| `hostUiHostedZoneId` | `REVENTLESS_HOST_UI_HOSTED_ZONE_ID` | `None` |
| `hostUiBaseName` | `REVENTLESS_HOST_UI_BASE_NAME` | `Pulumi.getProjectName()` |
| `hostUiProdStacks` | `REVENTLESS_HOST_UI_PROD_STACKS` (CSV) | `["prod", "main"]` |

Follow the existing precedence ladder used for `cognitoUserPoolId`: env var → `Pulumi.local.yaml` sidecar → `Pulumi.<stack>.yaml`.

### 3.2 Compute `customDomain` at call site

In `Platform.res`, before constructing the host UI bundle:

```rescript
let customDomain = switch (
  Util_LocalConfig.get("hostUiBaseDomain"),
  Util_LocalConfig.get("hostUiHostedZoneId"),
) {
| (Some(bd), Some(hz)) =>
  let stack = Pulumi.Pulumi.getStackName()
  let baseName = Util_LocalConfig.get("hostUiBaseName")
    ->Option.getOr(Pulumi.Pulumi.getProjectName())
  let prodStacks = Util_LocalConfig.get("hostUiProdStacks")
    ->Option.map(s => s->String.split(",")->Array.map(String.trim))
    ->Option.getOr(["prod", "main"])
  let fqdn = prodStacks->Array.includes(stack)
    ? `${baseName}.${bd}`
    : `${baseName}-${stack}.${bd}`
  Some({Plugin_Stack.fqdn, hostedZoneId: hz})
| _ => None
}
```

Pass `customDomain` into the `makeUiBundleDistribution` call. Downstream consumers (`hostShellUrl` stack export at [Platform.res:1487](../../../reventless/reventless-aws/src/Platform.res#L1487), host-shell `config.json`) consume the new pretty URL transparently.

### 3.3 Verification

- Unit test for the FQDN derivation logic (pure function — extract `Util_HostUiDomain.deriveFqdn(~baseName, ~stack, ~baseDomain, ~prodStacks)` and test cases: `("p", "alpha", "d", ["prod","main"]) → "p-alpha.d"`, `("p", "main", "d", default) → "p.d"`, `("p", "production", "d", ["production"]) → "p.d"`).
- `pnpm --filter reventless-aws test` green.

---

## Phase 4 — CI workflow + GitHub Actions variables

### 4.1 Repo variables (one-time)

Add three repo-level **variables** (not secrets — none are sensitive) to this repo's GitHub Actions settings:

- `HOST_UI_BASE_DOMAIN` (e.g. `app.reventless.dev`)
- `HOST_UI_HOSTED_ZONE_ID` (e.g. `Z01234…`)
- `HOST_UI_PROD_STACKS` — optional, only if the team uses non-default prod names

### 4.2 Wire through `deploy-reventless-aws.yml`

In [`.github/workflows/deploy-reventless-aws.yml`](../../../.github/workflows/deploy-reventless-aws.yml), add the three env vars to the `deploy-platform` and `deploy-plugins` jobs next to `REVENTLESS_COGNITO_USER_POOL_ID`:

```yaml
env:
  REVENTLESS_HOST_UI_BASE_DOMAIN: ${{ inputs.host-ui-base-domain }}
  REVENTLESS_HOST_UI_HOSTED_ZONE_ID: ${{ inputs.host-ui-hosted-zone-id }}
  REVENTLESS_HOST_UI_PROD_STACKS: ${{ inputs.host-ui-prod-stacks }}
```

### 4.3 Wire through `deploy-online-shop-hybrid.yml`

Caller workflow forwards the values from `vars.`:

```yaml
with:
  host-ui-base-domain: ${{ vars.HOST_UI_BASE_DOMAIN }}
  host-ui-hosted-zone-id: ${{ vars.HOST_UI_HOSTED_ZONE_ID }}
  host-ui-prod-stacks: ${{ vars.HOST_UI_PROD_STACKS }}
```

### 4.4 Verification

- Workflow lints clean (`gh actions list-workflows` resolves all referenced inputs).
- Trial deploy of `online-shop-hybrid` to alpha picks up the new vars; FQDN appears in the `hostShellUrl` stack output.

---

## Phase 5 — Documentation

### 5.1 `docs/guides/ui-fragments-deployment.md`

Extend the "What `platform-aws` provisions" section: list the cert + Route53 records as conditional resources, explain when they're created (presence of `baseDomain` + `hostedZoneId`), document the prod-stack stripping rule.

### 5.2 `docs/guides/deployment-guide.md`

Add `hostUiBaseDomain`, `hostUiHostedZoneId`, `hostUiBaseName`, `hostUiProdStacks` to the per-instance overrides table. Cross-link to the analysis for the domain-ownership / multi-tenancy discussion.

### 5.3 Sample-config discipline

Per the multi-tenancy note (analysis §6.4), example stack configs in this repo must **not** ship with `hostUiBaseDomain` set — the Reventless team's `app.reventless.dev` belongs in CI repo variables only. Verify `examples/*/Pulumi.*.yaml` are clean before commit.

---

## Phase 6 — End-to-end verification

Sequence on the alpha stack first:

1. Set the three repo variables.
2. Push a no-op change to `alpha`; let CI deploy.
3. Inspect Pulumi outputs: `hostShellUrl` should now be `https://<project>-alpha.app.reventless.dev`.
4. DNS-resolve the FQDN; check TLS handshake succeeds (`curl -I https://<fqdn>`).
5. Load the SPA in a browser; confirm AppSync calls + login still work (host-shell config.json + Cognito redirect URLs are independent of the SPA URL — verify anyway).
6. Trigger an invalidation (`aws cloudfront create-invalidation --paths "/*"`) — known gotcha from `reference_ui_deploy_cloudfront_stale_cache` memory; CloudFront would otherwise serve stale `index.html`.

Then, if a prod-named stack exists or is being created:

7. Create a `prod` Pulumi stack (or rename alpha to `main` — destroy/replace per analysis §10 gotcha #3).
8. Confirm FQDN is `<project>.app.reventless.dev` with no stack segment.
9. Same TLS + SPA + invalidation checks.

---

## Effort estimate

| Phase | Effort |
|---|---|
| 1 — Pulumi bindings | 60-90 min |
| 2 — `Plugin_Stack.makeUiBundleDistribution` wiring | 90-120 min |
| 3 — Auto-derive + `Util_LocalConfig` keys + unit tests | 45 min |
| 4 — CI wiring | 15 min |
| 5 — Docs | 30-45 min |
| 6 — End-to-end verification on alpha + one prod-named stack | 60-90 min |
| **Total** | **~5-7 hours** |

---

## Open follow-ups

- Per-plugin UI subdomains — picked up once per-plugin SPAs ship. The plumbing in this plan is reusable: `Plugin_Stack.makeUiBundleDistribution` already takes `~customDomain`, so the per-plugin call site just needs its own FQDN computation.
- Wildcard / BYO cert path (analysis §9) — switch when cert proliferation starts hurting (>~50 stacks).
- Hosted-zone auto-discovery via `aws.route53.getZone({name: baseDomain})` (analysis §6.4) — drops one config value at the cost of a deploy-time API call. Defer until config burden is felt.

---

## Cross-references

- [docs/analysis/host-ui-custom-domain.md](../../analysis/host-ui-custom-domain.md) — full design analysis.
- [docs/plans/done/host-ui-login-core.md](./host-ui-login-core.md) — prior plan that established the `Util_LocalConfig` + env-var pattern this proposal builds on.
- [docs/plans/done/aws-ui-bundle-spa-deploy.md](./aws-ui-bundle-spa-deploy.md) — prior plan that wrote `makeUiBundleDistribution`; this plan extends its signature.
- [reventless/reventless-aws/src/Plugin_Stack.res](../../../reventless/reventless-aws/src/Plugin_Stack.res) — primary code location.
- [reventless/reventless-aws/src/Platform.res](../../../reventless/reventless-aws/src/Platform.res) — secondary, for FQDN derivation.
- [reventless/reventless-aws/src/util/Util_LocalConfig.res](../../../reventless/reventless-aws/src/util/Util_LocalConfig.res) — new config keys.
- [rescript/rescript-pulumi-aws/src/](../../../rescript/rescript-pulumi-aws/src/) — new ACM / Route53 / Provider bindings.
- [.github/workflows/deploy-reventless-aws.yml](../../../.github/workflows/deploy-reventless-aws.yml) — CI env wiring.
