# Plan: Online Shop Hybrid — AutoUI Local E2E (Module Federation, no AWS)

Extends the example with `catalog-ui`, `ordering-ui`, and `dashboard` packages. Verifies the full Module Federation bundle loading pipeline locally using dev server URLs instead of CDN. Covers Scenario A (startup registration) only — the AppSync subscription (Scenarios B and C) requires AWS.

**Prerequisite plans:** `online-shop-hybrid-autoui-devapp.md` (Step 1 must be complete)  
**Next plan:** `online-shop-hybrid-autoui-aws-e2e.md`

---

## Goal

Make the dashboard **discover plugin UIs at runtime, not build time**. Today, adding a UI to a plugin means rebuilding the dashboard. After this plan the dashboard is a static shell that discovers whatever plugins are running against the backend and loads their UI bundles on the fly.

### What you can do when it's done

With all four dev servers running locally (see **Startup scripts** below — one command starts everything):

1. **Open `http://localhost:3000`** — the shell loads with an empty sidebar.
2. Within a second or two, the sidebar fills in with a **Catalog** section (Categories list page) and an **Ordering** section (Customers list page). Nothing about these was compiled into the dashboard — they arrive because the backend told the shell "plugin Catalog is running; its UI bundle lives at `http://localhost:5001`".
3. Click **Categories** → a live table renders, populated by a Relay query against the backend. No hand-written React — `AutoListView` derives the columns from the read model's schema.
4. Click a row → a detail panel opens at the `resource-detail` position, auto-rendering the Category aggregate.
5. Submit a command via the auto-generated form → the mutation goes through the backend, the list refreshes.
6. **Stop catalog-ui** (or the backend's catalog plugin) → on next dashboard reload the Catalog section is gone. No shell change.

### What this unlocks after local E2E

- **Phase 2 (AWS e2e plan):** same flow, bundles served from CloudFront, plugin lifecycle managed via AppSync subscriptions. A plugin deploy triggers a sidebar update in running dashboards with no user refresh.
- **Zero-rebuild plugin shipping:** ship a new plugin + its UI bundle to S3/CloudFront; every running dashboard picks it up.
- **Custom panels:** plugins that need hand-written React (not auto-generated) drop the component into their UI bundle, register it at a position (`platform-summary`, `resource-detail`, or a custom string), and it appears in the shell.

The local E2E proves the whole Module Federation + registry pipeline works end-to-end on a laptop without AWS — catching plumbing bugs (Relay singleton, MF shared scopes, registry lifecycle) before they become "works on my deploy but not in prod" bugs.

---

## Dependency strategy — `@reventless/reventless-ui` (dev vs publish)

The three UI packages (`catalog-ui`, `ordering-ui`, `dashboard`) depend on `@reventless/reventless-ui`. We want both:

- **Framework dev mode (this repo, co-located with the sister repo):** edits in the sister repo are immediately visible — no republish, no rebuild.
- **App dev / publish mode:** the example and the published starter install a real versioned package from the registry.

**Chosen pattern — npm `overrides`.** In each UI package's `package.json`, declare the registry version:

```json
"dependencies": {
  "@reventless/reventless-ui": "^1.0.0"
}
```

Then, **at the example root** (`examples/online-shop-hybrid/package.json` or the monorepo root), add an override pointing at the sister repo:

```json
"overrides": {
  "@reventless/reventless-ui": "file:../../../reventless-ui/packages/reventless-ui"
}
```

This mirrors the existing precedent documented in `CLAUDE.md`: the sister repo references `rescript-moment` from this repo via `file:../../../reventless-core/rescript/rescript-moment`. Both repos are assumed to live side-by-side on disk.

**Alternative considered — `npm link`:** zero repo footprint but every fresh clone needs a manual `npm link @reventless/reventless-ui` step. Rejected for friction.

After publish: drop the override (or keep it for dev). App devs `npm install`-ing the example get the real registry version.

---

## Ports

Backend (from Step 1 verification — do not change):
- `4000` — Domain GraphQL (application schema)
- `4001` — Admin / Platform GraphQL (`Platform_UIFragments`, `Platform_Plugins`, …)

UI dev servers (chosen to avoid collision with backend):
- `3000` — `dashboard` (Module Federation host shell)
- `5001` — `catalog-ui` (Module Federation remote)
- `5002` — `ordering-ui` (Module Federation remote)

Platform-in-memory reads `CATALOG_UI_BUNDLE_URL=http://localhost:5001` and `ORDERING_UI_BUNDLE_URL=http://localhost:5002` so `Platform_UIFragments` advertises the dev-server URLs.

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

### Design decision: URL supplied by platform, not plugin (Option B)

`remoteEntryUrl` is a **deployment fact**, not a plugin fact — whoever deploys a plugin knows where its bundle lives; the plugin itself does not. The plugin package stays agnostic; the platform composition root (`platform-in-memory` / `platform-aws`) picks the URL.

Considered and rejected: placing an `Env.res` in each plugin package reading a hardcoded env var name (e.g. `CATALOG_UI_BUNDLE_URL`). This couples plugins to deployment config, forces an `Env.res` convention on every UI-bearing plugin, and makes "same plugin, two deployments" awkward.

**Chosen:** the generator extends `make` with an optional `~uiBundleUrl=?: string` parameter. When present, the generated `make` calls `Plugin_Builder.makeAutoUIManifest(~remoteEntryUrl=url, ...)` and passes the result as `~uiFragments=Some(manifest)`. When absent, no fragments are registered. Platform composition reads its env/config once and passes the URL per plugin.

### 1.1 Extend generator (reventless-spec/generate-plugin)

Generated `CatalogPlugin.Plugin.Make(Platform).make` becomes:

```rescript
let make = (~uiBundleUrl=?) => {
  let uiFragments = uiBundleUrl->Option.map(url =>
    Plugin_Builder.makeAutoUIManifest(
      ~remoteEntryUrl=url,
      ~name="Catalog",
      ~aggregates=[module(CategoryAggregate)],
      ~readModels=[module(CategoriesReadModelMaker)],
      ~readModelPositions=["platform-summary"],
      ~aggregatePositions=["resource-detail"],
    )
  )
  Platform.Plugin.make(
    ~name="Catalog",
    ...
    ~pluginStructure=pluginStructure,
    ~uiFragments?,
  )
}
```

Positions remain fixed strings (`"platform-summary"`, `"resource-detail"`) — they are a UI contract shared with the dashboard shell, not a deployment concern.

### 1.2 Update platform composition roots

`platform-in-memory/src/Platform.res` reads env vars and passes them when wiring plugins:

```rescript
let catalogUiBundleUrl = Sys.getenv_opt("CATALOG_UI_BUNDLE_URL")
let orderingUiBundleUrl = Sys.getenv_opt("ORDERING_UI_BUNDLE_URL")

CatalogPlugin.Plugin.Make(Platform).make(~uiBundleUrl=?catalogUiBundleUrl)
OrderingPlugin.Plugin.Make(Platform).make(~uiBundleUrl=?orderingUiBundleUrl)
```

`platform-aws` follows the same pattern, passing a Pulumi stack output instead of an env var.

### Checklist

```
Step 1 ✅
  [x] 1.1  Extend generate-plugin to emit ~uiBundleUrl=? param on make, and wire
           makeAutoUIManifest with positions ["platform-summary"] / ["resource-detail"]
           (reventless/reventless-spec/src/generator/Codegen.res — emitted only when
           plugin has aggregates or readModels; otherwise make stays `() =>`)
  [x] 1.2  Regenerate catalog and ordering Plugin.res — both now have
           make = (~uiBundleUrl=?) with conditional makeAutoUIManifest wiring
  [x] 1.3  platform-in-memory wraps plugins in CatalogMaker/OrderingMaker that
           read CATALOG_UI_BUNDLE_URL / ORDERING_UI_BUNDLE_URL from process.env
           and forward via ~uiBundleUrl=?. PluginMaker module type unchanged
           (make: unit => component) — wrapper pattern avoids breaking other
           example platforms (aggregates, dcb) whose generated Plugin.res still
           has `let make = ()`.
  [x]      Verified:
           - Env vars set: Platform_UIFragments returns 2 entries with correct
             remoteEntryUrl, panels at "platform-summary" and "resource-detail"
             (Catalog.Categories.list, Catalog.Category.detail, Ordering.Customers.list,
             Ordering.Customer.detail)
           - Env vars unset: Platform_UIFragments returns empty edges
           - Root build: zero warnings
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
    "dev": "vite --port 5001",
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
  [ ]      Verify: bun run dev starts on port 5001; remoteEntry.js accessible;
           { pages, panels } contain correct fragmentIds for Categories
```

---

## Step 3 — `ordering-ui` package

Identical structure to `catalog-ui`, port 5002, imports from `@reventlessdev/online-shop-hybrid-ordering`.

### Checklist

```
Step 3
  [ ] 3.1  Create ordering-ui/package.json (port 5002)
  [ ] 3.2  Create ordering-ui/rescript.json
  [ ] 3.3  Create ordering-ui/vite.config.mjs
  [ ] 3.4  Create ordering-ui/src/Index.res
  [ ]      Verify: dev starts on port 5002; fragmentIds for Orders + Customer correct
```

---

## Step 4 — `dashboard` package

New package at `examples/online-shop-hybrid/dashboard/`. Module Federation host shell. ReScript source, Vite MF host config.

For local runs, queries `Platform_UIFragments` at `http://localhost:4001/graphql` (admin server) — no AppSync.

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

### Design: GraphQL client is Relay (Apollo removed)

The dashboard uses **Relay** for all GraphQL data. Apollo was previously removed from the UI stack, so Relay is the only supported client. Panels and pages inside loaded bundles use Relay fragments/hooks against the same Relay environment the shell creates — they do not instantiate their own client.

**Implications for the bundle contract:**

- Panels and pages must be pure React components that use `react-relay` hooks (`useFragment`, `useLazyLoadQuery`, `usePreloadedQuery`, `useMutation`). They do not own a Relay environment.
- The shell provides a single `RelayEnvironmentProvider` at the root. Loaded fragments use `useRelayEnvironment()` if they need direct access.
- `relay-runtime` and `react-relay` must be marked `singleton: true` in both the host and every remote's MF `shared` config — otherwise duplicate instances break the `__RELAY_ENV__` identity check at runtime.
- Relay compiler artifacts for the dashboard's queries live next to the `.res` sources (or in a `__generated__` folder). For bundles, each remote runs its own Relay compiler step during its own `vite build`.

### Source files (ReScript)

| File | Purpose |
|------|---------|
| `src/Main.res` | React entry — creates Relay env, wraps App in `RelayEnvironmentProvider`, mounts. |
| `src/RelayEnv.res` | `makeEnvironment()` — builds `Environment` with `Network.create(fetchFn)` pointing at the platform's admin GraphQL endpoint (`http://localhost:4001/graphql` for local, AppSync URL for AWS). |
| `src/GraphQL.res` | Typed Relay queries: `UIFragmentsQuery` (fetches `Platform_UIFragments` edges/node on startup). Subscriptions (for AWS) live alongside. |
| `src/Registry.res` | `loadRemoteBundle(remoteEntryUrl, scope, module)` — dynamic Module Federation container init (`__federation_method_setRemote`, `__federation_method_getRemote`), returns the bundle's exported `{ panels, pages }`. Memoises by URL so a second call is a no-op. |
| `src/App.res` | Top-level layout. On mount, issues `UIFragmentsQuery` via `useLazyLoadQuery`. For each returned entry, calls `Registry.loadRemoteBundle` and then `PanelRegistry.register` / `PageRegistry.register` from `@reventless/reventless-ui`. Renders `<SidebarNav />` + `<MainContent />` using the merged registry state. |

### Component responsibilities

**`Main.res`**
```rescript
let env = RelayEnv.makeEnvironment(~graphqlUrl="http://localhost:4001/graphql")
ReactDOM.Client.createRoot(rootEl)
  ->ReactDOM.Client.Root.render(
    <ReactRelay.RelayEnvironmentProvider environment=env>
      <App />
    </ReactRelay.RelayEnvironmentProvider>
  )
```

**`RelayEnv.res`** — thin wrapper over `relay-runtime`'s `Environment`, `Network`, `Store`, `RecordSource`. The fetch function POSTs `{ query, variables }` to `graphqlUrl`. No auth for local; AWS variant will add a Cognito/JWT header.

**`GraphQL.res`** — defines the startup query:
```graphql
query UIFragmentsQuery {
  Platform_UIFragments(first: 100) {
    edges {
      node {
        pluginId
        remoteEntryUrl
        panels { fragmentId title positions requiredAccess }
        pages  { fragmentId title menuEntry { label icon group sortOrder } requiredAccess }
      }
    }
  }
}
```
Used by `App.res` via `useLazyLoadQuery`. In AWS mode, a companion `UIFragmentsSubscription` subscribes to `onUIFragmentChange`.

**`Registry.res`** — the only non-trivial piece. Uses `@originjs/vite-plugin-federation`'s runtime API:
```rescript
let loadRemoteBundle = async (~remoteEntryUrl, ~scope, ~exposedModule) => {
  // 1. Register the remote with the federation runtime if not already
  federationRuntime.setRemote(scope, {url: remoteEntryUrl, format: "esm"})
  // 2. Dynamically import the exposed module
  let container = await federationRuntime.getRemote(scope, exposedModule)
  // container.default is { panels: array<panelDefinition>, pages: array<pageDefinition> }
  container.default
}
```
Keep a `Dict<scope, Promise>` cache so repeated startup calls dedupe.

**`App.res`** — startup effect reads the query result and fans out:
```rescript
@react.component
let make = () => {
  let data = useLazyLoadQuery(UIFragmentsQuery.query, ())
  React.useEffect1(() => {
    data.Platform_UIFragments.edges->Array.forEach(async edge => {
      let node = edge.node
      let { panels, pages } = await Registry.loadRemoteBundle(
        ~remoteEntryUrl=node.remoteEntryUrl,
        ~scope=node.pluginId,      // e.g. "Catalog@1.0.0-alpha.19"
        ~exposedModule="./fragments",
      )
      panels->Array.forEach(p => PanelRegistry.register(node.pluginId, p))
      pages->Array.forEach(p => PageRegistry.register(node.pluginId, p))
    })
    None
  }, [data])
  <Layout>
    <SidebarNav />
    <MainContent />
  </Layout>
}
```

`SidebarNav` and `MainContent` come from `@reventless/reventless-ui` and read from the registries.

### Relay compiler

Add a `relay` section to the dashboard's root `package.json`:
```json
"relay": {
  "src": "./src",
  "language": "typescript",
  "schema": "./schema.graphql",
  "artifactDirectory": "./src/__generated__"
}
```

The `schema.graphql` is fetched once from the running admin server (`npx get-graphql-schema http://localhost:4001/graphql > schema.graphql`) and committed. Step 5 verification will include a `npm run relay` step before `npm run dev`.

ReScript-to-Relay binding: since this repo doesn't yet have a ReScript Relay binding, the queries can be defined in `.ts` files under `src/` and called from ReScript via `@module` externals. Alternatively, `rescript-relay` can be added — out of scope for this plan; defaulting to plain TS queries + ReScript externals.

### Checklist

```
Step 4
  [ ] 4.1  Create dashboard/package.json + rescript.json + vite.config.mjs
  [ ] 4.2  Create dashboard/src/GraphQL.res + src/RelayEnv.res — Relay env
           pointed at http://localhost:4001/graphql; UIFragmentsQuery defined
  [ ] 4.3  Create dashboard/src/Registry.res — loadRemoteBundle (dynamic MF import)
  [ ] 4.4  Create dashboard/src/App.res — provider tree + startup effect
  [ ] 4.5  Create dashboard/src/Main.res — React entry
  [ ]      Verify: dev starts on port 3000; shell loads with empty sidebar
```

---

## Step 5 — Startup scripts (one command to run it all)

Four services in four terminals is painful. Wrap them in a single script so a fresh clone can `npm run dev:all` at the example root and see the dashboard within seconds.

### 5.1 Root-level orchestrator — `examples/online-shop-hybrid/package.json`

Add (or extend) the root `package.json` with `concurrently` + `wait-on`:

```json
{
  "name": "@reventlessdev/online-shop-hybrid",
  "private": true,
  "scripts": {
    "dev:all": "concurrently --kill-others-on-fail --names backend,catalog-ui,ordering-ui,dashboard --prefix-colors cyan,yellow,magenta,green 'npm run dev:backend' 'npm run dev:catalog-ui' 'npm run dev:ordering-ui' 'npm run dev:dashboard'",
    "dev:backend": "CATALOG_UI_BUNDLE_URL=http://localhost:5001 ORDERING_UI_BUNDLE_URL=http://localhost:5002 npm run dev -w platform-in-memory",
    "dev:catalog-ui": "wait-on tcp:4001 && npm run dev -w catalog-ui",
    "dev:ordering-ui": "wait-on tcp:4001 && npm run dev -w ordering-ui",
    "dev:dashboard": "wait-on tcp:4001 tcp:5001 tcp:5002 && npm run dev -w dashboard"
  },
  "devDependencies": {
    "concurrently": "^9.1.0",
    "wait-on": "^8.0.1"
  }
}
```

**Why the waits:** the dashboard's startup Relay query hits the admin server on `:4001`, and `loadRemoteBundle` hits the UI dev servers. Starting the dashboard before those are up produces spurious errors on first load. The `wait-on` gates make the sequence deterministic without adding latency once warm.

**`--kill-others-on-fail`:** if any service dies (e.g., backend crashes on an unhandled event), the others tear down too. Avoids orphaned processes holding ports.

### 5.2 Convenience scripts

| Script | What it does |
|---|---|
| `npm run dev:all` | Start all four services with prefixed logs |
| `npm run dev:backend` | Start only the in-memory platform (with UI env vars so `Platform_UIFragments` advertises dev-server URLs) |
| `npm run dev:catalog-ui` / `dev:ordering-ui` | Start only one remote (for focused UI work — the dashboard can still load it if the other remote is running) |
| `npm run dev:dashboard` | Start only the shell (assumes backend + remotes already running) |

Run from `examples/online-shop-hybrid/`:
```bash
cd examples/online-shop-hybrid
npm install      # one-time — resolves the @reventless/reventless-ui override
npm run dev:all  # starts backend + 2 remotes + dashboard; open http://localhost:3000
```

### 5.3 Stop behaviour

`Ctrl+C` in the `dev:all` terminal tears down all four via concurrently's signal forwarding. If any process survives (e.g., tsx spawning a child), the `--kill-others-on-fail` flag handles it. If a port stays wedged: `lsof -ti :4000,4001,5001,5002,3000 | xargs kill -9`.

### Checklist

```
Step 5
  [ ] 5.1  Add dev:all + per-service scripts to examples/online-shop-hybrid/package.json
  [ ] 5.2  Add concurrently + wait-on as devDependencies; npm install
  [ ] 5.3  Document in examples/online-shop-hybrid/README.md (create if missing):
           - one-line summary of what `dev:all` does
           - the Ports table copied from this plan
           - the `npm run dev:all` quickstart
  [ ]      Verify: fresh clone + npm install + npm run dev:all + open localhost:3000
           shows dashboard with Catalog + Ordering sections within ~10s
```

---

## Step 6 — Local E2E acceptance (Scenario A)

Run `npm run dev:all`, open `http://localhost:3000`, walk the "What you can do when it's done" checklist from the Goal section.

### Checklist

```
Step 6
  [ ] 6.1  Dashboard loads; UIFragmentsQuery returns Catalog + Ordering entries
  [ ] 6.2  Both bundles load via Module Federation; SidebarNav shows both groups
  [ ] 6.3  AutoListView renders live data for Categories and Customers
  [ ] 6.4  AutoDetailView renders at "resource-detail" on row selection
  [ ] 6.5  AutoCommandForm submits mutation; list refreshes
  [ ] 6.6  Stop catalog-ui → reload dashboard → Catalog section absent from sidebar
  [ ]      Verify: React DevTools shows a single root (no duplicate React)
  [ ]      Verify: single @reventless/reventless-ui instance (MF singleton scope)
  [ ]      Verify: Network tab — remoteEntry.js from :5001 and :5002 each loaded once
```
