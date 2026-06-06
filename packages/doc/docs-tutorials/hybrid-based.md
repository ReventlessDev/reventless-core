---
title: Hybrid walkthrough
sidebar_position: 3
---

# Hybrid Implementation

The hybrid approach mixes **aggregate-based** and **DCB-based** components within a single Plugin. Each entity gets the modeling strategy that fits best:

- **Independent entities** use aggregates — simple, isolated event streams with per-instance consistency
- **Interdependent entities** share a DCB event log — enabling cross-entity decision models with per-command optimistic concurrency

In this example: **Category** and **Customer** stay as aggregates because their lifecycles are fully independent. **Product + ProductDemand** and **Order + CatalogProduct** share DCB event logs because they benefit from querying each other's events in the same filtered read.

:::info This page tracks the real package
The code on this page describes the actual
[`examples/online-shop-hybrid/`](https://github.com/ReventlessDev/reventless-core/tree/main/examples/online-shop-hybrid)
package. Two things differ from a hand-written sketch:

- **`Plugin.res` is generated**, not hand-written. A `prebuild` step runs
  `generate-plugin src/`, which scans the plugin's `src/` folders by name
  (`Aggregate/`, `StateChangeSlice/`, `StateViewSliceStream/`, `ReadModel/`,
  `Task/`, …) and wires every component it finds. You add a folder + file; the
  generator does the wiring. See [Plugin composition](#plugin-composition) below.
- **There is no `*EventLog.res` file.** The shared DCB event log is *implied* by
  the slices — each slice declares its own events, and the DCB log is their
  union. You never write an event-log type by hand.
:::

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

| State View Slice (Stream) | Events | Queryable view |
|---|---|---|
| `Products` | `ProductAdded`, `ProductNameChanged`, `ProductDescriptionChanged`, `ProductPriceChanged` | `Products` |

In the source these live in `catalog/src/Product/StateViewSliceStream/` — the
**Stream** variant projects into a live-updating view that pushes changes to
subscribed clients. (Use the non-stream `StateViewSlice` when you don't need
live updates.)

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

| State View Slice (Stream) | Events | Queryable view |
|---|---|---|
| `ProductDemand` | `ProductAdded`, `ProductDemandRecorded`, `ProductDemandRevoked` | `ProductDemand` |

**Why Product + ProductDemand share DCB?** ProductDemand uses the same `productId` tag as Product events. The `ProductDemand` view can query both in a single filtered read. The `RecordProductDemand` decision model can validate product existence — something that would require a cross-aggregate query in the aggregate-based approach.

### Read Model: `CatalogActivity`

A plugin-wide audit feed — one denormalised row per entity (a category or a
product) that has changed in the catalog. It is a **mixed-source** read model,
populated from **both** the Category aggregate's events **and** the Product DCB
log via a multi-source projection (`catalog/src/CatalogActivity/ReadModel/`).
Categories and Products use the non-stream `ReadModel` variant here.

| Read Model | Sources | State |
|---|---|---|
| `CatalogActivity` | Category aggregate + Product DCB log | `{name, kind: Category \| Product, lastChange: Added \| Renamed \| Archived}` |

This is the canonical example of a read model that spans an aggregate and a DCB
log in one projection — see [Mixed-source read models](/app/components/readmodel)
for the pattern.

### Task: `ImportProducts`

A background **Task** (`catalog/src/Task/ImportProducts.res`) that watches an S3
bucket (`product-imports`) for uploaded product files. It is the file-triggered
counterpart to the webhook-style `ImportProduct` InboundTranslationSlice above:
both ultimately produce `AddProduct` commands, but the Task reacts to bucket
uploads while the slice reacts to inbound webhook payloads.

### The shared Catalog DCB event log

There is **no `CatalogEventLog.res` file**. The shared DCB log is *implied* by
the Product and ProductDemand slices: each slice declares the events it produces,
and the log is their union. It contains **only Product and ProductDemand
events** — no Category events, because Category is an aggregate with its own
per-instance event log.

Conceptually, the events flowing through the shared Catalog DCB log are:

```rescript
// Illustrative union — assembled from the slices, not a file you write.

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

Compare this with the pure DCB implementation, whose Catalog log also carries `CategoryAdded`, `CategoryRenamed`, and `CategoryArchived`. In the hybrid approach those events live in the Category aggregate's own event log instead.

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
| `RefundOrder` | `IssueRefund` | `RefundIssued` |

`RefundOrder` is an **internal, admin-only** slice: its command is marked
`@noApi`, so it is not exposed on the public GraphQL API. It models a refund
workflow triggered after a cancellation rather than by an external client — a
small but realistic example of a command that exists for automation/operations
only.

| State View Slice (Stream) | Events | Queryable view |
|---|---|---|
| `Orders` | `OrderPlaced`, `OrderShipped`, `OrderCancelled` | `Orders` |

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

`EmailService` is a real (stubbed) domain service at
`ordering/src/Service/EmailService.res`. Keeping the integration behind a service
module is the recommended pattern: the slice depends on the service interface,
and only the service knows how to talk to the outside world.

### Chapter: CatalogProduct

A lightweight shadow copy of Catalog product data, kept in sync via Catalog's Extension Point. CatalogProduct events are tagged by `productId` in the shared DCB event log.

| State Change Slices | Commands | Events |
|---|---|---|
| `SyncCatalogProduct` | `SyncNewProduct`, `SyncPriceChange` | `CatalogProductSynced`, `CatalogProductPriceChanged` |

| State View Slice (Stream) | Events | Queryable view |
|---|---|---|
| `AvailableProducts` | `CatalogProductSynced`, `CatalogProductPriceChanged` | `AvailableProducts` |

**Why Order + CatalogProduct share DCB?** Both entities benefit from living in the same event log. The shared log means CatalogProduct sync events and Order events are available together, enabling the framework to deliver both in filtered reads for projections like `AvailableProductsView`.

**Cross-entity validation:** The `PlaceOrder` command uses a tagged array field (`productId: array<@s.matches(DcbTag.string) string>`) to reference product IDs. The runtime automatically builds a multi-clause OR query that fetches both Order events (by `orderId`) and CatalogProduct events (by each `productId`) into the same decision model — enabling PlaceOrder to reject orders referencing unknown products.

### The shared Ordering DCB event log

As in Catalog, there is **no `OrderingEventLog.res` file** — the shared DCB log
is implied by the Order and CatalogProduct slices. It contains **only Order and
CatalogProduct events** — no Customer events, because Customer is an aggregate
with its own per-instance event log.

Conceptually, the events flowing through the shared Ordering DCB log are:

```rescript
// Illustrative union — assembled from the slices, not a file you write.

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

Compare this with the pure DCB implementation, whose Ordering log also carries `CustomerRegistered`, `EmailChanged`, `AddressChanged`, and `CustomerDeactivated`. In the hybrid approach those events live in the Customer aggregate's own event log instead.

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

## Plugin composition

You do **not** hand-write the plugin composition root. A `prebuild` step runs
`generate-plugin src/`, which scans the plugin's folders by name and emits
`src/Plugin.res`. Adding a component is a matter of dropping a file into the
right folder — the generator wires it.

```json
// catalog/package.json
"scripts": {
  "generate": "generate-plugin src/",
  "prebuild": "pnpm run generate",
  "build": "rescript build"
}
```

The generator maps each folder to a functor and a `Plugin.make` argument:

| Folder | Generated as | `Plugin.make` argument |
|---|---|---|
| `Aggregate/` | `Platform.Aggregate.Make(Spec, Behavior, …)` | `~aggregates` |
| `StateChangeSlice/` | `Platform.StateChangeSlice.Make(Spec, Behavior)` | `~stateChangeSlices` |
| `StateViewSliceStream/` | `Platform.StateViewSliceStream.Make(Spec, Projection)` | `~stateViewSlices` |
| `ReadModel/` | `Platform.ReadModel.Make(Spec, Projections)` | `~readModels` |
| `ReadModelStream/` | `Platform.ReadModelStream.Make(Spec, Projections)` | `~readModels` |
| `InboundTranslationSlice/` | `Platform.InboundTranslationSlice.Make(Spec, Translation)` | `~inboundTranslationSlices` |
| `AutomationSlice/` | `Platform.AutomationSlice.Make(Spec, Automation)` | `~automationSlices` |
| `OutboundTranslationSlice/` | `Platform.OutboundTranslationSlice.Make(Spec, Translation)` | `~outboundTranslationSlices` |
| `Task/` | `Platform.Task.Make(Spec)` | `~tasks` |
| `ExtensionPoint/` | `Platform.ExtensionPoint.Make(Mapping)` | `~extensionPoints` |
| `Extension/` | `Platform.Extension.Make(Mapping)` | `~extensions` |

The "hybrid" is invisible in your source: because Catalog has both an
`Aggregate/` folder (Category) **and** `StateChangeSlice/` folders (Product,
ProductDemand), the generated `Plugin.make` call simply receives both
`~aggregates` **and** the DCB slice arrays. The framework routes aggregate
commands to per-instance event logs and DCB commands to the shared (implied)
DCB log.

### The generated `catalog/src/Plugin.res`

This file is committed to git (CI compiles it directly) but is regenerated on
every build — never edit it by hand:

```rescript
// AUTO-GENERATED — do not edit. Run `npm run generate` to update.
module Make = (Platform: ReventlessInfra.Platform.T) => {
  // StateChangeSlices (Product + ProductDemand — the DCB entities)
  module AddProductSlice = Platform.StateChangeSlice.Make(AddProduct, AddProduct_Behavior)
  module ChangeProductNameSlice = Platform.StateChangeSlice.Make(ChangeProductName, ChangeProductName_Behavior)
  // … ChangeProductDescription, ChangeProductPrice, RecordProductDemand

  // StateViewSliceStreams (live-updating views)
  module ProductsStreamSlice = Platform.StateViewSliceStream.Make(Products, Products_Projection)
  module ProductDemandStreamSlice = Platform.StateViewSliceStream.Make(ProductDemand, ProductDemand_Projection)

  // InboundTranslationSlices
  module ImportProductSlice = Platform.InboundTranslationSlice.Make(ImportProduct, ImportProduct_Translation)

  // Aggregates (Category — the independent entity)
  module CategoryAggregate = Platform.Aggregate.Make(
    Category, Category_Behavior, ReventlessInfra.NoEventMappings.Make(Category),
  )

  // ReadModels (non-stream)
  module CatalogActivityReadModel = Platform.ReadModel.Make(CatalogActivity, CatalogActivity_Projections)
  module CategoriesReadModel = Platform.ReadModel.Make(Categories, Categories_Projections)

  // Tasks
  module ImportProductsTask = Platform.Task.Make(ImportProducts)

  // ExtensionPoint (outbound) + Extension (inbound)
  module Products_ExtensionPoint = Platform.ExtensionPoint.Make(Products_ExtensionPointMapping)
  module Orders_Extension = Platform.Extension.Make(Orders_Extension.Mapping)

  let make = (~uiBundleUrl=?) =>
    Platform.Plugin.make(
      ~name="Catalog",
      ~heartbeatInterval=5,
      ~aggregates=[module(CategoryAggregate)],                    // ← aggregate entity
      ~readModels=[module(CatalogActivityReadModel), module(CategoriesReadModel)],
      ~tasks=[module(ImportProductsTask)],
      ~stateChangeSlices=[module(AddProductSlice), /* … */ module(RecordProductDemandSlice)], // ← DCB entities
      ~stateViewSlices=[module(ProductsStreamSlice), module(ProductDemandStreamSlice)],
      ~inboundTranslationSlices=[module(ImportProductSlice)],
      ~extensionPoints=[module(Products_ExtensionPoint)],
      ~extensions=[module(Orders_Extension)],
      // …a pluginStructure definition and an Auto UI manifest are also generated
    )
}
```

The key point: one generated `Plugin.make` receives **both** `~aggregates` (for
Category) and the DCB slice arrays (for Product/ProductDemand). The framework
handles the routing — aggregate commands go to per-instance event logs, DCB
commands go to the shared event log.

### The generated `ordering/src/Plugin.res`

Ordering is generated the same way. Its `make` wires:

- the **`Customer`** aggregate, with a **`Customers` ReadModelStream** (the
  live-updating read-model variant — `Platform.ReadModelStream.Make`);
- the Order and CatalogProduct **DCB slices** (`PlaceOrder`, `ShipOrder`,
  `CancelOrder`, `RefundOrder`, `SyncCatalogProduct`);
- the **`AutoShipOrder`** automation slice and the **`SendOrderConfirmation`**
  outbound-translation slice;
- the `Orders` and `AvailableProducts` `StateViewSliceStream` views;
- the `Orders` extension point (outbound) and `Products` extension (inbound).

Same hybrid pattern: one generated `Plugin.make` receives `~aggregates` for
Customer and the DCB slice arrays for Order/CatalogProduct.

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

---

**Next:** [Run it locally →](./run-locally) — start the whole shop on your machine
with the local platform.
