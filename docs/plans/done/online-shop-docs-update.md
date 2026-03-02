# Online Shop Documentation Update Plan

## Goal

Update the three Online Shop documentation pages so they accurately reflect the current implementation in `examples/aggregate/` and `examples/dcb/`. Specifically:

1. **Overview page** (`get-started.md`) — describe features common to both implementations
2. **Aggregate-based page** (`aggregate-based.md`) — cover the full feature set of both Catalog and Ordering plugins with code examples using the Product/Catalog domain
3. **DCB-based page** (`dcb-based.md`) — same full coverage using the same Product/Catalog domain (already started, needs Extension Point and Extension sections)

All three files are in `packages/doc/docs-online-shop/`.

---

## What Is Currently Missing

### Overview page gaps
- No mention of cross-plugin communication (Extension Points and Extensions) as a common feature of both implementations
- No mention that both implementations track product demand via the Ordering extension point
- No mention of the Platform abstraction (in-memory vs AWS) as a common pattern

### Aggregate-based page gaps
The implementation section only covers Product aggregate, ProductsReadModel, ProductsProjections, and an incomplete CatalogPlugin. Missing:
- `ProductDemand` aggregate (driven by Ordering's OrdersExtensionPoint)
- `ProductDemandReadModel` and `ProductDemandProjections`
- `ProductsExtensionPoint` (outbound EP: Catalog → Ordering)
  - `ProductsExtensionPointSpec.res` — the EP's stable public API
  - `ProductsExtensionPointMapping.res` — maps Product events to EP events
- `OrdersExtension` (inbound: Catalog subscribes to Ordering's EP)
  - `OrdersExtensionPointSpec.res` — local copy of Ordering's EP spec
  - `OrdersExtension.res` — maps EP events to ProductDemand commands
- Full `CatalogPlugin.res` (including EP and extension wiring)
- Feature tables for the Catalog plugin are incomplete (missing ProductDemand, EP, Extension)
- Ordering plugin feature tables need cross-plugin integration rows

### DCB-based page gaps
The implementation section covers EventLog, AddProduct, UpdateProductPrice, ProductsView, and an incomplete CatalogPlugin. Missing:
- `RecordProductDemand` StateChangeSlice (demand tracking driven by Ordering's EP)
- `ProductDemandView` StateViewSlice
- `ProductsExtensionPoint` — `ProductsExtensionPointSpec.res` + `ProductsExtensionPointMapping.res`
- `OrdersExtension` — `OrdersExtensionPointSpec.res` + `OrdersExtension.res` (with DCB adapter)
- Full `CatalogPlugin.res` (including demand, EP, and extension wiring)
- Plugin 1 (Catalog) feature tables missing ProductDemand chapter

---

## Step-by-Step Changes

### Step 1 — Update `get-started.md` (Overview)

Add a new **"Common Features"** section between "Implementations" and "Comparing the Two Approaches".

Content to add:
- **Platform abstraction**: Both use `Make(Platform: Platform.T)` — the same plugin code runs in-memory (for tests) or on AWS with no logic changes
- **Cross-plugin communication**: Both use Extension Points (outbound published API) and Extensions (inbound subscription). Catalog publishes a `ProductsExtensionPoint` and subscribes to Ordering's `OrdersExtension`
- **Demand tracking**: Both plugins react to `ItemOrdered` / `ItemOrderCancelled` events from Ordering's extension point to maintain a product demand count — this is a concrete cross-plugin integration example visible in both implementations

### Step 2 — Update `aggregate-based.md` (Aggregate-Based Plugin)

#### 2a. Expand Plugin 1 (Catalog) feature summary

Add rows for:
- `ProductDemand` aggregate — records per-product demand driven by Ordering's EP
- `ProductsExtensionPoint` — outbound API publishing product availability to Ordering
- `OrdersExtension` — inbound subscription to Ordering's EP, routes to ProductDemand

#### 2b. Expand Plugin 2 (Ordering) feature summary

Add rows showing that Ordering has its own EP (`OrdersExtensionPoint`) that Catalog subscribes to, and a `ProductsExtension` that subscribes to Catalog's EP.

#### 2c. Add implementation steps (after existing Step 3: Read Model)

**Step 4: Extension Point**

Show `ProductsExtensionPointSpec.res` and `ProductsExtensionPointMapping.res`:
- `ProductsExtensionPointSpec` defines the stable public API: `name = "Catalog.Products"`, command, event, directive types. The event type translates internal Product events into a stable domain language (`ProductBecameAvailable`, `ProductPriceChanged`) that Ordering can depend on without coupling to Catalog's internal event types.
- `ProductsExtensionPointMapping` maps `Product.ProductAdded` → `ProductBecameAvailable` and `Product.ProductPriceUpdated` → `ProductPriceChanged`

**Step 5: Extension**

Show `OrdersExtensionPointSpec.res` and `OrdersExtension.res`:
- `OrdersExtensionPointSpec` is a local copy of Ordering's EP spec (`name = "Ordering.Orders"`) — Catalog only needs to know the event vocabulary, not Ordering's internals
- `OrdersExtension` maps `ItemOrdered` → `PublishAggregateCommand(productId, RecordDemand(...))` and `ItemOrderCancelled` → `PublishAggregateCommand(productId, RevokeDemand(...))`

**Step 6: Plugin (replace existing Step 4)**

Show the full `CatalogPlugin.res` with all wiring:
- Product and Category aggregates (existing)
- Product and Category read models (existing)
- ProductDemand aggregate + read model (new)
- ProductsExtensionPoint builder with mapping (new)
- OrdersExtension builder (new)

### Step 3 — Update `dcb-based.md` (DCB-Based Plugin)

#### 3a. Expand Plugin 1 (Catalog) feature summary

Add a **ProductDemand** chapter row with:
- `RecordProductDemand` StateChangeSlice
- `ProductDemandView` StateViewSlice

#### 3b. Add implementation steps (after existing step 3: StateViewSlice, before step 4: Plugin)

**Step 4: Extension Point**

Show `ProductsExtensionPointSpec.res` (same as aggregate — the spec is shared/identical) and `ProductsExtensionPointMapping.res`:
- The DCB mapping uses an `Aggregate` adapter module that wraps `CatalogEventLog` so the `ExtensionPointMapping.Make` functor can decode outgoing events
- The mapping logic is the same as in the aggregate approach

**Step 5: Extension**

Show `OrdersExtensionPointSpec.res` (identical to aggregate — shared EP spec) and `OrdersExtension.res`:
- The DCB extension uses an `Aggregate` adapter module that wraps `RecordProductDemand` command type so `ExtensionMapping.Make` can encode outgoing commands
- The mapping logic is the same as in the aggregate approach

**Step 6 (update existing step 4): Plugin**

Show the full `CatalogPlugin.res` with all wiring:
- EventLog (existing)
- All Product and Category StateChangeSlices (existing)
- Product and Category StateViewSlices (existing)
- ProductDemand StateChangeSlice + StateViewSlice (new)
- ProductsExtensionPoint builder (new)
- OrdersExtension builder (new)

---

## Files to Edit

| File | Change |
|---|---|
| `packages/doc/docs-online-shop/get-started.md` | Add "Common Features" section |
| `packages/doc/docs-online-shop/aggregate-based.md` | Expand feature tables; add Extension Point, Extension, and updated Plugin steps |
| `packages/doc/docs-online-shop/dcb-based.md` | Expand Catalog feature table; add Extension Point, Extension, and updated Plugin steps |

No sidebar changes needed — the three pages already exist in the sidebar.

---

## Source Files to Use for Code Examples

All code examples come from the actual implementations:

### Aggregate-Based (in `examples/aggregate/catalog/src/`)
- `Aggregate/Product.res` — Aggregate Spec (already documented)
- `Aggregate/ProductBehavior.res` — Behavior (already documented)
- `ReadModel/ProductsReadModel.res` + `ProductsProjections.res` — Read Model (already documented)
- `ExtensionPoint/ProductsExtensionPointSpec.res` — EP spec (new)
- `ExtensionPoint/ProductsExtensionPointMapping.res` — EP mapping (new)
- `Extension/OrdersExtensionPointSpec.res` — Orders EP spec (new)
- `Extension/OrdersExtension.res` — Extension mapping (new)
- `CatalogPlugin.res` — full Plugin (update existing)

### DCB-Based (in `examples/dcb/catalog/src/`)
- `Plugin/CatalogEventLog.res` — Event Log Spec (already documented)
- `Product/StateChangeSlice/AddProduct.res` — creation slice (already documented)
- `Product/StateChangeSlice/UpdateProductPrice.res` — update slice (already documented)
- `Product/StateViewSlice/ProductsView.res` — view slice (already documented)
- `Product/StateChangeSlice/RecordProductDemand.res` — demand slice (new)
- `Product/StateViewSlice/ProductDemandView.res` — demand view (new)
- `ExtensionPoint/ProductsExtensionPointSpec.res` — EP spec (new)
- `ExtensionPoint/ProductsExtensionPointMapping.res` — EP mapping with DCB adapter (new)
- `Extension/OrdersExtensionPointSpec.res` — Orders EP spec (new)
- `Extension/OrdersExtension.res` — Extension with DCB adapter (new)
- `Plugin/CatalogPlugin.res` — full Plugin (update existing)

---

## Status

- [x] Step 1: Update `get-started.md`
- [x] Step 2: Update `aggregate-based.md`
- [x] Step 3: Update `dcb-based.md`
