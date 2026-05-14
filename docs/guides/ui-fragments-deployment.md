# UI Fragments Deployment

How Reventless serves a browser UI for any deployed platform — locally and on AWS — without each plugin shipping its own React bundle.

For related guides, see:
- [Platform and Plugin Guide](platform-and-plugin-guide.md) — creating platforms and plugins
- [Lambda Deployment](lambda-deployment.md) — AWS Lambda code-asset packaging
- [GraphQL API Guide](graphql-api-guide.md) — how the admin and domain APIs are stitched

---

## 1. Why "Auto UI" Is the Default

A Reventless plugin's schema (aggregates, commands, events, read models) is already discoverable at runtime via two GraphQL queries on the platform's admin API:

| Query | Returns |
|---|---|
| `Platform_UIDefinitions` | Per-plugin metadata: command shapes, read-model schemas, linked entities, search/label fields. |
| `Platform_UIFragments`   | Per-plugin manifest of which `fragmentId`s the plugin contributes, plus an optional `remoteEntryUrl` for federation. |

The host shell (a static SPA shipped from the `reventless-ui` workspace) queries both at boot, then renders a list, detail, or panel view for each fragment **generically** — using the schemas alone. No plugin code touches the browser unless the plugin explicitly opts into a custom UI bundle.

This is Auto UI: the same code path works on the in-memory platform and on AWS.

---

## 2. fragmentId Naming

Every plugin auto-derives its fragment manifest via `Plugin.makeAutoUIManifest`. The derived names are:

| Source | fragmentId | Renders as |
|---|---|---|
| Read model `<Name>` | `<Plugin>.<Name>.list` | Page + summary panel |
| Aggregate `<Name>`  | `<Plugin>.<Name>.detail` | Detail panel |

E.g. the catalog plugin declares `aggregates=[CategoryAggregate]` and `readModels=[CatalogActivity, Categories]`. Its auto-derived manifest contains:

- panels: `Catalog.CatalogActivity.list`, `Catalog.Categories.list`, `Catalog.Category.detail`
- pages: `Catalog.CatalogActivity.list`, `Catalog.Categories.list`

The host shell reads these strings and decides which rendered view goes where. The plugin author writes zero UI code.

---

## 3. Local Development

```
┌────────────────────┐         ┌────────────────────┐
│ vite dev           │ ◀────── │ Auto UI components │
│ (host shell SPA)   │         │ from reventless-ui │
└─────────┬──────────┘         └────────────────────┘
          │ GraphQL: Platform_UIFragments + Platform_UIDefinitions
          ▼
┌────────────────────┐
│ in-memory platform │
│ (Node process)     │
└────────────────────┘
```

The in-memory platform exposes the admin GraphQL server on a local port. Run `vite dev` in the host shell with `public/config.json` pointing at it. Plugin lifecycle events (`Connected`, `UIFragmentRegistered`) flow through the in-process bus, the QueryDb is seeded synchronously, and the queries resolve immediately.

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
- A `config.json` `BucketObject` whose **content** is derived from Pulumi `Output`s at deploy time — `apiEndpoint`, `region`, `authMode`. No rebuild of the host shell SPA is needed when these change.
- Stack output `hostShellUrl`.

The host shell SPA itself is built upstream by `reventless-ui`'s `host-shell` package. `assetsDir` points at its `dist/` directory.

`platform-aws` takes a versioned npm dependency on `@reventlessdev/reventless-host-shell`. The published tarball already contains pre-built `dist/` output (the package's `prepublishOnly` hook runs `vite build` before publish, and `dist/` is in its `files` allowlist). With the repo's `node-linker=hoisted` (`.npmrc`), `pnpm install` places it under the repo-root `node_modules/`, so deploy paths work in CI without checking out the sibling `reventless-ui` repo. To upgrade the shell, bump the dependency version in `platform-aws/package.json` and re-run `pulumi up`.

### `config.json` contract

```json
{
  "apiEndpoint": "https://<id>.appsync-api.<region>.amazonaws.com/graphql",
  "region": "<aws region>",
  "authMode": "anonymous"
}
```

`authMode` is `"anonymous"` today. When Cognito wiring lands (`host-ui-login-core.md`), the platform stack will write `"cognito"` with the user-pool and client IDs.

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
