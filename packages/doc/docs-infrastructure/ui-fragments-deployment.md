# UI Fragments Deployment

How Reventless serves a browser UI for any deployed platform — locally and on AWS — without each plugin shipping its own React bundle.

For related guides, see:
- [Platform and Plugin Guide](/app/platform-and-plugin-guide) — creating platforms and plugins
- [Lambda Deployment](lambda-deployment.md) — AWS Lambda code-asset packaging
- [GraphQL API Guide](/app/graphql-api-guide) — how the admin and domain APIs are stitched

---

## 1. Why "Auto UI" Is the Default

A Reventless plugin's schema (aggregates, commands, events, read models) is already discoverable at runtime via two GraphQL queries on the platform's admin API:

| Query | Returns |
|---|---|
| `Platform_ComponentDefinitions` | Per-plugin metadata: command shapes, read-model schemas, linked entities, search/label fields. |
| `Platform_UIFragments`   | Per-plugin manifest of which `fragmentId`s the plugin contributes, plus an optional `remoteEntryUrl` for federation. |

The host shell (a static SPA shipped from the `reventless-ui` workspace) queries both at boot, then renders a list, detail, or panel view for each fragment **generically** — using the schemas alone. No plugin code touches the browser unless the plugin explicitly opts into a custom UI bundle.

This is Auto UI: the same code path works on the local platform and on AWS.

---

## 2. fragmentId Naming

Every plugin auto-derives its fragment manifest via `Plugin.makeAutoUIManifest`. The derived names are:

| Source | fragmentId | Renders as |
|---|---|---|
| Read model `<Name>` | `<Plugin>.<Name>.list` | Page + summary panel |
| Aggregate `<Name>`  | `<Plugin>.<Name>.detail` | Detail panel |

E.g. the ordering plugin declares `aggregates=[CustomerAggregate]` and `readModels=[Customers]`. Its auto-derived manifest contains:

- panels: `Ordering.Customers.list`, `Ordering.Customer.detail`
- pages: `Ordering.Customers.list`

The host shell reads these strings and decides which rendered view goes where. The plugin author writes zero UI code.

---

## 3. Local Development

```
┌────────────────────┐         ┌────────────────────┐
│ vite dev           │ ◀────── │ Auto UI components │
│ (host shell SPA)   │         │ from reventless-ui │
└─────────┬──────────┘         └────────────────────┘
          │ GraphQL: Platform_UIFragments + Platform_ComponentDefinitions
          ▼
┌────────────────────┐
│ local platform │
│ (Node process)     │
└────────────────────┘
```

The local platform exposes the admin GraphQL server on a local port. Run `vite dev` in the host shell with `public/config.json` pointing at it. Plugin lifecycle events (`Connected`, `UIFragmentRegistered`) flow through the in-process bus, the QueryDb is seeded synchronously, and the queries resolve immediately.

No CDN, no S3, no bundle distributions. The host shell rebuilds itself on save like any Vite app.

---

## 4. AWS Deployment

```
┌────────────────────────┐ index.html + assets + config.json
│ CloudFront (host-ui)   │ ◀───────────────────────────────────────────────┐
│ + S3 bucket            │                                                 │
└──────────┬─────────────┘                                                 │
           │                                                               │
           │ browser fetch:                                                 │
           │  /index.html (no-cache)                                        │
           │  /config.json (no-cache)                                       │
           │  /assets/*.<hash>.js (long cache)                              │
           ▼                                                                │
┌────────────────────────┐  GraphQL: Platform_UIFragments + …             ┌─┴─────────────────────┐
│ Host shell SPA in      │ ──────────────────────────────────────────────▶│ AppSync admin API     │
│ browser                │                                                 │ (platform-aws stack)  │
└────────────────────────┘                                                 └───────────────────────┘
```

### What `platform-aws` provisions

`Platform.deployPlatform(~hostUiBundle={assetsDir, bundleVersion})` calls `Plugin_Stack.makeUiBundleDistribution` for the static SPA:

- S3 bucket with public access blocked, accessed only via CloudFront OAC.
- CloudFront distribution with `~spaFallback=true` (403/404 → `index.html`).
- Ordered cache behaviors layered on top of the default `CachingOptimized` policy:
  - `/remoteEntry.js`, `/index.html`, `/config.json` use `CachingDisabled` (TTL 0).
  - Hashed `/assets/*.<hash>.js` chunks keep the long-cache default.
- A `config.json` `BucketObject` whose **content** is derived from Pulumi `Output`s at deploy time — `apiEndpoint`, `platformApiEndpoint`, `region`, `authMode`, `cognitoUserPoolId`, `cognitoClientId`, `liveUpdates`, and (when the corresponding resource is provisioned) `domainApiEventsEndpoint` / `platformApiEventsEndpoint` / `clientEventsNamespace` and `geocoderEndpoint`. Deployment *choices* — `viewModes` and anything passed through `shellConfig` — are merged in beside them. No rebuild of the host shell SPA is needed when any of this changes.
- Stack output `hostShellUrl`.

#### Conditional: custom domain

When both `hostUiBaseDomain` and `hostUiHostedZoneId` are configured (env var → `Pulumi.local.yaml` → `Pulumi.<stack>.yaml`), three extra resources are provisioned and the `hostShellUrl` output becomes `https://<derived-fqdn>` instead of the default `*.cloudfront.net`:

- **`aws.acm.Certificate`** in **us-east-1** (CloudFront only consumes us-east-1 certs) covering the derived FQDN, with `validationMethod: "DNS"`. Lives in the same AWS account as the rest of the stack via a module-level us-east-1 `Provider` singleton.
- **`aws.route53.Record`** in the caller's hosted zone for the ACM DNS-01 validation challenge (CNAME, 60s TTL, `allowOverwrite: true`).
- **`aws.acm.CertificateValidation`** — synthetic resource that blocks until ACM marks the cert ISSUED. First deploy typically takes 1-5 minutes; up to ~30 in pathological cases.
- **`aws.route53.Record`** A-alias from the FQDN to the CloudFront distribution, with target zone ID `Z2FDTNDATAQYW2` (CloudFront's fixed global value).
- The CloudFront distribution itself gains `aliases: [fqdn]` and `viewerCertificate: { acmCertificateArn, sslSupportMethod: "sni-only", minimumProtocolVersion: "TLSv1.2_2021" }`.

The FQDN is auto-derived per stack:

```
stack ∈ prodStacks → "${baseName}.${baseDomain}"
otherwise         → "${baseName}-${stack}.${baseDomain}"
```

Defaults: `baseName = Pulumi.getProjectName()`, `prodStacks = ["prod", "main"]`. Both are overridable via `hostUiBaseName` (per-stack vanity) and `hostUiProdStacks` (CSV, e.g. `production,live`).

With `hostUiBaseDomain=app.example.com`:
- `myapp/alpha` → `myapp-alpha.app.example.com`
- `myapp/main` → `myapp.app.example.com` (prod stack — stack segment dropped)
- `myapp/alpha` + `hostUiBaseName=myapp-short` → `myapp-short-alpha.app.example.com`

When either `hostUiBaseDomain` or `hostUiHostedZoneId` is absent the framework keeps today's `*.cloudfront.net` default — no surprise opt-in for forks.

**Important.** The default `*.cloudfront.net` hostname stops accepting requests once `aliases` is set (returns 403). Anything caching or linking to the old URL breaks on the first deploy with a custom domain — fine in practice since `hostShellUrl` is the only known consumer and it flips in the same deploy.

The host shell SPA is consumed as the published
`@reventlessdev/reventless-host-shell` package, whose tarball already contains
built output — `assetsDir` points at it. A deployment therefore needs nothing but
an install, and upgrading the shell means bumping that dependency's version in
your platform package and re-running `pulumi up`. The version is pinned exactly
on purpose: the shell and the schema it renders move together.

### `config.json` contract

```json
{
  "apiEndpoint": "https://<id>.appsync-api.<region>.amazonaws.com/graphql",
  "platformApiEndpoint": "https://<id>.appsync-api.<region>.amazonaws.com/graphql",
  "region": "<aws region>",
  "authMode": "cognito",
  "cognitoUserPoolId": "<aws region>_XXXXXXXXX",
  "cognitoClientId": "<26-char client id>",
  "liveUpdates": true,
  "domainApiEventsEndpoint": "https://<id>.appsync-api.<region>.amazonaws.com/event",
  "platformApiEventsEndpoint": "https://<id>.appsync-api.<region>.amazonaws.com/event",
  "clientEventsNamespace": "client",
  "geocoderEndpoint": "https://<id>.lambda-url.<region>.on.aws/",
  "viewModes": ["map"]
}
```

The first block of keys is always present. The events keys appear only when the stack has an AppSync Events API — `clientEventsNamespace` is a capability gate, and a client hides publish-dependent features (presence, transient chat) when it is absent. `geocoderEndpoint` appears only when `~hostUiBundle` carries a `geocoderPlaceIndex`. `viewModes` (and each mode's flattened options) appears only when `~hostUiBundle` names one.

`authMode: "cognito"` matches the AppSync auth wiring used for host-UI login — every AWS AppSync GraphQL API uses `AMAZON_COGNITO_USER_POOLS` as its primary authenticationType with `AWS_IAM` as the single additional provider for server-to-server lambdas.

`apiEndpoint` and `platformApiEndpoint` are written separately so the host shell can target the platform admin schema independently of plugin-domain queries; in unified-API mode (the default — `Config.splitApi=false`) both keys resolve to the same URL and the SPA treats them interchangeably. `cognitoUserPoolId` / `cognitoClientId` come from `Platform_Stack.resolveCognitoUserPool` (auto-provisioned or BYO via `REVENTLESS_COGNITO_USER_POOL_ID` env var / `Pulumi.local.yaml` / `Pulumi.<stack>.yaml`).

### Wiring it in your stack

```rescript
// examples/online-shop-hybrid/platform-aws/src/Main.res
module Platform = ReventlessAws.Platform.Make()

let default = Platform.deployPlatform(
  ~version=Reventless.PackageVersion.fromCaller(),
  ~hostUiBundle={
    assetsDir: "../../../node_modules/@reventlessdev/reventless-host-shell/dist",
    bundleVersion: Reventless.PackageVersion.fromCaller(),
  },
)
```

`assetsDir` is resolved relative to the directory containing `Pulumi.yaml` (the `platform-aws/` folder). The three `../` traverse up from `platform-aws/` → `online-shop-hybrid/` → `examples/` → repo root, where hoisted `node_modules/` lives. No separate build step is needed — `pnpm install` extracts the published tarball (which already contains `dist/`).

### Choosing what the shell *does*

Most of `config.json` tells the shell where things are. Two `~hostUiBundle` fields tell it what to be:

```rescript
~hostUiBundle={
  viewModes: [Map({})],
  shellConfig: Dict.fromArray([("platformName", JSON.Encode.string("Online Shop"))]),
}
```

**`viewModes`** names the optional view modes the shell loads at boot. Each mode is a separate package with a heavy dependency (maplibre-gl, cytoscape) reached through a dynamic `import()`, so a deployment that names none downloads none — which is exactly why the modes have to be opted into rather than shipped on. It is a closed variant (`Map(mapOptions)` / `Graph(graphOptions)`), not the wire's `array<string>`: a mode is looked up by name in the shell's registry, so a misspelling would type-check, deploy, and produce an app with the feature silently missing. Per-mode options ride on their arm and are flattened onto the wire (`Map({style})` ⇒ `"viewModes": ["map"], "mapStyle": …`), so a style set with the map off cannot be expressed.

Naming `Map` turns on **both** halves of the map feature — the map view mode *and* the map-backed geo-point command input are registered by the same `init` — and it is also what makes a provisioned `geocoderPlaceIndex` reachable, since the shell builds its geocoder client inside the map chunk. A stack that provisions the place index without naming the mode pays for a service no browser can call.

The picker is the **client** path to a geo point, and not the only one: a plugin can also geocode an address nobody pinned, in an `OutboundTranslationSlice` that runs unattended. The two do not collide, and not by luck — the slice's `collect` yields no work item for an event that already carries a point (which is what saves the geocoder request), and the receiving aggregate returns no events for a command that matches state it already holds (which is what survives at-least-once redelivery). Both guards, not either: the first alone is wrong under redelivery, the second alone pays for every duplicate lookup. The place index is therefore shared by a browser and a backend, and `geocoderPlaceIndex` provisions it for both.

**`shellConfig`** is an untyped `dict<JSON.t>` passthrough for keys the shell owns and the framework has no opinion about (`accessTiers`, `platformName`, `assetOrigins`, `uiHintsUrl`). It merges in under the computed keys; a key that collides with one the deploy computes **fails the deploy naming the key**, rather than quietly pointing the app at a different API.

The in-memory platform accepts both fields and ignores them — it serves no `config.json` of its own. Local dev turns a view mode on by editing the host-shell package's `public/config.json`.

### Independent host-ui cadence

The host-shell deployment lives inside `platform-aws` so it reads the platform's API endpoint and Cognito IDs directly — no `Pulumi.StackReference` indirection. Teams that want to deploy the shell on an independent cadence can later extract this into a standalone `host-ui-aws` package; the only change is reading those values from a `StackReference` to `platform-aws` instead.

---

## 5. Opt-in Custom UI (deferred mechanism)

A plugin can replace Auto UI rendering for any (or all) of its fragments by shipping a federation remote — a Vite bundle with a `remoteEntry.js` that the host shell registers at runtime. The seam exists in three places:

1. `Plugin.makeAutoUIManifest`'s `~remoteEntryUrl` argument. Already plumbed; today every plugin passes the platform-supplied default (or none, in which case the plugin is rendered by Auto UI).
2. `Plugin_Stack.makeUiBundleDistribution` — call site for provisioning the plugin's own CloudFront/S3 bundle distribution.
3. A future `plugin.json` `uiBundle` block + generator extension that emits the `makeUiBundleDistribution` call in the generated `*-aws/src/Plugin.res` without hand-edits.

No example currently exercises this path. When a plugin actually needs custom UI, the generator extension lands alongside that first use case (see `cloudfront-ui-fragments-core.md` step 3 — deferred).

The contract the custom remote must satisfy: every `exposes` key must match a `fragmentId` from the manifest. For the catalog plugin that would be `./Catalog.Categories.list`, `./Catalog.Category.detail`, etc.

---

## 6. Operational notes

- **Cache invalidation:** the short-TTL behaviors mean re-deploying the shell or rewriting `config.json` is visible on the next request — no manual CloudFront invalidation needed.
- **Cross-origin:** today's setup serves the host shell and the AppSync API from different origins. The host shell calls AppSync as a CORS request; AppSync responds with `Access-Control-Allow-Origin: *` by default. If a deployment fronts both behind a single CloudFront (custom domain + multiple origins), the CORS concern disappears.
- **Versioning:** `bundleVersion` is part of the S3 prefix — bumping it provisions a fresh bucket layout. Pass a content hash or a semver tag from CI.
