---
title: Hybrid Implementation
sidebar_position: 4
---

# Hybrid Implementation

The hybrid approach mixes **aggregate-based** and **DCB-based** components within a single Plugin. Each entity gets the modeling strategy that fits best:

- **Independent entities** use aggregates — simple, isolated event streams with per-instance consistency
- **Interdependent entities** share a DCB event log — enabling cross-entity decision models with per-command optimistic concurrency

In this example: **Category** and **Customer** stay as aggregates because their lifecycles are fully independent. **Product + ProductDemand** and **Order + CatalogProduct** share DCB event logs because they benefit from querying each other's events in the same filtered read.

---

## Plugin 1: Catalog

Manages the product catalogue — what is available for sale and how it is organized.

### Aggregate: `Category`

A named grouping of products (e.g. "Books", "Electronics"). Category has its own event log — separate from the DCB event log.

| Commands | Events |
|---|---|
| `AddCategory` | `CategoryAdded` |
| `RenameCategory` | `CategoryRenamed` |
| `ArchiveCategory` | `CategoryArchived` |

**Why an aggregate?** Category has no relationship to Product or ProductDemand events. Including it in the DCB log would add noise without benefit. Its simple Add/Rename/Archive lifecycle is a natural fit for an isolated aggregate with per-instance consistency.

### Chapter: Product

A product listing with a name, description, and price. Product events are tagged by `productId` in the shared DCB event log.

| State Change Slices | Commands | Events |
|---|---|---|
| `AddProduct` | `AddProduct` | `ProductAdded` |
| `ChangeProductName` | `ChangeProductName` | `ProductNameChanged` |
| `ChangeProductDescription` | `ChangeProductDescription` | `ProductDescriptionChanged` |
| `ChangeProductPrice` | `ChangeProductPrice` | `ProductPriceChanged` |

| State View Slices | Events | Read Models |
|---|---|---|
| `ProductsView` | `ProductAdded`, `ProductNameChanged`, `ProductDescriptionChanged`, `ProductPriceChanged` | `Products` |

#### Inbound Translation: Import Product from Supplier

An **InboundTranslationSlice** receives external supplier data, validates it, and translates it into an `AddProduct` command — identical to the DCB-based implementation.

| Inbound Translation Slice | External Input | Command Produced |
|---|---|---|
| `ImportProduct` | Supplier product JSON | `AddProduct` |

### Chapter: ProductDemand

Tracks per-product order demand. Driven entirely by events arriving from Ordering's Extension Point. Demand events are tagged by `productId` — the same tag as Product events, so the `ProductDemandView` can combine both in a single filtered read.

| State Change Slices | Commands | Events |
|---|---|---|
| `RecordProductDemand` | `RecordDemand`, `RevokeDemand` | `ProductDemandRecorded`, `ProductDemandRevoked` |

| State View Slices | Events | Read Models |
|---|---|---|
| `ProductDemandView` | `ProductAdded`, `ProductDemandRecorded`, `ProductDemandRevoked` | `ProductDemand` |

**Why Product + ProductDemand share DCB?** ProductDemand uses the same `productId` tag as Product events. The `ProductDemandView` can query both in a single filtered read. The `RecordProductDemand` decision model can validate product existence — something that would require a cross-aggregate query in the aggregate-based approach.

### CatalogEventLog

The DCB event log contains **only Product and ProductDemand events** — no Category events. Category has its own aggregate event log.

```rescript
// CatalogEventLog.res

open Reventless
@schema
type event =
  | ProductAdded({
      productId: @s.matches(DcbTag.string) string,
      name: string,
      description: string,
      price: float,
    })
  | ProductNameChanged({productId: @s.matches(DcbTag.string) string, name: string})
  | ProductDescriptionChanged({
      productId: @s.matches(DcbTag.string) string,
      description: string,
    })
  | ProductPriceChanged({productId: @s.matches(DcbTag.string) string, price: float})
  | ProductDemandRecorded({
      productId: @s.matches(DcbTag.string) string,
      orderId: string,
    })
  | ProductDemandRevoked({
      productId: @s.matches(DcbTag.string) string,
      orderId: string,
    })
```

Compare this with the pure DCB implementation's `CatalogEventLog`, which also includes `CategoryAdded`, `CategoryRenamed`, and `CategoryArchived`. In the hybrid approach those events live in the Category aggregate's own event log instead.

### Extension Point: `ProductsExtensionPoint`

Outbound API from Catalog to Ordering. Translates internal `CatalogEventLog` events into a stable public vocabulary — identical to the other implementations.

| EP Event | Triggered By |
|---|---|
| `ProductBecameAvailable` | `ProductAdded` |
| `ProductPriceChanged` | `ProductPriceChanged` |

### Extension: `OrdersExtension`

Inbound subscription to Ordering's `OrdersExtensionPoint`. Routes demand events to `RecordProductDemand` slice commands — identical to the other implementations.

| EP Event Received | Command Dispatched |
|---|---|
| `ItemOrdered` | `RecordDemand` |
| `ItemOrderCancelled` | `RevokeDemand` |

---

## Plugin 2: Ordering

Handles the purchase flow — who is buying and what they ordered.

### Aggregate: `Customer`

A registered buyer with contact details and account status. Customer has its own event log — separate from the DCB event log.

| Commands | Events |
|---|---|
| `RegisterCustomer` | `CustomerRegistered` |
| `UpdateEmail` | `EmailUpdated` |
| `UpdateAddress` | `AddressUpdated` |
| `DeactivateCustomer` | `CustomerDeactivated` |

**Why an aggregate?** Customer lifecycle is fully independent. No cross-entity consistency with Order or CatalogProduct is needed. Its register/update/deactivate lifecycle is a natural fit for a simple aggregate.

### Chapter: Order

A confirmed purchase referencing product IDs and a customer. Order events are tagged by `orderId` in the shared DCB event log.

| State Change Slices | Commands | Events |
|---|---|---|
| `PlaceOrder` | `PlaceOrder` | `OrderPlaced` |
| `ShipOrder` | `ShipOrder` | `OrderShipped` |
| `CancelOrder` | `CancelOrder` | `OrderCancelled` |

| State View Slices | Events | Read Models |
|---|---|---|
| `OrdersView` | `OrderPlaced`, `OrderShipped`, `OrderCancelled` | `Orders` |

#### Automation: Auto-Ship Order

An **AutomationSlice** automatically ships every placed order — identical to the DCB-based implementation.

| Automation Slice | Trigger Event | Command Issued | Resolved By |
|---|---|---|---|
| `AutoShipOrder` | `OrderPlaced` | `ShipOrder` | `OrderShipped` |

#### Outbound Translation: Send Order Confirmation Email

An **OutboundTranslationSlice** sends a confirmation email whenever an order is placed — identical to the DCB-based implementation.

| Outbound Translation Slice | Trigger Event | External Action |
|---|---|---|
| `SendOrderConfirmation` | `OrderPlaced` | Send email via `EmailService` |

### Chapter: CatalogProduct

A lightweight shadow copy of Catalog product data, kept in sync via Catalog's Extension Point. CatalogProduct events are tagged by `productId` in the shared DCB event log.

| State Change Slices | Commands | Events |
|---|---|---|
| `SyncCatalogProduct` | `SyncNewProduct`, `SyncPriceChange` | `CatalogProductSynced`, `CatalogProductPriceChanged` |

| State View Slices | Events | Read Models |
|---|---|---|
| `AvailableProductsView` | `CatalogProductSynced`, `CatalogProductPriceChanged` | `AvailableProducts` |

**Why Order + CatalogProduct share DCB?** Both entities benefit from living in the same event log. The shared log means CatalogProduct sync events and Order events are available together, enabling the framework to deliver both in filtered reads for projections like `AvailableProductsView`.

**Cross-entity validation:** The `PlaceOrder` command uses a tagged array field (`productId: array<@s.matches(DcbTag.string) string>`) to reference product IDs. The runtime automatically builds a multi-clause OR query that fetches both Order events (by `orderId`) and CatalogProduct events (by each `productId`) into the same decision model — enabling PlaceOrder to reject orders referencing unknown products.

### OrderingEventLog

The DCB event log contains **only Order and CatalogProduct events** — no Customer events. Customer has its own aggregate event log.

```rescript
// OrderingEventLog.res

open Reventless
@schema
type event =
  | OrderPlaced({
      orderId: @s.matches(DcbTag.string) string,
      customerId: string,
      productIds: array<string>,
    })
  | OrderShipped({orderId: @s.matches(DcbTag.string) string})
  | OrderCancelled({
      orderId: @s.matches(DcbTag.string) string,
      productIds: array<string>,
    })
  | CatalogProductSynced({
      productId: @s.matches(DcbTag.string) string,
      name: string,
      price: float,
    })
  | CatalogProductPriceChanged({
      productId: @s.matches(DcbTag.string) string,
      price: float,
    })
```

Compare this with the pure DCB implementation's `OrderingEventLog`, which also includes `CustomerRegistered`, `EmailChanged`, `AddressChanged`, and `CustomerDeactivated`. In the hybrid approach those events live in the Customer aggregate's own event log instead.

### Extension Point: `OrdersExtensionPoint`

Outbound API from Ordering to Catalog — identical to the other implementations.

| EP Event | Triggered By |
|---|---|
| `ItemOrdered` | `OrderPlaced` |
| `ItemOrderCancelled` | `OrderCancelled` |

### Extension: `ProductsExtension`

Inbound subscription to Catalog's `ProductsExtensionPoint` — identical to the other implementations.

| EP Event Received | Command Dispatched |
|---|---|
| `ProductBecameAvailable` | `SyncCatalogProduct` |
| `ProductPriceChanged` | `SyncCatalogProduct` |

---

## Cross-Plugin Integration

Cross-plugin communication is identical to the other two implementations. Extension Points abstract away whether the source entity uses an aggregate or DCB internally — the EP contract is the same. Neither Plugin knows or cares how the other models its entities.

---

## Plugin Composition

This is the key section — the hybrid `Plugin.make` call that passes both `~aggregates` and `~dcbSpec`.

### CatalogPlugin

```rescript
// CatalogPlugin.res

open Reventless.Projection

module Make = (Platform: ReventlessInfra.Platform.T) => {
  // ── Category Aggregate ──────────────────────────────────────
  module CategoryAggregate = Platform.Aggregate.Make(
    Category,
    CategoryBehavior,
    ReventlessInfra.NoEventMappings.Make(Category),
  )

  module CategoryProjections: Mappings with module Target := CategoriesReadModel = {
    module M = Mappings.Make(CategoriesReadModel)
    module type Mapping = M.Mapping
    let mappings: array<module(Mapping)> = [module(CategoriesProjections.CategoryMapping)]
  }

  module CategoryReadModel = Platform.ReadModel.Make(CategoriesReadModel, CategoryProjections)

  // ── Product/ProductDemand DCB ───────────────────────────────
  module CatalogEventLogMaker = Platform.DcbEventLog.Make(CatalogEventLog)

  module AddProductSlice = Platform.StateChangeSlice.Make(AddProduct)
  module ChangeProductNameSlice = Platform.StateChangeSlice.Make(ChangeProductName)
  module ChangeProductDescriptionSlice = Platform.StateChangeSlice.Make(ChangeProductDescription)
  module ChangeProductPriceSlice = Platform.StateChangeSlice.Make(ChangeProductPrice)

  module ProductsViewSlice = Platform.StateViewSlice.Make(ProductsView)

  module ImportProductSlice = Platform.InboundTranslationSlice.Make(ImportProduct)

  module RecordProductDemandSlice = Platform.StateChangeSlice.Make(RecordProductDemand)
  module ProductDemandViewSlice = Platform.StateViewSlice.Make(ProductDemandView)

  // ── Extension Point and Extension (same as other approaches) ──
  // ... (EP and Extension wiring omitted for brevity)

  // ── DCB Spec (excludes Category — it's an aggregate) ───────
  module DcbSpec = {
    @schema
    type event = CatalogEventLog.event
    let stateChangeSlices = [
      module(AddProductSlice), module(ChangeProductNameSlice),
      module(ChangeProductDescriptionSlice), module(ChangeProductPriceSlice),
      module(RecordProductDemandSlice),
    ]
    let stateViewSlices = [module(ProductsViewSlice), module(ProductDemandViewSlice)]
    let automationSlices = []
    let outboundTranslationSlices = []
    let inboundTranslationSlices = [module(ImportProductSlice)]
  }

  // ── Hybrid Plugin Assembly ──────────────────────────────────
  let make = (~scheduler, ~api, ~apiRole) =>
    Platform.Plugin.make(
      ~name="Catalog",
      ~version="1.0.0",
      ~heartbeatInterval=60,
      ~aggregates=[module(CategoryAggregate)],     // ← aggregate entities
      ~readModels=[module(CategoryReadModel)],     // ← aggregate read models
      ~extensionPoints=[module(ProductsExtensionPointMaker)],
      ~extensions=[module(OrdersExtensionMaker)],
      ~api, ~apiRole, ~scheduler,
      ~dcbSpec=module(DcbSpec),                    // ← DCB entities
    )
}
```

The key difference from the other approaches: `Plugin.make` receives both `~aggregates` (for Category) and `~dcbSpec` (for Product/ProductDemand). The framework handles the routing — aggregate commands go to per-instance event logs, DCB commands go to the shared event log.

### OrderingPlugin

```rescript
// OrderingPlugin.res

module Make = (Platform: ReventlessInfra.Platform.T) => {
  // ── Customer Aggregate ──────────────────────────────────────
  module CustomerAggregate = Platform.Aggregate.Make(
    Customer, CustomerBehavior,
    ReventlessInfra.NoEventMappings.Make(Customer),
  )
  module CustomerReadModel = Platform.ReadModel.Make(CustomersReadModel, CustomerProjections)

  // ── Order/CatalogProduct DCB ────────────────────────────────
  module OrderingEventLogMaker = Platform.DcbEventLog.Make(OrderingEventLog)

  module PlaceOrderSlice = Platform.StateChangeSlice.Make(PlaceOrder)
  module ShipOrderSlice = Platform.StateChangeSlice.Make(ShipOrder)
  module CancelOrderSlice = Platform.StateChangeSlice.Make(CancelOrder)

  module AutoShipOrderSlice = Platform.AutomationSlice.Make(AutoShipOrder)
  module SendOrderConfirmationSlice = Platform.OutboundTranslationSlice.Make(SendOrderConfirmation)

  module OrdersViewSlice = Platform.StateViewSlice.Make(OrdersView)

  module SyncCatalogProductSlice = Platform.StateChangeSlice.Make(SyncCatalogProduct)
  module AvailableProductsViewSlice = Platform.StateViewSlice.Make(AvailableProductsView)

  // ── Extension Point and Extension (same as other approaches) ──
  // ... (EP and Extension wiring omitted for brevity)

  // ── DCB Spec (excludes Customer — it's an aggregate) ───────
  module DcbSpec = {
    @schema
    type event = OrderingEventLog.event
    let stateChangeSlices = [
      module(PlaceOrderSlice), module(ShipOrderSlice),
      module(CancelOrderSlice), module(SyncCatalogProductSlice),
    ]
    let stateViewSlices = [module(OrdersViewSlice), module(AvailableProductsViewSlice)]
    let automationSlices = [module(AutoShipOrderSlice)]
    let outboundTranslationSlices = [module(SendOrderConfirmationSlice)]
    let inboundTranslationSlices = []
  }

  // ── Hybrid Plugin Assembly ──────────────────────────────────
  let make = (~scheduler, ~api, ~apiRole) =>
    Platform.Plugin.make(
      ~name="Ordering",
      ~version="1.0.0",
      ~heartbeatInterval=60,
      ~aggregates=[module(CustomerAggregate)],      // ← aggregate entities
      ~readModels=[module(CustomerReadModel)],      // ← aggregate read models
      ~extensionPoints=[module(OrdersExtensionPointMaker)],
      ~extensions=[module(ProductsExtensionMaker)],
      ~api, ~apiRole, ~scheduler,
      ~dcbSpec=module(DcbSpec),                     // ← DCB entities
    )
}
```

Same pattern: `~aggregates` for Customer, `~dcbSpec` for Order/CatalogProduct.

---

## When to Choose Hybrid

| Scenario | Recommended Approach |
|---|---|
| All entities have independent lifecycles | **Aggregate-based** — simplest model, isolated streams |
| All entities benefit from shared event log | **DCB-based** — cross-entity consistency, fewer tables |
| Some entities are independent, others need cross-entity consistency | **Hybrid** — best of both |

The hybrid boundary must be clean: entities that need cross-entity consistency **must** share the same DCB event log. Entities that are independent **should** be aggregates — including them in the DCB log adds noise without benefit.

### Decision checklist

For each entity in your Plugin, ask:

1. **Does this entity need to see events from other entities in its decision model?** → DCB
2. **Does a read model need to combine events from this entity with another entity's events?** → Both entities should share a DCB log
3. **Is this entity's lifecycle fully independent?** → Aggregate

If all answers point to the same approach, use that approach. If answers are mixed, use hybrid.
