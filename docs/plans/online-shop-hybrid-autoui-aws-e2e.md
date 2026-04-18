# Plan: Online Shop Hybrid — AutoUI Full AWS E2E (CDN + AppSync)

Extends the local E2E setup with real CDN hosting (S3 + CloudFront) and AppSync subscriptions. Verifies all three scenarios: startup registration, runtime connect, and runtime disconnect.

**Prerequisite plans:**
- `online-shop-hybrid-autoui-devapp.md` (Step 1 complete)
- `online-shop-hybrid-autoui-local-e2e.md` (all steps complete)

---

## Step 1 — CDN provisioning in AWS stacks

### 1.1 `catalog-aws/src/Stack.res`

```rescript
let { distributionUrl, bucketName } =
  Plugin_Stack.makeUiBundleDistribution(
    ~pluginId="Catalog",
    ~bundleVersion=Reventless.PackageVersion.fromCaller(),
  )
```

Export `distributionUrl` as a Pulumi stack output and thread it into `~remoteEntryUrl` in the plugin definition (via `Output.apply` — see `ui-fragment-registry.md` Phase 5).

### 1.2 `ordering-aws/src/Stack.res`

Same pattern for Ordering.

### Checklist

```
Step 1
  [ ] 1.1  Add makeUiBundleDistribution to catalog-aws/src/Stack.res
  [ ] 1.2  Add makeUiBundleDistribution to ordering-aws/src/Stack.res
  [ ] 1.3  Export distributionUrl as Pulumi stack output in both stacks
  [ ] 1.4  Thread distributionUrl → ~remoteEntryUrl in each plugin's Plugin.res
  [ ]      Verify: pulumi preview shows S3 bucket + CloudFront distribution per plugin
```

---

## Step 2 — CI/CD upload step for plugin UI bundles

After Pulumi deploy, upload the built bundle to the S3 bucket and invalidate the CloudFront cache.

```bash
# catalog-ui: build and upload
BUCKET=$(pulumi -C examples/online-shop-hybrid/catalog-aws stack output catalogUiBucketName)
DIST_ID=$(pulumi -C examples/online-shop-hybrid/catalog-aws stack output catalogUiDistributionId)
npm run build -w examples/online-shop-hybrid/catalog-ui
aws s3 sync examples/online-shop-hybrid/catalog-ui/dist/ s3://$BUCKET/ --delete
aws cloudfront create-invalidation --distribution-id $DIST_ID --paths '/*'
```

Add `deploy` scripts to each UI package:

```json
"scripts": {
  "deploy": "npm run build && aws s3 sync dist/ s3://$UI_BUNDLE_BUCKET/ --delete"
}
```

### Checklist

```
Step 2
  [ ] 2.1  Add deploy script to catalog-ui/package.json
  [ ] 2.2  Add deploy script to ordering-ui/package.json
  [ ] 2.3  Document upload + invalidation sequence in examples/online-shop-hybrid/README.md
  [ ]      Verify: distributionUrl serves remoteEntry.js from CloudFront
```

---

## Step 3 — AppSync subscription wiring in dashboard

Update `dashboard/src/GraphQL.res` to use the AppSync endpoint instead of localhost, configured via env var.

```rescript
// Use APPSYNC_ENDPOINT env var; fall back to localhost:4001 for local dev
let endpoint =
  Sys.getenv_opt("APPSYNC_ENDPOINT")
  ->Option.getOr("http://localhost:4001/graphql")
```

Add `aws-amplify` dependency and wire the `onUIFragmentChange` subscription in `App.res`.

### Checklist

```
Step 3
  [ ] 3.1  Add aws-amplify to dashboard/package.json
  [ ] 3.2  Wire onUIFragmentChange subscription in App.res
  [ ] 3.3  Add APPSYNC_ENDPOINT to dashboard/.env.example
  [ ]      Verify: subscription receives events when plugin connects/disconnects
```

---

## Step 4 — End-to-end scenario verification

### Scenario A — Startup registration

1. Deploy both plugins to platform-aws; both connect → `UIFragmentRegistry` has two entries
2. Start dashboard — `fetchUIFragments` returns both manifests; bundles load from CDN
3. SidebarNav shows "Categories" and "Orders"
4. AutoListView renders live data; AutoDetailView renders in detail panel
5. AutoCommandForm submits mutation; list refreshes

### Scenario B — Runtime registration (plugin connects after shell starts)

1. Start dashboard with no plugins running → empty sidebar
2. Deploy and start Catalog → `onUIFragmentChange` fires (`Registered`)
3. Dashboard loads catalog bundle → "Categories" appears without shell reload
4. Same for Ordering

### Scenario C — Runtime deregistration (plugin goes offline)

1. Both plugins registered; stop Catalog → heartbeat timeout → `UIFragmentDeregistered`
2. `onUIFragmentChange` fires (`Deregistered`, pluginId: "Catalog")
3. "Categories" disappears; open catalog panels show offline state

### Checklist

```
Step 4
  [ ] 4.1  Scenario A: startup + AutoListView renders live data from CDN bundle
  [ ] 4.2  Scenario A: AutoDetailView + AutoCommandForm work end-to-end
  [ ] 4.3  Scenario B: runtime registration appears in SidebarNav without reload
  [ ] 4.4  Scenario C: deregistration removes nav entry; panels show offline state
  [ ]      Verify: no duplicate React instances
  [ ]      Verify: remoteEntryUrl in UIFragmentRegistry matches CloudFront URL
```
