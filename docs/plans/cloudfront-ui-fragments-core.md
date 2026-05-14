# Plan: CloudFront UI Fragments — Core

**Sibling plan:** `reventless-ui: docs/plans/cloudfront-ui-fragments-ui.md` — host shell construction. This plan is the server-side / Pulumi / example side.
**Prerequisite:** none.
**Blocks:** `reventless-ui: docs/plans/cloudfront-ui-fragments-ui.md` step 1 needs the GraphQL query from step 1 below. Otherwise the two plans run in parallel.

## Scope

Everything needed in `reventless-core` to (a) let a plugin's Pulumi stack provision its own CloudFront/S3 bundle distribution, (b) expose `remoteEntryUrl`s to clients via GraphQL, (c) bundle a working example with the `online-shop-hybrid/catalog` plugin, and (d) provide a Pulumi program for the host UI shell deployment itself.

What this plan does **not** cover: building the host shell React app, choosing/installing the federation runtime — see the UI sibling plan.

## Steps

### 1. Add `Platform_UIFragments` GraphQL query

**Goal:** the host UI can fetch the list of plugins with their `remoteEntryUrl`, panels, and pages via a single round-trip.

- In `reventless/reventless-core/src/admin/Platform_UIDefinitionsApi.res` (or a new sibling `Platform_UIFragmentsApi.res` — decide by whether the join into `Platform_UIDefinitions` is cheap), add SDL types `Platform_UIFragmentEntry { pluginId, remoteEntryUrl, panels, pages, registeredAt, updatedAt }` and a query field `Platform_UIFragments: [Platform_UIFragmentEntry!]!`.
- Add the matching JSON encoder mirroring the patterns in `Platform_UIDefinitionsApi.res`.
- AWS adapter: `reventless/reventless-aws/src/adapter/Api/Platform_UIFragments_Lambda.res` scans the `UIFragmentRegistryReadModel` DynamoDB table and returns the list (mirror `Platform_UIDefinitions_Lambda.res`).
- In-memory adapter: extend the in-process query resolver to read from the same `UIFragmentRegistryReadModel`.
- Tests: GWT covering one plugin registered, one updated, one deregistered.

**Verify:** Query `{ Platform_UIFragments { pluginId remoteEntryUrl panels { fragmentId title positions } } }` against both adapters returns identical shape with the existing env-var-set `CATALOG_UI_BUNDLE_URL`.

> **Gate:** UI sibling plan step 1 can start once this is merged.

### 2. Add a `ui/` template to `examples/online-shop-hybrid/catalog/`

**Goal:** a buildable Vite app that produces the `remoteEntry.js` artefact the framework already expects.

- Create `examples/online-shop-hybrid/catalog/ui/` with `package.json`, `vite.config.ts`, `src/main.tsx`, `index.html`.
- Use `@originjs/vite-plugin-federation` (or `@module-federation/vite` — pick whichever the UI sibling plan settles on; coordinate via the UI plan).
- Expose one page (e.g. `CatalogProductList`) and one panel (e.g. `CatalogProductsSummary`). Names must match what `Plugin.makeAutoUIManifest` derives from the aggregate/readmodel names — read `examples/online-shop-hybrid/catalog/src/Plugin.res:49-72`.
- Add a top-level `npm run build:ui` script in the catalog package that runs `vite build` and emits to `ui/dist/`.
- Gitignore `ui/dist/` and `ui/node_modules/`.

**Verify:** `vite preview` in `ui/` serves a working bundle. The UI sibling plan's host shell can load this URL locally via federation.

### 3. Extend `plugin.json` + generator to provision a bundle distribution

**Goal:** `pulumi up` on the catalog plugin stack provisions its bundle distribution and feeds the URL back to the lambda — **without** hand-editing the auto-generated `Plugin.res`. All variability lives in `plugin.json`; the generator emits the `Plugin_Stack.makeUiBundleDistribution(...)` call.

**3a. Extend the `plugin.json` schema (`reventless/reventless-spec/src/generator/Config.res`)**

Add an optional `uiBundle` block parsed into a new `Config.uiBundle` record:

```json
{
  "name": "Catalog",
  "uiBundle": {
    "assetsDir": "../catalog/ui/dist",
    "spaFallback": false
  }
}
```

| Field | Type | Default | Notes |
|---|---|---|---|
| `assetsDir` | string (required to enable UI bundle) | — | Path relative to the `*-aws` package root, pointing at the `vite build` output. Presence of this key is what tells the generator "emit `makeUiBundleDistribution`". |
| `bundleVersion` | string (optional) | content hash of `assetsDir` | Namespaces the S3 prefix. Hash default means most users never set it. |
| `spaFallback` | bool (optional) | `false` | `true` for SPA host shells (rewrites unknown paths to `/index.html`); plugin fragments stay `false`. |
| `envVar` | string (optional) | `<NAME>_UI_BUNDLE_URL` (existing rule, Codegen.res:438-446) | Override only if a plugin needs an unusual env-var name. |

The `Config.res` reader (currently `Config.res:7-8`, `getStrField`/`getIntField` style at `Config.res:78-80`) gains a nested record reader for the `uiBundle` block. Absent block ⇒ `None` ⇒ generator emits today's shape (no behaviour change for existing plugins).

**3b. Extend `renderAwsWrapper` (`reventless/reventless-spec/src/generator/Codegen.res:448`)**

When `config.uiBundle` is `Some(_)`, replace the current
```rescript
@val external uiBundleUrl: option<string> = "process.env.CATALOG_UI_BUNDLE_URL"
…
let make = () => Composition.make(~uiBundleUrl?)
```
with a Pulumi-resource call whose args come straight from the JSON:
```rescript
let { distributionUrl, bucketName } = ReventlessAws.Plugin_Stack.makeUiBundleDistribution(
  ~pluginId="catalog",
  ~bundleVersion=…,        // from plugin.json or computed hash
  ~assetsDir="../catalog/ui/dist",
  ~spaFallback=false,
)
…
let make = () => Composition.make(~uiBundleUrl=distributionUrl)
```
Also emit `bundleDistributionUrl` and `bundleBucketName` as Pulumi stack outputs at the bottom of `Plugin.res` (or push them into the generated `Main.res` instead — pick whichever keeps the functor module clean).

When `config.uiBundle` is `None`, emit the current shape unchanged (back-compat).

**3c. Widen `Composition.make` to accept the Output form**

Today the standard composition's `make` accepts `~uiBundleUrl: option<string>=?` (Codegen.res:609) and uses `Option.map` to build the fragment manifest (Codegen.res:631). With `makeUiBundleDistribution`, the URL is `Pulumi.Output.t<string>` at deploy time.

Change the composition signature to accept `~uiBundleUrl: Pulumi.Output.t<string>=?` (or a sum type that admits both forms if in-memory still passes a plain string). The `makeAutoUIManifest` call already needs a `Pulumi.Output.t<string>` downstream — no change for the in-memory variant if it lifts plain strings via `Pulumi.Output.make`.

**3d. Set the block in `examples/online-shop-hybrid/catalog/src/plugin.json`**

```json
{
  "name": "Catalog",
  "uiBundle": {
    "assetsDir": "../catalog/ui/dist"
  }
}
```

The lambda code (which reads `process.env.CATALOG_UI_BUNDLE_URL`) is unchanged; the generator continues to set that env var, only its *value* now comes from the Pulumi output instead of the deploy-shell env.

**Verify:**
- `pnpm run generate` in `catalog-aws/` produces a `Plugin.res` containing the `makeUiBundleDistribution` call and no manual edits are needed.
- `pulumi up` provisions S3 + CloudFront, uploads the `ui/dist/` files.
- `pulumi stack output bundleDistributionUrl` returns the CloudFront URL.
- Hitting `<bundleDistributionUrl>/remoteEntry.js` returns the federation manifest.
- The catalog plugin lambda's `Plugin_Connected` event payload contains `uiFragments.remoteEntryUrl = <bundleDistributionUrl>`.
- The new `Platform_UIFragments` query reflects this.
- A plugin **without** a `uiBundle` block in `plugin.json` regenerates to byte-identical output as before (back-compat check).

### 4. Extend `platform-aws` to deploy the host UI shell

**Goal:** the host shell from the UI sibling plan has a place to deploy to on AWS.

The host UI isn't a Reventless plugin (no aggregates, no extension points) so the `plugin.json` generator mechanism from step 3 doesn't apply. It also doesn't need its own package: `platform-aws/src/Main.res` already has direct access to the API endpoint, Cognito IDs, etc. as Output values — wiring the host UI distribution there avoids a cross-stack `StackReference` indirection.

- Edit `examples/online-shop-hybrid/platform-aws/src/Main.res` to call `Plugin_Stack.makeUiBundleDistribution(~pluginId="host-ui", ~bundleVersion=…, ~assetsDir="../../../reventless-ui/host-shell/dist", ~spaFallback=true)` after `deployPlatform` returns.
- Write a `config.json` to the dist directory *before* upload, containing `apiEndpoint`, `region`, `cognitoUserPoolId`, `cognitoClientId` — values come directly from the platform's in-scope outputs, no `StackReference` needed.
- Export `hostShellUrl` as a stack output alongside the existing platform exports (`platformApiId`, `domainApiEndpoint`, etc.).

> Production users wanting an independent host-ui deploy cadence (separate team, separate `pulumi up`) can extract this into a `host-ui-aws` package later — it's a one-time refactor that adds a `Pulumi.StackReference` to the platform outputs.

**Verify:**
- `pulumi up` on `platform-aws` deploys the dist directory + a `config.json` next to `index.html`.
- `pulumi stack output hostShellUrl` returns the CloudFront URL.
- Visiting `<hostShellUrl>` serves the host shell which then fetches `config.json` and queries `Platform_UIFragments` against the platform's `domainApiEndpoint`.

### 5. Refine cache behaviours in `makeUiBundleDistribution`

**Goal:** cached `remoteEntry.js` doesn't pin the entire UI to a stale build.

- In `reventless/reventless-aws/src/Plugin_Stack.res`, add a second `orderedCacheBehavior` for `pathPattern: "/remoteEntry.js"` (and `/index.html` for SPA shells) using AWS managed `CachingDisabled` (`4135ea2d-6df8-44a3-9df3-4b5a84be39ad`) or a custom policy with very short TTL.
- Optionally short TTL on `/config.json` too.

**Verify:** uploading a new build with the same `bundleVersion` still surfaces the new manifest on next request without manual invalidation.

### 6. Document the flow and replicate to ordering

**Goal:** the catalog template generalises; `ordering/ui/` mirrors it; `docs/guides/` explains.

- Copy `examples/online-shop-hybrid/catalog/ui/` to `examples/online-shop-hybrid/ordering/ui/`, swap names. Add the same `uiBundle` block to `ordering/src/plugin.json` (with `assetsDir: "../ordering/ui/dist"`) — no edits to `ordering-aws/src/Plugin.res` needed, the generator picks it up.
- Write `reventless-core: docs/guides/ui-fragments-deployment.md` covering: plugin `ui/` layout, vite-plugin-federation config, the `plugin.json` `uiBundle` schema, what the generator emits, how the host UI is folded into `platform-aws`, `config.json` runtime contract.

**Verify:** following the guide cold, a new plugin gains a working UI fragment.

## Out of scope for this plan

- React shell, AuthProvider, login UI — `reventless-ui: docs/plans/cloudfront-ui-fragments-ui.md` and `reventless-ui: docs/plans/host-ui-login-ui.md`.
- Cognito UserPool, AppSync auth mode flip — `reventless-core: docs/plans/host-ui-login-core.md`.
- Cross-origin CORS hardening — comes naturally if the host and plugin distributions share a parent CloudFront; otherwise a per-plugin CORS allow-listing pass is needed and is deferred.
