# Plan: Online Shop Hybrid — AutoUI Local E2E (Module Federation, no AWS)

Extends the example with `catalog-ui`, `ordering-ui`, and `dashboard` packages. Verifies the full Module Federation bundle loading pipeline locally using dev server URLs instead of CDN. Covers Scenario A (startup registration) only — the AppSync subscription (Scenarios B and C) requires AWS.

**Prerequisite plans:** `online-shop-hybrid-autoui-devapp.md` (Step 1 must be complete)  
**Next plan:** `online-shop-hybrid-autoui-aws-e2e.md`

---

## Position constants

All three packages use the same position strings. Define them once:

```
platform-summary   — read model list panels in the main content area
resource-detail    — aggregate detail panels
sidebar            — sidebar navigation entries
```

---

## Step 1 — Wire `makeAutoUIManifest` into backend plugins (reventless-core)

For local runs, `remoteEntryUrl` points at the local Vite dev server. Pass it via env var so the same Plugin.res works in both local and AWS contexts.

### `catalog/src/Plugin.res`

```rescript
~uiFragments=Some(
  Plugin_Builder.makeAutoUIManifest(
    ~remoteEntryUrl=Env.catalogUiBundleUrl,
    ~name="Catalog",
    ~aggregates=[module(CategoryAggregate)],
    ~readModels=[module(CategoriesReadModelMaker)],
    ~readModelPositions=["platform-summary"],
    ~aggregatePositions=["resource-detail"],
  )
),
```

### `catalog/src/Env.res`

```rescript
let catalogUiBundleUrl =
  Sys.getenv_opt("CATALOG_UI_BUNDLE_URL")
  ->Option.getOr("http://localhost:4001")
```

Same pattern for `ordering/src/Env.res` with `ORDERING_UI_BUNDLE_URL` / `http://localhost:4002`.

### Checklist

```
Step 1
  [ ] 1.1  Add Env.res to catalog; add ~uiFragments to catalog Plugin.res
  [ ] 1.2  Add Env.res to ordering; add ~uiFragments to ordering Plugin.res
  [ ]      Verify: both plugins compile; pluginDefinition.uiFragments is Some(_) at runtime
```

---

## Step 2 — `catalog-ui` package

New package at `examples/online-shop-hybrid/catalog-ui/`. ReScript source, Vite Module Federation remote.

### `package.json`

```json
{
  "name": "@reventlessdev/online-shop-hybrid-catalog-ui",
  "version": "1.0.0",
  "private": true,
  "scripts": {
    "dev": "vite --port 4001",
    "build": "vite build",
    "build:rescript": "rescript build"
  },
  "dependencies": {
    "@reventless/reventless-ui": "*",
    "@reventlessdev/online-shop-hybrid-catalog": "*"
  },
  "peerDependencies": {
    "react": "^18.3.1",
    "react-dom": "^18.3.1",
    "react-relay": "^18.2.0",
    "relay-runtime": "^18.2.0"
  },
  "devDependencies": {
    "@originjs/vite-plugin-federation": "^1.3.0",
    "rescript": "^12.2.0",
    "vite": "^6.0.0"
  }
}
```

### `rescript.json`

```json
{
  "name": "@reventlessdev/online-shop-hybrid-catalog-ui",
  "sources": [{ "dir": "src", "subdirs": true }],
  "package-specs": { "module": "esmodule", "in-source": true },
  "suffix": ".res.js",
  "bs-dependencies": ["@reventless/reventless-ui", "@reventlessdev/online-shop-hybrid-catalog"]
}
```

### `vite.config.mjs`

```js
import { defineConfig } from 'vite'
import federation from '@originjs/vite-plugin-federation'

export default defineConfig({
  plugins: [
    federation({
      name: 'catalogUi',
      filename: 'remoteEntry.js',
      exposes: { './fragments': './src/Index.res.js' },
      shared: ['react', 'react-dom', 'relay-runtime', 'react-relay', '@reventless/reventless-ui'],
    }),
  ],
  build: { target: 'esnext' },
})
```

### `src/Index.res`

```rescript
open AutoTypes

let { pages, panels } = ReventlessUi.Auto.generateFragments(
  CatalogPlugin.CatalogUiDefinition.definition,
  ~aggregatePositions=["resource-detail"],
)
```

### Checklist

```
Step 2
  [ ] 2.1  Create catalog-ui/package.json
  [ ] 2.2  Create catalog-ui/rescript.json
  [ ] 2.3  Create catalog-ui/vite.config.mjs with Module Federation remote config
  [ ] 2.4  Create catalog-ui/src/Index.res — generateFragments entry point
  [ ]      Verify: bun run dev starts on port 4001; remoteEntry.js accessible;
           { pages, panels } contain correct fragmentIds for Categories
```

---

## Step 3 — `ordering-ui` package

Identical structure to `catalog-ui`, port 4002, imports from `@reventlessdev/online-shop-hybrid-ordering`.

### Checklist

```
Step 3
  [ ] 3.1  Create ordering-ui/package.json (port 4002)
  [ ] 3.2  Create ordering-ui/rescript.json
  [ ] 3.3  Create ordering-ui/vite.config.mjs
  [ ] 3.4  Create ordering-ui/src/Index.res
  [ ]      Verify: dev starts on port 4002; fragmentIds for Orders + Customer correct
```

---

## Step 4 — `dashboard` package

New package at `examples/online-shop-hybrid/dashboard/`. Module Federation host shell. ReScript source, Vite MF host config.

For local runs, queries `Admin_UIFragments` at `localhost:4001` (admin server) — no AppSync.

### `package.json`

```json
{
  "name": "@reventlessdev/online-shop-hybrid-dashboard",
  "version": "1.0.0",
  "private": true,
  "scripts": {
    "dev": "vite --port 3000",
    "build": "vite build",
    "build:rescript": "rescript build"
  },
  "dependencies": {
    "@reventless/reventless-ui": "*",
    "graphql": "^15.10.1",
    "react": "^18.3.1",
    "react-dom": "^18.3.1",
    "react-relay": "^18.2.0",
    "relay-runtime": "^18.2.0"
  },
  "devDependencies": {
    "@originjs/vite-plugin-federation": "^1.3.0",
    "rescript": "^12.2.0",
    "vite": "^6.0.0"
  }
}
```

### `vite.config.mjs`

```js
import { defineConfig } from 'vite'
import federation from '@originjs/vite-plugin-federation'

export default defineConfig({
  plugins: [
    federation({
      name: 'dashboard',
      remotes: {},
      shared: {
        react:                       { singleton: true, requiredVersion: '^18.3.1' },
        'react-dom':                 { singleton: true, requiredVersion: '^18.3.1' },
        'relay-runtime':             { singleton: true },
        'react-relay':               { singleton: true },
        '@reventless/reventless-ui': { singleton: true },
      },
    }),
  ],
  build: { target: 'esnext' },
})
```

### Source files (ReScript)

| File | Purpose |
|------|---------|
| `src/App.res` | Provider tree + startup effect (fetch fragments, load bundles) |
| `src/Registry.res` | `loadRemoteBundle` — dynamic MF container load + register |
| `src/GraphQL.res` | `fetchUIFragments` against localhost:4001 (local) or AppSync (AWS) |
| `src/Main.res` | React entry — mounts App |

### Checklist

```
Step 4
  [ ] 4.1  Create dashboard/package.json + rescript.json + vite.config.mjs
  [ ] 4.2  Create dashboard/src/GraphQL.res — fetchUIFragments against localhost:4001
  [ ] 4.3  Create dashboard/src/Registry.res — loadRemoteBundle (dynamic MF import)
  [ ] 4.4  Create dashboard/src/App.res — provider tree + startup effect
  [ ] 4.5  Create dashboard/src/Main.res — React entry
  [ ]      Verify: dev starts on port 3000; shell loads with empty sidebar
```

---

## Step 5 — Local E2E verification (Scenario A)

```bash
# Terminal 1 — backend (reventless-core)
CATALOG_UI_BUNDLE_URL=http://localhost:4001 \
ORDERING_UI_BUNDLE_URL=http://localhost:4002 \
npm run dev -w examples/online-shop-hybrid/platform-in-memory

# Terminal 2 — catalog-ui
npm run dev -w examples/online-shop-hybrid/catalog-ui     # port 4001

# Terminal 3 — ordering-ui
npm run dev -w examples/online-shop-hybrid/ordering-ui    # port 4002

# Terminal 4 — dashboard
npm run dev -w examples/online-shop-hybrid/dashboard      # port 3000
```

### Checklist

```
Step 5
  [ ] 5.1  Dashboard loads; fetchUIFragments returns Catalog + Ordering entries
  [ ] 5.2  Both bundles load via Module Federation; SidebarNav shows both groups
  [ ] 5.3  AutoListView renders live data for Categories and Orders
  [ ] 5.4  AutoDetailView renders at "resource-detail" on row selection
  [ ] 5.5  AutoCommandForm submits mutation; list refreshes
  [ ]      Verify: no duplicate React instances (React DevTools — single root)
  [ ]      Verify: no duplicate @reventless/reventless-ui instances (singleton MF scope)
```
