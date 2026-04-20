# Plan: Online Shop Hybrid — AutoUI via Dev-App (Simplest Path)

Verifies the full AutoUI rendering pipeline — real GraphQL, real data, AutoListView/AutoDetailView — against the in-memory platform. Uses the existing `dev-app` directly; no Module Federation, no UIFragmentRegistry, no CDN.

**Prerequisite plans:** none  
**Next plan:** `online-shop-hybrid-autoui-local-e2e.md`

---

## What this demonstrates

- AutoListView and AutoDetailView rendering live data from a running in-memory backend
- AutoCommandForm submitting real mutations

What it does NOT demonstrate: runtime bundle loading, UIFragmentRegistry, CDN, Module Federation.

---

## Component → AutoUI mapping

| Folder pattern | AutoUI role |
|---|---|
| `*/Aggregate/` | Commands (state is internal — not queryable) |
| `*/ReadModel/` | List/detail view |
| `*/StateViewSlice/` | List/detail view — DCB equivalent of ReadModel |
| `*/StateChangeSlice/` | Commands (independent — not linked to a specific view) |

ReadModel and StateViewSlice are the queryable components — they project state into a table and expose it via a GraphQL field. Aggregates and StateChangeSlices are write-side only; their state is internal and never exposed as a query. StateChangeSlices are independent command handlers — not coupled to any StateViewSlice.

---

## Step 1 — Implement `Plugin_Builder.makeAutoUIDefinition` and wire into generator

`makeAutoUIDefinition` constructs a `Reventless.Plugin.uiDefinition` value from a plugin's component modules. It should never be called manually — the generator emits `let uiDefinition` in the generated `Plugin.res` using the component lists it already has.

### 1.1 Implement `Plugin_Builder.makeAutoUIDefinition`

`makeAutoUIManifest` already exists in `Plugin_Builder.res` for the UIFragmentRegistry/CDN path. `makeAutoUIDefinition` is a new, separate function for the dev-app path. Its return type must be defined in reventless-core — `Plugin_Builder` cannot import from the UI repo.

```rescript
let makeAutoUIDefinition = (
  ~name: string,
  ~aggregates: array<module(ReventlessInfra.Aggregate.T with type api = api)>=[],
  ~readModels: array<module(ReventlessInfra.ReadModel.T with type api = api and type role = role)>=[],
  ~stateViewSlices: array<module(ReventlessInfra.StateViewSlice.T)>=[],
  ~stateChangeSlices: array<module(ReventlessInfra.StateChangeSlice.T)>=[],
): Reventless.Plugin.uiDefinition
```

Define `Reventless.Plugin.uiDefinition` in the core package (analogous to `uiFragmentManifest`). Extracts per component type:
- `readModel` / `stateViewSlice` — `Spec.name` → queryField, `Spec.stateSchema` → schema
- `aggregate` / `stateChangeSlice` — `Spec.name`, command variants from `Spec.commandSchema`

`~stateViewSlices` and `~stateChangeSlices` are independent — there is no coupling between them in the definition.

### 1.2 Update `generate-plugin` to emit `let uiDefinition`

The generator already knows `~name`, `~aggregates`, `~readModels`, `~stateViewSlices`, and `~stateChangeSlices`. Add to the generated `Plugin.res` output:

```rescript
let uiDefinition = Plugin_Builder.makeAutoUIDefinition(
  ~name="Catalog",
  ~aggregates=[module(CategoryAggregate)],
  ~readModels=[module(CategoriesReadModelMaker)],
  ~stateViewSlices=[module(ProductsViewSlice), module(ProductDemandViewSlice)],
  ~stateChangeSlices=[module(AddProduct), module(ChangeProductName), module(ChangeProductPrice), module(ChangeProductDescription), module(RecordProductDemand)],
)
```

### Checklist

```
Step 1  (implemented as pluginStructure/makePluginDefinition — same purpose, different naming)
  [x] 1.1  Define Reventless.Plugin.uiDefinition type in reventless-core (analogous to uiFragmentManifest)
  [x] 1.2  Implement Plugin_Builder.makeAutoUIDefinition using ReventlessInfra .T module types
  [x] 1.3  Update generate-plugin (Codegen.res) to emit `let uiDefinition` in Plugin.res
  [x] 1.4  Regenerate catalog/src/Plugin.res and ordering/src/Plugin.res
  [x]      Verify: pluginStructure contains stateViewSlices and stateChangeSlices entries (confirmed in Plugin.res)
```

---

## Step 2 — Expose `Platform_UIDefinitions` via admin API

The dev-app fetches UI definitions from the running platform at startup — no plugin imports, no config file. The platform stores each plugin's `uiDefinition` at registration time and exposes it via a new admin query.

### 2.1 Store `uiDefinition` in platform on plugin connect

Extend `Platform.Plugin.make` to accept `~uiDefinition: option<Reventless.Plugin.uiDefinition>` sourced from the generated `let uiDefinition` in `Plugin.res`. Store it alongside the plugin registration in `Platform_Admin`.

### 2.2 Add `Platform_UIDefinitions` admin query

New query on the admin server (port 4001) returning the UI definitions for all currently connected plugins:

```graphql
query {
  Platform_UIDefinitions {
    pluginId
    readModels        { name queryField schema }
    stateViewSlices   { name queryField schema }
    stateChangeSlices { name commands { name schema } }
    aggregates        { name commands { name schema } }
  }
}
```

`readModels` and `stateViewSlices` are the queryable components — they have `queryField` and `schema`. `aggregates` and `stateChangeSlices` are write-side only — no `queryField`, just `name` and `commands`. StateChangeSlices are not linked to any StateViewSlice.

### Checklist

```
Step 2
  [x] 2.1  Extend Platform.Plugin.make with ~uiDefinition; store at registration
  [x] 2.2  Implement Platform_UIDefinitions admin query
  [x]      Verify: dev-app renders all plugin components without any hardcoded imports

Verification (npm run dev:full -w examples/online-shop-hybrid/platform-in-memory)
  [x]      dev-app loads at localhost:5173; SidebarNav shows Catalog and Ordering groups
  [x]      AutoListView renders live categories, orders, products
  [x]      AutoDetailView renders in detail panel on row selection
  [x]      AutoCommandForm submits mutation; list refreshes
```

