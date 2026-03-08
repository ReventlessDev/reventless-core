# Plan: Implement `online-shop-hybrid` Example

**Analysis**: [Hybrid Aggregate + DCB Approach](../analysis/hybrid-aggregate-dcb-approach.md)

**Status**: Complete

## Goal

Create a third example — `examples/online-shop-hybrid/` — that implements the same Online Shop domain as the two existing examples, but mixes aggregate-based and DCB-based components within each plugin:

- **Catalog**: Category as an aggregate + Product/ProductDemand as DCB slices
- **Ordering**: Customer as an aggregate + Order/CatalogProduct as DCB slices

The framework already supports this (`Plugin.make` accepts both `~aggregates` and `~dcbSpec`). No framework changes are needed — only a new example project.

## Design Principle

Each plugin uses the most appropriate modeling strategy per entity:

- **Independent entities** (Category, Customer) → aggregate with own event log
- **Interdependent entities** (Product + ProductDemand, Order + CatalogProduct) → shared DCB event log with cross-entity decision models

Cross-plugin communication via extension points is identical to the other examples.

### Design Note: Cross-Entity DCB Validation

The original plan proposed PlaceOrder cross-entity validation (checking CatalogProductSynced events). This was not implemented because DCB tag filtering scopes event queries by entity ID — CatalogProductSynced events (tagged by `productId`) are not visible when PlaceOrder queries by `orderId`. PlaceOrder uses the same simple duplicate-check pattern as the DCB example.

---

## Step 1: Create Package Scaffolding

- [x] Create `examples/online-shop-hybrid/catalog-spec/package.json`
- [x] Create `examples/online-shop-hybrid/catalog-spec/rescript.json`
- [x] Create `examples/online-shop-hybrid/ordering-spec/package.json`
- [x] Create `examples/online-shop-hybrid/ordering-spec/rescript.json`
- [x] Create `examples/online-shop-hybrid/catalog/package.json`
- [x] Create `examples/online-shop-hybrid/catalog/rescript.json`
- [x] Create `examples/online-shop-hybrid/ordering/package.json`
- [x] Create `examples/online-shop-hybrid/ordering/rescript.json`
- [x] Create `examples/online-shop-hybrid/online-shop-hybrid/package.json`
- [x] Create `examples/online-shop-hybrid/online-shop-hybrid/rescript.json`
- [x] Workspaces/lerna already covered by `examples/**` glob
- [x] Run `npm install` to update `package-lock.json`

---

## Step 2: Spec Packages (Extension Point Contracts)

- [x] Create `catalog-spec/src/ProductsExtensionPoint.res` + `.js`
- [x] Create `ordering-spec/src/OrdersExtensionPoint.res` + `.js`

---

## Step 3: Catalog Plugin — Category Aggregate

- [x] Create `catalog/src/Category/Aggregate/Category.res`
- [x] Create `catalog/src/Category/Aggregate/CategoryBehavior.res`
- [x] Create `catalog/src/Category/ReadModel/CategoriesReadModel.res`
- [x] Create `catalog/src/Category/ReadModel/CategoriesProjections.res`

---

## Step 4: Catalog Plugin — Product/ProductDemand DCB

- [x] Create `catalog/src/Plugin/CatalogEventLog.res` (6 events, no Category)
- [x] Create `catalog/src/Plugin/CatalogEventLog.js`
- [x] Create `catalog/src/Product/StateChangeSlice/AddProduct.res`
- [x] Create `catalog/src/Product/StateChangeSlice/ChangeProductName.res`
- [x] Create `catalog/src/Product/StateChangeSlice/ChangeProductDescription.res`
- [x] Create `catalog/src/Product/StateChangeSlice/ChangeProductPrice.res`
- [x] Create `catalog/src/Product/StateViewSlice/ProductsView.res`
- [x] Create `catalog/src/Product/StateViewSlice/ProductDemandView.res`
- [x] Create `catalog/src/Product/InboundTranslationSlice/ImportProduct.res`
- [x] Create `catalog/src/ProductDemand/StateChangeSlice/RecordProductDemand.res`

---

## Step 5: Catalog Plugin — Extension Point and Extension

- [x] Create `catalog/src/ExtensionPoint/ProductsExtensionPointMapping.res`
- [x] Create `catalog/src/Extension/OrdersExtension.res`

---

## Step 6: Catalog Plugin — Hybrid Plugin Composition

- [x] Create `catalog/src/Plugin/CatalogPlugin.res` — hybrid: `~aggregates` + `~dcbSpec`

---

## Step 7: Ordering Plugin — Customer Aggregate

- [x] Create `ordering/src/Customer/Aggregate/Customer.res`
- [x] Create `ordering/src/Customer/Aggregate/CustomerBehavior.res`
- [x] Create `ordering/src/Customer/ReadModel/CustomersReadModel.res`
- [x] Create `ordering/src/Customer/ReadModel/CustomersProjections.res`

---

## Step 8: Ordering Plugin — Order/CatalogProduct DCB

- [x] Create `ordering/src/Plugin/OrderingEventLog.res` (5 events, no Customer)
- [x] Create `ordering/src/Plugin/OrderingEventLog.js`
- [x] Create `ordering/src/Order/StateChangeSlice/PlaceOrder.res`
- [x] Create `ordering/src/Order/StateChangeSlice/ShipOrder.res`
- [x] Create `ordering/src/Order/StateChangeSlice/CancelOrder.res`
- [x] Create `ordering/src/Order/StateViewSlice/OrdersView.res`
- [x] Create `ordering/src/Order/AutomationSlice/AutoShipOrder.res`
- [x] Create `ordering/src/Order/OutboundTranslationSlice/SendOrderConfirmation.res`
- [x] Create `ordering/src/CatalogProduct/StateChangeSlice/SyncCatalogProduct.res`
- [x] Create `ordering/src/CatalogProduct/StateViewSlice/AvailableProductsView.res`
- [x] Create `ordering/src/Service/EmailService.res`

---

## Step 9: Ordering Plugin — Extension Point, Extension, and Composition

- [x] Create `ordering/src/ExtensionPoint/OrdersExtensionPointMapping.res`
- [x] Create `ordering/src/Extension/ProductsExtension.res`
- [x] Create `ordering/src/Plugin/OrderingPlugin.res` — hybrid: `~aggregates` + `~dcbSpec`

---

## Step 10: Platform Assembly

- [x] Create `online-shop-hybrid/src/Main.res`

---

## Step 11: Build and Verify

- [x] Add `@reventlessdev/online-shop-hybrid` to root `rescript.json` dependencies
- [x] Add hybrid build step to root `package.json` build script
- [x] Add hybrid test projects to root `jest.config.js`
- [x] Run `npm run build` — zero errors, zero warnings

---

## Step 12: Tests

- [x] Create `catalog/tests/Category/CategoryBehaviorTest.res` (7 tests)
- [x] Create `ordering/tests/Customer/CustomerBehaviorTest.res` (8 tests)
- [x] Create `catalog/tests/Product/ProductDecisionTest.res` (15 tests)
- [x] Create `ordering/tests/Order/OrderDecisionTest.res` (12 tests)
- [x] Create `catalog/tests/E2E/CatalogE2ETest.res` (4 tests)
- [x] Create `ordering/tests/E2E/OrderingE2ETest.res` (6 tests)
- [x] Create `catalog/__mocks__/emptyModule.js`
- [x] Create `ordering/__mocks__/emptyModule.js`
- [x] Jest config embedded in plugin `package.json` files (no separate jest.config.mjs)

---

## Step 13: Run All Tests

- [x] 52 hybrid tests pass
- [x] 749 total tests pass across 91 test suites (zero regressions)
