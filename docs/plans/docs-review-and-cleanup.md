# Documentation Review & Cleanup Plan

## Summary

A review of all Docusaurus pages in `packages/doc/docs-app/` against the actual example code in `examples/` revealed several categories of issues. The most critical are a fully outdated aggregate walkthrough guide and stale `@decco` annotations scattered across component reference pages.

---

## Issues Found

### 1. Aggregate walkthrough guide uses obsolete behavior API (`aggregate-based-plugin.md`)

**File:** `packages/doc/docs-app/aggregate-based-plugin.md`  
**Lines:** 78–143

The guide teaches four separate behavior functions that no longer exist:

```rescript
// OUTDATED (docs)
let init: Behavior.init<state, Spec.event> = event => ...
let apply: Behavior.apply<state, Spec.event> = (state, event) => ...
let create: Behavior.create<...> = (command, context, error) => ...
let execute: Behavior.execute<...> = (state, command, ...) => ...
```

All current examples use the consolidated API:

```rescript
// CORRECT (examples/online-shop-aggregates/..., examples/online-shop-hybrid/...)
let initialState = ...
let evolve = (state, event) => ...
let decide = (state, command) => ...
```

The component reference `components/aggregate.md` already documents the correct API (lines 190–200) so the explanation text there is fine — only the walkthrough guide is wrong.

**Also in this file (line 248):** Uses `Reventless.Platform.T` — all actual plugin functors use `ReventlessInfra.Platform.T`.

**Fix:** Rewrite the behavior section and code examples. Replace `Reventless.Platform.T` with `ReventlessInfra.Platform.T`.

---

### 2. `plugin-system.md` uses outdated behavior API and inconsistent `Platform.T`

**File:** `packages/doc/docs-app/plugin-system.md`  
**Lines:** 90–136 (behavior code), 184 (Platform.T), 230 (Platform.T)

Same outdated `init`/`apply`/`create`/`execute` pattern in the behavior code examples.

Line 184 uses `Reventless.Platform.T`; line 230 correctly uses `ReventlessInfra.Platform.T`. Both should be `ReventlessInfra.Platform.T`.

**Fix:** Update behavior code examples and standardize `Platform.T` to `ReventlessInfra.Platform.T`.

---

### 3. `@decco` annotations in component reference pages

**All current code uses `@schema` (sury-ppx). `@decco` is a different PPX and not installed.**

Occurrences by file:

| File | Lines | Count |
|------|-------|-------|
| `components/aggregate.md` | 57, 62, 64, 67, 73, 80, 88 | 7 |
| `components/readmodel.md` | 49 | 1 |
| `components/extension.md` | 211, 216, 222 | 3 |
| `components/extensionpoint.md` | 87, 93, 100, 324 | 4 |

**Total: 15 occurrences across 4 files.**

**Fix:** Replace every `@decco` with `@schema` in these files. Verify surrounding code examples compile against current spec.

---

### 4. DCB walkthrough uses `model` parameter name inconsistently (`dcb-based-plugin.md`)

**File:** `packages/doc/docs-app/dcb-based-plugin.md`  
**Lines:** 113, 117, 120, 150, 153, 156, 186, 189, 192

The `evolve` and `decide` functions use `model` as the parameter name for state. All actual DCB examples use `state`. This is not a compilation error but creates confusion — readers will see `model` in the guide and `state` in the examples.

**Fix:** Rename parameter to `state` in all `evolve` and `decide` signatures in this file.

---

### 5. `aggregate.md` Spec code examples use `@decco` but explain `@schema`

**File:** `packages/doc/docs-app/components/aggregate.md`  
**Lines:** 57–88 (spec type block)

The component reference correctly explains `evolve`/`decide` in prose (lines 190–200) but the Spec code block on lines 57–88 still shows `@decco` on all type annotations. The code won't work as written.

(Covered partially under issue 3, but noted here as a split within the same file — upper section is wrong, lower section is correct.)

---

## Scope Not Affected (Verified Correct)

- `dcb-based-plugin.md` — uses `@schema` throughout, correct `ReventlessInfra.Platform.T`, correct `consumedEvent` in StateChangeSlice examples
- `components/statechangeslice.md`, `components/stateviewslice.md` — use `@schema` correctly
- `writing-unit-tests.md` — uses BehaviorTest DSL which is independent of the internal function names; does not describe `init`/`apply` directly
- `rescript-syntax.md` — uses `@schema` correctly

---

## Steps

- [x] **Step 1** — Fix `aggregate-based-plugin.md`:
  - Replace `init`/`apply`/`create`/`execute` behavior section (lines ~78–143) with `initialState`/`evolve`/`decide` pattern, aligned with `examples/online-shop-aggregates/catalog/src/Aggregate/`
  - Replace `Reventless.Platform.T` → `ReventlessInfra.Platform.T` (line 248)

- [x] **Step 2** — Fix `plugin-system.md`:
  - Update behavior code examples (lines ~90–136) to use `initialState`/`evolve`/`decide`
  - Replace `Reventless.Platform.T` → `ReventlessInfra.Platform.T` (line 184)

- [x] **Step 3** — Fix `@decco` → `@schema` in four component reference files:
  - `components/aggregate.md` (7 occurrences + 2 stale prose references to decco)
  - `components/readmodel.md` (1 occurrence)
  - `components/extension.md` (3 occurrences)
  - `components/extensionpoint.md` (4 occurrences)

- [x] **Step 4** — Fix `dcb-based-plugin.md` parameter naming:
  - Renamed `model` → `state` in all `evolve` and `decide` function signatures and bodies (CreateItem, RenameItem, DeleteItem slices)

- [ ] **Step 5** — Verify: build docs site locally (`cd packages/doc && npm run build`) and spot-check all edited pages render without errors (covers round-1 and round-2 changes)

---

## Round 2 Audit — Generic Domain Names & Structural Gaps

A second deep audit compared every code snippet against the actual online-shop example code.
Domain names like `Customer` (generic), `CatalogItem`, `Item`, `CreateItem`, `ItemCreated` are
NOT in any current example and must be replaced with real online-shop entities.

### 6. `aggregate-based-plugin.md` — entire walkthrough uses `CatalogItem` (fictional entity)

All steps use `CatalogItemSpec`, `CatalogItemBehavior`, `CatalogItemReadModelSpec`, etc.

**Real entity to use:** `Product` from `examples/online-shop-aggregates/catalog/src/Aggregate/`.

Additional issues in this file:
- Projection uses `let map = ...` — real code uses `let project = ...` (`ProductsProjections.res`)
- Event mapping Step 5 targets a fictional `NotificationSpec`; real example is `Order_EventMappings.res`
- Plugin assembly is a custom inline wiring; real code is `CatalogPlugin.res`

**Fix:** Replace every code block with the actual `Product.res`, `ProductBehavior.res`,
`ProductsReadModel.res`, `ProductsProjections.res`, `Order_EventMappings.res`, `CatalogPlugin.res`.

---

### 7. `dcb-based-plugin.md` — walkthrough uses `Item` (fictional entity) and phantom EventLog spec

**Issues:**
- "Step 1: Define the Shared Event Log Spec" (`ItemEventLogSpec.res`) does not exist in any real DCB example. In the real code each slice defines its own `consumedEvent` subset; there is no separate shared event log spec file.
- All three slices use `Item`: `CreateItemSpec`, `RenameItemSpec`, `DeleteItemSpec`
- The StateViewSlice uses `ItemViewSpec` with `ItemCreated/ItemRenamed/ItemDeleted`
- Plugin is `ItemCatalogPlugin`
- Architecture diagram names CreateItem/RenameItem/DeleteItem slices

**Real entities to use:** `AddProduct`, `ChangeProductName`, `ProductsView` from
`examples/online-shop-dcb/catalog/src/Product/`.

**Fix:**
- Remove Step 1 (shared EventLog spec); add a prose note explaining the shared log is implicit
- Replace all three StateChangeSlice examples with `AddProduct.res` and `ChangeProductName.res`
- Replace StateViewSlice with `ProductsView.res`
- Replace plugin assembly with simplified `CatalogPlugin.res` (DCB version)
- Update architecture diagram

---

### 8. `components/aggregate.md` — Spec and Behavior examples use fabricated 1990s API

**Spec example (lines 52–92):**  
Uses `module Id = Reventless.Id.String`, `@schema type id = Id.t`, manual `let name`, custom
intermediate types (`type name`, `type address`, `type customer`), and old-style commands like
`Create(customer)`. The `@@reventless.spec` PPX auto-injects all of this now.

**Behavior example (lines 138–179):**  
Uses `open Reventless; open Customer` and patterns from the old API.

**Real code to use:** `Customer.res` and `CustomerBehavior.res` from
`examples/online-shop-aggregates/ordering/src/Aggregate/`.

---

### 9. `components/readmodel.md` — ReadModel Spec example uses fabricated code

Examples at lines 42–67 and 112–117 use `open Customer`, manual `let name`, `module Id`, and
non-`@@reventless.spec` format.

**Real code to use:** `ProductsReadModel.res` from
`examples/online-shop-aggregates/catalog/src/ReadModel/` (uses `@@reventless.spec`).

---

### 10. `components/sideeffecthandler.md` — primary usage example uses fabricated `Customer_EmailNotification`

Lines 65–113 show `Customer.Created({name, email})`, `Customer.AddressChanged(newAddress)`,
`Customer.Deleted` — these events don't exist in any real aggregate.

**Real code to use:** `Order_EmailNotification.res` from
`examples/online-shop-aggregates/ordering/src/SideEffect/`.

The "Common Patterns" section (lines 266–302) also shows a `Order_EmailNotification.res` block
with fabricated events (`Order.Created({customerId, items})`, `Order.Shipped({trackingNumber})`).
These must be replaced with the real `Order.Placed({customerId})` event.

---

### 11. `plugin-system.md` — Full Example section uses `CatalogItem` and `Item`

Lines 89–136 (after the behavior fix) still show `CatalogItemBehavior`, `CatalogItemSpec`,
`CatalogItemReadModelSpec`, and `CatalogItemPlugin`. Parallel to issue 6.
Also: the DCB Full Example section (lines 217–255) uses `ItemEventLogSpec`, `ItemCatalogPlugin`.

**Fix:** Same as issues 6 and 7 — replace with `Product` and real `CatalogPlugin`.

---

### 12. Projection function name mismatch

All projection code in documentation uses `let map = ...` as the mapping function.
All actual examples use `let project = ...` (`ProductsProjections.res`, `CustomersProjections.res`).

Affected files:
- `aggregate-based-plugin.md` (Step 4)
- `plugin-system.md` (Full Example, projection block)

**Fix:** Rename `map` → `project` in all projection code blocks.

---

## Round 2 Steps

- [x] **Step 6** — Fix `aggregate-based-plugin.md`: replaced all `CatalogItem` with real `Product` examples, fixed `map` → `project`, replaced event mapping with `Order_EventMappings`, replaced plugin with `CatalogPlugin`

- [x] **Step 7** — Fix `dcb-based-plugin.md`: removed shared EventLog spec step (replaced with :::info note), replaced `Item` with `Product` using real `AddProduct`/`ChangeProductName`/`ProductsView`, updated architecture diagram

- [x] **Step 8** — Fix `plugin-system.md`: replaced `CatalogItem` and `Item` with real examples in both Full Example sections, fixed `map` → `project`

- [x] **Step 9** — Fix `components/aggregate.md`: replaced fabricated Customer spec/behavior with real `Customer.res` / `CustomerBehavior.res`

- [x] **Step 10** — Fix `components/readmodel.md`: replaced fabricated Customer read model with real `ProductsReadModel.res`; added `CustomersReadModel.res` as index example

- [x] **Step 11** — Fix `components/sideeffecthandler.md`: replaced `Customer_EmailNotification` primary example and fake `Order.Created/Shipped` pattern with real `Order_EmailNotification.res`

---

## References

- Aggregate spec/behavior: `examples/online-shop-aggregates/catalog/src/Aggregate/Product.res` + `ProductBehavior.res`
- Customer spec/behavior: `examples/online-shop-aggregates/ordering/src/Aggregate/Customer.res` + `CustomerBehavior.res`
- Read model: `examples/online-shop-aggregates/catalog/src/ReadModel/ProductsReadModel.res` + `ProductsProjections.res`
- Event mappings: `examples/online-shop-aggregates/ordering/src/EventMappings/Order_EventMappings.res`
- SideEffect: `examples/online-shop-aggregates/ordering/src/SideEffect/Order_EmailNotification.res`
- DCB slices: `examples/online-shop-dcb/catalog/src/Product/StateChangeSlice/AddProduct.res` + `ChangeProductName.res`
- DCB view: `examples/online-shop-dcb/catalog/src/Product/StateViewSlice/ProductsView.res`
- DCB plugin: `examples/online-shop-dcb/catalog/src/Plugin/CatalogPlugin.res`
- Aggregates plugin: `examples/online-shop-aggregates/catalog/src/Plugin/CatalogPlugin.res`
