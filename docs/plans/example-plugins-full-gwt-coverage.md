# Full GWT Test Coverage for Example Plugins

## Goal

Every authored component in every example plugin under `examples/online-shop-aggregates/`, `examples/online-shop-dcb/`, and `examples/online-shop-hybrid/` should have a single corresponding GWT (`@@reventless.gwt` or `_GWT`-suffixed) test file. **Nothing else.**

That means:

- Every Aggregate (Behavior + Mapping), every StateChangeSlice, every StateViewSlice / StateViewSliceStream, every ReadModel projection, every InboundTranslationSlice, every OutboundTranslationSlice, every AutomationSlice → one `*_GWT.res` file using the appropriate `ReventlessGwt.*_GWT` DSL.
- All other test files in `tests/` (E2E integration tests, ad-hoc `*Test.res` Jest scaffolds, projection tests written against `Projection.Set/Update/Delete` directly) → **deleted**.
- Platform packages (`platform-in-memory/`, `platform-aws/`) and AWS plugin variants (`catalog-aws/`, `ordering-aws/`) keep zero tests — they wire infrastructure, not behaviour.
- Spec packages (`*-spec/`) keep zero tests.

The canonical reference is `docs/guides/given-when-then.md` and the worked examples in `reventless/reventless-gwt/tests/`. The codegen output under `examples/codegen/dilger/*/tests/` is the gold standard for shape and PPX usage.

## Convention recap (from the GWT guide)

| Component kind                      | DSL module                                            | File name pattern                            |
| ----------------------------------- | ----------------------------------------------------- | -------------------------------------------- |
| Aggregate command (Aggregate)       | `Behavior_GWT.Make(Spec, Behavior)`                   | `<Spec>_GWT.res` next to behavior            |
| StateChangeSlice (DCB)              | inferred from folder `StateChangeSlice/`              | `<SliceSpec>_GWT.res`                        |
| ReadModel projection (Aggregate)    | `MultiSourceProjection_GWT.Make(Mapping)` or per-source `Projection_GWT.Make(Mapping)` | `<ReadModelSpec>_GWT.res` next to projection |
| StateViewSlice / StateViewSliceStream (DCB) | inferred from folder                          | `<ViewSpec>_GWT.res`                         |
| AutomationSlice (DCB)               | inferred from folder `AutomationSlice/`               | `<AutomationSpec>_GWT.res`                   |
| InboundTranslationSlice             | inferred from folder `InboundTranslationSlice/`       | `<SliceSpec>_GWT.res`                        |
| OutboundTranslationSlice            | inferred from folder `OutboundTranslationSlice/`      | `<SliceSpec>_GWT.res`                        |
| Cross-pattern automation (Mappings) | `Mapping_GWT.Make(Mapping)`                           | `<TargetSpec>Mappings_GWT.res` (only when a Mappings module exists with non-trivial map logic — skip empty `NoEventMappings`) |

For every test file:

1. Place it under `tests/<EntityFolder>/<SliceFolder>/<Spec>_GWT.res` mirroring the `src/` layout (so the PPX folder-segment heuristic kicks in).
2. Use bare `@@reventless.gwt` whenever possible; fall back to `@@reventless.gwt(SpecModule)` only when the Spec is in a different module from the filename stem; use `@@reventless.gwt(Spec, Behavior)` only for Aggregate Behaviors when the two-arg functor is needed.
3. Name tests Given/When/Then style: "empty event log produces …", "existing X returns YAlreadyExists", "same name produces no events (idempotent)".
4. Cover at least: happy path, validation/precondition error, idempotency case (where applicable). For projections cover every event variant the Mapping reacts to.

## Out of scope

- Adding test coverage to platforms, AWS adapters, or spec packages.
- Migrating the `reventless-gwt` package's own internal tests.
- Refactoring source files; tests are added/converted to match the existing source.
- Touching codegen-generated example projects under `examples/codegen/`.

---

## Phase 0 — Pre-flight

- [ ] Run `pnpm run build` from repo root and confirm zero warnings against the current state.
- [ ] Run the existing example tests once and capture the baseline (`pnpm test --filter '@reventlessdev/online-shop-*'`) so regressions during conversion are spottable.
- [ ] Re-read `docs/guides/given-when-then.md` §§ 4.1–4.10 and skim the runnable copies under `reventless/reventless-gwt/tests/`.
- [ ] Confirm each example plugin already lists `@reventlessdev/reventless-gwt` in its `rescript.json` `dependencies` — if not, add it before writing `_GWT` tests.

---

## Phase 1 — `online-shop-aggregates` (Aggregate-pattern variant)

### 1.1 Catalog plugin (`examples/online-shop-aggregates/catalog/`)

Source components requiring GWT coverage:

| Component                                       | Folder                                | Test file to create                                                |
| ----------------------------------------------- | ------------------------------------- | ------------------------------------------------------------------ |
| Category aggregate (Behavior)                   | `src/Category/Aggregate/`             | `tests/Category/Aggregate/Category_GWT.res`                        |
| Categories ReadModel projection                 | `src/Category/ReadModel/`             | `tests/Category/ReadModel/Categories_GWT.res`                      |
| Product aggregate (Behavior)                    | `src/Product/Aggregate/`              | `tests/Product/Aggregate/Product_GWT.res`                          |
| Products ReadModel projection                   | `src/Product/ReadModel/`              | `tests/Product/ReadModel/Products_GWT.res`                         |
| ProductDemand aggregate (Behavior) **[gap]**    | `src/ProductDemand/Aggregate/`        | `tests/ProductDemand/Aggregate/ProductDemand_GWT.res`              |
| ProductDemands ReadModel projection **[gap]**   | `src/ProductDemand/ReadModel/`        | `tests/ProductDemand/ReadModel/ProductDemands_GWT.res`             |

Tasks:

- [ ] **Convert** `tests/Category/CategoryBehaviorTest.res` → `tests/Category/Aggregate/Category_GWT.res` (`@@reventless.gwt`, drop the manual `include` once the PPX resolves it).
- [ ] **Convert** `tests/Category/CategoryProjectionTest.res` → `tests/Category/ReadModel/Categories_GWT.res` using `MultiSourceProjection_GWT`.
- [ ] **Convert** `tests/Product/ProductBehaviorTest.res` → `tests/Product/Aggregate/Product_GWT.res`.
- [ ] **Convert** `tests/Product/ProductProjectionTest.res` → `tests/Product/ReadModel/Products_GWT.res`.
- [ ] **Add** `tests/ProductDemand/Aggregate/ProductDemand_GWT.res` covering the full ProductDemand command/event surface.
- [ ] **Add** `tests/ProductDemand/ReadModel/ProductDemands_GWT.res` covering every event the projection consumes.
- [ ] **Delete** `tests/E2E/CategoryE2ETest.res` and `tests/E2E/ProductE2ETest.res`. Remove the now-empty `tests/E2E/` folder.
- [ ] **Delete** the old top-level `tests/Category/CategoryBehaviorTest.res` and `CategoryProjectionTest.res` once the Aggregate-folder copies build (likewise for Product).

### 1.2 Ordering plugin (`examples/online-shop-aggregates/ordering/`)

| Component                                              | Folder                                   | Test file to create                                                       |
| ------------------------------------------------------ | ---------------------------------------- | ------------------------------------------------------------------------- |
| Customer aggregate (Behavior)                          | `src/Customer/Aggregate/`                | `tests/Customer/Aggregate/Customer_GWT.res`                               |
| Customers ReadModel projection                         | `src/Customer/ReadModel/`                | `tests/Customer/ReadModel/Customers_GWT.res`                              |
| Order aggregate (Behavior)                             | `src/Order/Aggregate/`                   | `tests/Order/Aggregate/Order_GWT.res`                                     |
| Order Mappings (`Order_Mappings.res` — uses sources)   | `src/Order/Aggregate/Order_Mappings.res` | `tests/Order/Aggregate/OrderMappings_GWT.res` (`Mapping_GWT.Make`)        |
| Orders ReadModel projection                            | `src/Order/ReadModel/`                   | `tests/Order/ReadModel/Orders_GWT.res`                                    |
| CatalogProduct aggregate (Behavior) **[gap]**          | `src/CatalogProduct/Aggregate/`          | `tests/CatalogProduct/Aggregate/CatalogProduct_GWT.res`                   |
| AvailableProducts ReadModel projection **[gap]**       | `src/CatalogProduct/ReadModel/`          | `tests/CatalogProduct/ReadModel/AvailableProducts_GWT.res`                |

Tasks:

- [ ] Inspect `Order_Mappings.res` — if it carries non-trivial `EventMapping` rules (e.g. translating Customer events into Order commands), add a `Mapping_GWT` test. If it's a `NoEventMappings.Make(...)` stub, skip the mappings test row above.
- [ ] **Convert** `tests/Customer/CustomerBehaviorTest.res`, `tests/Customer/CustomerProjectionTest.res`, `tests/Order/OrderBehaviorTest.res`, `tests/Order/OrderProjectionTest.res` to the `_GWT` shape and folder-mirror.
- [ ] **Add** GWT files for CatalogProduct aggregate and AvailableProducts projection (currently zero coverage).
- [ ] **Delete** `tests/E2E/CustomerE2ETest.res` and `tests/E2E/OrderE2ETest.res`. Remove `tests/E2E/`.
- [ ] **Delete** the old non-`_GWT` test files once their replacements compile.

### 1.3 Aggregates variant — verify

- [ ] `pnpm --filter @reventlessdev/online-shop-aggregates-catalog test` passes with only `*_GWT.res` files.
- [ ] `pnpm --filter @reventlessdev/online-shop-aggregates-ordering test` passes likewise.
- [ ] `find examples/online-shop-aggregates -path "*/tests/*" -name "*.res" -not -path "*/lib/bs/*"` lists only `*_GWT.res`.

---

## Phase 2 — `online-shop-dcb` (DCB-pattern variant)

DCB is where most ad-hoc Jest tests live. Each StateChangeSlice's pure-Jest `*DecisionTest.res` covers `evolve` + `decide` and must be **split into one `<Slice>_GWT.res` per slice** mirroring the `src/` folder structure (the GWT PPX cannot resolve a Spec from a multi-slice file). Same goes for the StateViewSlice tests.

### 2.1 Catalog plugin (`examples/online-shop-dcb/catalog/`)

| Slice                                | Folder                                       | Test file to create                                                          |
| ------------------------------------ | -------------------------------------------- | ---------------------------------------------------------------------------- |
| AddCategory                          | `src/Category/StateChangeSlice/`             | `tests/Category/StateChangeSlice/AddCategory_GWT.res`                        |
| RenameCategory                       | `src/Category/StateChangeSlice/`             | `tests/Category/StateChangeSlice/RenameCategory_GWT.res`                     |
| ArchiveCategory                      | `src/Category/StateChangeSlice/`             | `tests/Category/StateChangeSlice/ArchiveCategory_GWT.res`                    |
| Categories (StateViewSlice)          | `src/Category/StateViewSlice/`               | `tests/Category/StateViewSlice/Categories_GWT.res`                           |
| AddProduct                           | `src/Product/StateChangeSlice/`              | `tests/Product/StateChangeSlice/AddProduct_GWT.res`                          |
| ChangeProductName                    | `src/Product/StateChangeSlice/`              | `tests/Product/StateChangeSlice/ChangeProductName_GWT.res`                   |
| ChangeProductDescription             | `src/Product/StateChangeSlice/`              | `tests/Product/StateChangeSlice/ChangeProductDescription_GWT.res`            |
| ChangeProductPrice                   | `src/Product/StateChangeSlice/`              | `tests/Product/StateChangeSlice/ChangeProductPrice_GWT.res`                  |
| RecordProductDemand                  | `src/Product/StateChangeSlice/`              | `tests/Product/StateChangeSlice/RecordProductDemand_GWT.res`                 |
| Products (StateViewSlice)            | `src/Product/StateViewSlice/`                | `tests/Product/StateViewSlice/Products_GWT.res`                              |
| ProductDemand (StateViewSlice) **[gap]** | `src/Product/StateViewSlice/`            | `tests/Product/StateViewSlice/ProductDemand_GWT.res`                         |
| ImportProduct (InboundTranslationSlice) **[gap]** | `src/Product/InboundTranslationSlice/` | `tests/Product/InboundTranslationSlice/ImportProduct_GWT.res`           |

Tasks:

- [ ] **Replace** `tests/Category/StateChangeSlice/CategoryDecisionTest.res` with three `_GWT` files (one per slice). Each one uses bare `@@reventless.gwt` — the folder segment `StateChangeSlice` and filename stem give the PPX everything it needs.
- [ ] **Replace** `tests/Product/StateChangeSlice/ProductDecisionTest.res` with five `_GWT` files (AddProduct, ChangeProductName, ChangeProductDescription, ChangeProductPrice, RecordProductDemand).
- [ ] **Replace** `tests/Category/StateViewSlice/CategoriesTest.res` with `Categories_GWT.res` using the StateViewSlice DSL (`thenAllStates` / `thenStateWithId`).
- [ ] **Replace** `tests/Product/StateViewSlice/ProductsTest.res` with `Products_GWT.res`.
- [ ] **Add** `tests/Product/StateViewSlice/ProductDemand_GWT.res` (currently no test).
- [ ] **Add** `tests/Product/InboundTranslationSlice/ImportProduct_GWT.res` using `InboundTranslation_GWT` DSL — cover happy translation + error/unknown-input branches.
- [ ] **Delete** `tests/E2E/CatalogE2ETest.res` and the `tests/E2E/` folder.
- [ ] **Delete** all the now-superseded `*DecisionTest.res` and `*Test.res` files.

### 2.2 Ordering plugin (`examples/online-shop-dcb/ordering/`)

| Slice                                 | Folder                                          | Test file to create                                                              |
| ------------------------------------- | ----------------------------------------------- | -------------------------------------------------------------------------------- |
| RegisterCustomer                      | `src/Customer/StateChangeSlice/`                | `tests/Customer/StateChangeSlice/RegisterCustomer_GWT.res`                       |
| ChangeAddress                         | `src/Customer/StateChangeSlice/`                | `tests/Customer/StateChangeSlice/ChangeAddress_GWT.res`                          |
| ChangeEmail                           | `src/Customer/StateChangeSlice/`                | `tests/Customer/StateChangeSlice/ChangeEmail_GWT.res`                            |
| DeactivateCustomer                    | `src/Customer/StateChangeSlice/`                | `tests/Customer/StateChangeSlice/DeactivateCustomer_GWT.res`                     |
| Customers (StateViewSlice)            | `src/Customer/StateViewSlice/`                  | `tests/Customer/StateViewSlice/Customers_GWT.res`                                |
| PlaceOrder                            | `src/Order/StateChangeSlice/`                   | `tests/Order/StateChangeSlice/PlaceOrder_GWT.res`                                |
| ShipOrder                             | `src/Order/StateChangeSlice/`                   | `tests/Order/StateChangeSlice/ShipOrder_GWT.res`                                 |
| CancelOrder                           | `src/Order/StateChangeSlice/`                   | `tests/Order/StateChangeSlice/CancelOrder_GWT.res`                               |
| Orders (StateViewSlice)               | `src/Order/StateViewSlice/`                     | `tests/Order/StateViewSlice/Orders_GWT.res`                                      |
| AutoShipOrder (AutomationSlice) **[gap]** | `src/Order/AutomationSlice/`                | `tests/Order/AutomationSlice/AutoShipOrder_GWT.res`                              |
| SendOrderConfirmation (OutboundTranslationSlice) **[gap]** | `src/Order/OutboundTranslationSlice/` | `tests/Order/OutboundTranslationSlice/SendOrderConfirmation_GWT.res` |
| SyncCatalogProduct                    | `src/CatalogProduct/StateChangeSlice/`          | `tests/CatalogProduct/StateChangeSlice/SyncCatalogProduct_GWT.res`               |
| AvailableProducts (StateViewSlice) **[gap]** | `src/CatalogProduct/StateViewSlice/`     | `tests/CatalogProduct/StateViewSlice/AvailableProducts_GWT.res`                  |

Tasks:

- [ ] **Replace** `tests/Customer/StateChangeSlice/CustomerDecisionTest.res` with four per-slice `_GWT` files.
- [ ] **Replace** `tests/Order/StateChangeSlice/OrderDecisionTest.res` with three per-slice `_GWT` files.
- [ ] **Replace** `tests/Customer/StateViewSlice/CustomersTest.res` and `tests/Order/StateViewSlice/OrdersTest.res` with `_GWT` versions.
- [ ] **Add** `tests/CatalogProduct/StateChangeSlice/SyncCatalogProduct_GWT.res`.
- [ ] **Add** `tests/CatalogProduct/StateViewSlice/AvailableProducts_GWT.res`.
- [ ] **Add** `tests/Order/AutomationSlice/AutoShipOrder_GWT.res` using `Automation_GWT` (cover `collect`, `resolve`, `process`).
- [ ] **Add** `tests/Order/OutboundTranslationSlice/SendOrderConfirmation_GWT.res` using `OutboundTranslation_GWT`.
- [ ] **Delete** `tests/E2E/OrderingE2ETest.res` and the `tests/E2E/` folder.
- [ ] **Delete** all superseded `*DecisionTest.res` and `*Test.res` files.

### 2.3 DCB variant — verify

- [ ] `pnpm --filter @reventlessdev/online-shop-dcb-catalog test` passes.
- [ ] `pnpm --filter @reventlessdev/online-shop-dcb-ordering test` passes.
- [ ] No file under `examples/online-shop-dcb/*/tests/` ends in `Test.res` (only `_GWT.res`).

---

## Phase 3 — `online-shop-hybrid` (mixed Aggregate + DCB)

The hybrid variant currently has the worst coverage gap (both projections and several slices are untested). Apply the same per-slice / per-projection rule as Phases 1–2.

### 3.1 Catalog plugin (`examples/online-shop-hybrid/catalog/`)

| Component                                          | Folder                                          | Test file to create                                                          |
| -------------------------------------------------- | ----------------------------------------------- | ---------------------------------------------------------------------------- |
| Category aggregate (Behavior)                      | `src/Category/Aggregate/`                       | `tests/Category/Aggregate/Category_GWT.res`                                  |
| Categories ReadModel projection                    | `src/Category/ReadModel/`                       | `tests/Category/ReadModel/Categories_GWT.res`                                |
| CatalogActivity ReadModel projection               | `src/CatalogActivity/ReadModel/`                | `tests/CatalogActivity/ReadModel/CatalogActivity_GWT.res`                    |
| AddProduct                                         | `src/Product/StateChangeSlice/`                 | `tests/Product/StateChangeSlice/AddProduct_GWT.res`                          |
| ChangeProductName                                  | `src/Product/StateChangeSlice/`                 | `tests/Product/StateChangeSlice/ChangeProductName_GWT.res`                   |
| ChangeProductDescription                           | `src/Product/StateChangeSlice/`                 | `tests/Product/StateChangeSlice/ChangeProductDescription_GWT.res`            |
| ChangeProductPrice                                 | `src/Product/StateChangeSlice/`                 | `tests/Product/StateChangeSlice/ChangeProductPrice_GWT.res`                  |
| Products (StateViewSliceStream)                    | `src/Product/StateViewSliceStream/`             | `tests/Product/StateViewSliceStream/Products_GWT.res`                        |
| ProductDemand (StateViewSliceStream)               | `src/Product/StateViewSliceStream/`             | `tests/Product/StateViewSliceStream/ProductDemand_GWT.res`                   |
| RecordProductDemand                                | `src/ProductDemand/StateChangeSlice/`           | `tests/ProductDemand/StateChangeSlice/RecordProductDemand_GWT.res`           |
| ImportProduct (InboundTranslationSlice)            | `src/Product/InboundTranslationSlice/`          | `tests/Product/InboundTranslationSlice/ImportProduct_GWT.res`                |

Tasks:

- [ ] **Convert** `tests/Category/CategoryBehaviorTest.res` → `tests/Category/Aggregate/Category_GWT.res`.
- [ ] **Add** GWT tests for Categories and CatalogActivity ReadModels (no current coverage).
- [ ] **Replace** `tests/Product/ProductDecisionTest.res` with one `_GWT.res` per StateChangeSlice (four files).
- [ ] **Add** GWT tests for Products and ProductDemand StateViewSliceStream projections.
- [ ] **Add** GWT test for RecordProductDemand StateChangeSlice (lives under `ProductDemand/`, not `Product/`).
- [ ] **Add** GWT test for ImportProduct InboundTranslationSlice.
- [ ] **Delete** `tests/E2E/CatalogE2ETest.res` and `tests/E2E/`.
- [ ] **Delete** the superseded `*BehaviorTest.res` / `*DecisionTest.res` files.

### 3.2 Ordering plugin (`examples/online-shop-hybrid/ordering/`)

| Component                                                  | Folder                                          | Test file to create                                                              |
| ---------------------------------------------------------- | ----------------------------------------------- | -------------------------------------------------------------------------------- |
| Customer aggregate (Behavior)                              | `src/Customer/Aggregate/`                       | `tests/Customer/Aggregate/Customer_GWT.res`                                      |
| Customers ReadModel projection                             | `src/Customer/ReadModel/`                       | `tests/Customer/ReadModel/Customers_GWT.res`                                     |
| SyncCatalogProduct                                         | `src/CatalogProduct/StateChangeSlice/`          | `tests/CatalogProduct/StateChangeSlice/SyncCatalogProduct_GWT.res`               |
| AvailableProducts (StateViewSlice)                         | `src/CatalogProduct/StateViewSlice/`            | `tests/CatalogProduct/StateViewSlice/AvailableProducts_GWT.res`                  |
| PlaceOrder                                                 | `src/Order/StateChangeSlice/`                   | `tests/Order/StateChangeSlice/PlaceOrder_GWT.res`                                |
| ShipOrder                                                  | `src/Order/StateChangeSlice/`                   | `tests/Order/StateChangeSlice/ShipOrder_GWT.res`                                 |
| CancelOrder                                                | `src/Order/StateChangeSlice/`                   | `tests/Order/StateChangeSlice/CancelOrder_GWT.res`                               |
| RefundOrder **[hybrid-only]**                              | `src/Order/StateChangeSlice/`                   | `tests/Order/StateChangeSlice/RefundOrder_GWT.res`                               |
| Orders (StateViewSlice)                                    | `src/Order/StateViewSlice/`                     | `tests/Order/StateViewSlice/Orders_GWT.res`                                      |
| AutoShipOrder (AutomationSlice)                            | `src/Order/AutomationSlice/`                    | `tests/Order/AutomationSlice/AutoShipOrder_GWT.res`                              |
| SendOrderConfirmation (OutboundTranslationSlice)           | `src/Order/OutboundTranslationSlice/`           | `tests/Order/OutboundTranslationSlice/SendOrderConfirmation_GWT.res`             |

Tasks:

- [ ] **Convert** `tests/Customer/CustomerBehaviorTest.res` → `tests/Customer/Aggregate/Customer_GWT.res`.
- [ ] **Add** GWT for Customers ReadModel.
- [ ] **Replace** `tests/Order/OrderDecisionTest.res` with four per-slice `_GWT` files (one of which is `RefundOrder_GWT.res`, which has no coverage today).
- [ ] **Add** GWT files for Orders, AvailableProducts, AutoShipOrder, SendOrderConfirmation, SyncCatalogProduct.
- [ ] **Delete** `tests/E2E/OrderingE2ETest.res` and `tests/E2E/`.

### 3.3 Hybrid variant — verify

- [ ] `pnpm --filter @reventlessdev/online-shop-hybrid-catalog test` passes.
- [ ] `pnpm --filter @reventlessdev/online-shop-hybrid-ordering test` passes.
- [ ] `catalog-aws/`, `ordering-aws/`, `platform-aws/`, `platform-in-memory/` still have no `tests/` directories with `.res` files.

---

## Phase 4 — Repo-wide guardrails

- [ ] Add a one-paragraph note to `docs/guides/given-when-then.md` (or `docs/guides/component-testing-guide.md`) stating the rule: **example plugins ship with `_GWT` tests only — no E2E or ad-hoc Jest tests.** Cross-link to the canonical worked examples.
- [ ] Update `MEMORY.md` with a short pointer: "All example plugins use `@@reventless.gwt`-based `*_GWT.res` files exclusively; never add E2E or `*DecisionTest.res` to examples."
- [ ] Run `pnpm run build` from repo root → zero warnings.
- [ ] Run `pnpm test` from repo root and confirm all example plugin tests pass.
- [ ] `git grep -nE "/tests/.*(BehaviorTest|ProjectionTest|DecisionTest|E2ETest)\.res" examples/` returns no hits.
- [ ] `git grep -nE "/tests/.*Test\.res" examples/online-shop-aggregates/ examples/online-shop-dcb/ examples/online-shop-hybrid/` returns no hits (only `_GWT.res`).

---

## Risks & open questions

- **`Order_Mappings.res` substance**: if it's a `NoEventMappings` placeholder it doesn't need a `Mapping_GWT` test; if it carries real cross-aggregate rules it does. Inspect before deciding.
- **`StateViewSliceStream` DSL coverage**: the GWT guide lists `StateViewSlice_GWT`/`Projection_GWT`; verify the streaming variant is exercised the same way before writing the hybrid Products/ProductDemand tests. If the runtime registers a different `_GWT` module, swap the DSL.
- **Spec-id traceability**: the codegen-generated GWT files include `// spec-id: …` markers. The hand-written conversions don't have a spec-id source, so we just keep the descriptive `test("…")` names — no spec-id comments.
- **Idempotency tests**: where the existing Jest tests assert `Ok([])` for the no-op case (e.g. ChangeProductName same name), keep that case as `thenNoEvent` in the GWT version.
- **DCB-tag fixture-style helpers**: if multiple `_GWT.res` files in the same folder need the same fixtures, use the companion-fixtures convention (`<Stem>_Fixtures.res`) so the PPX auto-opens them. Decide on a per-folder basis once more than two slices share fixture data.

## Done definition

- Every component listed in Phases 1–3 has exactly one `*_GWT.res` test file.
- No example plugin contains any `.res` test file that is not `_GWT`.
- `pnpm test` from repo root is green.
- Zero compiler warnings.
- Plan moved to `docs/plans/done/`.
