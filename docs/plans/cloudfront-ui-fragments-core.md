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

### 3. Wire `makeUiBundleDistribution` into `catalog-aws`

**Goal:** `pulumi up` on the catalog plugin stack provisions its bundle distribution and feeds the URL back to the lambda.

- Edit `examples/online-shop-hybrid/catalog-aws/src/Plugin.res` (currently auto-generated — decide if regeneration needs to support this or if the file becomes hand-maintained; recommend the latter, with a regen-safe block).
- Call `Plugin_Stack.makeUiBundleDistribution(~pluginId="catalog", ~bundleVersion=…, ~assetsDir="../catalog/ui/dist", ~spaFallback=false)`. The bundleVersion can come from package.json or a hash of the dist directory.
- Set `CATALOG_UI_BUNDLE_URL` on the plugin lambdas as a Pulumi env-var from `distributionUrl`. The lambda code (which reads `process.env.CATALOG_UI_BUNDLE_URL`) is unchanged.
- Export `bundleDistributionUrl` and `bundleBucketName` as Pulumi stack outputs.

**Verify:**
- `pulumi up` provisions S3 + CloudFront, uploads the `ui/dist/` files.
- `pulumi stack output bundleDistributionUrl` returns the CloudFront URL.
- Hitting `<bundleDistributionUrl>/remoteEntry.js` returns the federation manifest.
- The catalog plugin lambda's `Plugin_Connected` event payload contains `uiFragments.remoteEntryUrl = <bundleDistributionUrl>`.
- The new `Platform_UIFragments` query reflects this.

### 4. Add a host-UI Pulumi program

**Goal:** the host shell from the UI sibling plan has a place to deploy to on AWS.

- Create `examples/online-shop-hybrid/host-ui-aws/` with `Pulumi.yaml`, `Pulumi.alpha.yaml`, `package.json`, `rescript.json`, `src/Main.res`.
- The `Main.res` calls `Plugin_Stack.makeUiBundleDistribution(~pluginId="host-ui", ~bundleVersion=…, ~assetsDir="../../../../reventless-ui/host-shell/dist", ~spaFallback=true)`.
- Write a `config.json` to the dist directory *before* upload, containing `apiEndpoint`, `region`, `cognitoUserPoolId`, `cognitoClientId` resolved from a `Pulumi.StackReference` to the platform stack. Stack output names match the platform's outputs.
- Export `hostShellUrl` as a stack output.

**Verify:**
- `pulumi up` deploys the dist directory + a `config.json` next to `index.html`.
- Visiting `<hostShellUrl>` serves the host shell which then fetches `config.json` and queries `Platform_UIFragments` against the platform's `domainApiEndpoint`.

### 5. Refine cache behaviours in `makeUiBundleDistribution`

**Goal:** cached `remoteEntry.js` doesn't pin the entire UI to a stale build.

- In `reventless/reventless-aws/src/Plugin_Stack.res`, add a second `orderedCacheBehavior` for `pathPattern: "/remoteEntry.js"` (and `/index.html` for SPA shells) using AWS managed `CachingDisabled` (`4135ea2d-6df8-44a3-9df3-4b5a84be39ad`) or a custom policy with very short TTL.
- Optionally short TTL on `/config.json` too.

**Verify:** uploading a new build with the same `bundleVersion` still surfaces the new manifest on next request without manual invalidation.

### 6. Document the flow and replicate to ordering

**Goal:** the catalog template generalises; `ordering/ui/` mirrors it; `docs/guides/` explains.

- Copy `examples/online-shop-hybrid/catalog/ui/` to `examples/online-shop-hybrid/ordering/ui/`, swap names. Wire `ordering-aws/src/Plugin.res` the same as catalog.
- Write `reventless-core: docs/guides/ui-fragments-deployment.md` covering: plugin `ui/` layout, vite-plugin-federation config, `makeUiBundleDistribution` call site, env-var injection, host-ui-aws Pulumi program, `config.json` runtime contract.

**Verify:** following the guide cold, a new plugin gains a working UI fragment.

## Out of scope for this plan

- React shell, AuthProvider, login UI — `reventless-ui: docs/plans/cloudfront-ui-fragments-ui.md` and `reventless-ui: docs/plans/host-ui-login-ui.md`.
- Cognito UserPool, AppSync auth mode flip — `reventless-core: docs/plans/host-ui-login-core.md`.
- Cross-origin CORS hardening — comes naturally if the host and plugin distributions share a parent CloudFront; otherwise a per-plugin CORS allow-listing pass is needed and is deferred.
