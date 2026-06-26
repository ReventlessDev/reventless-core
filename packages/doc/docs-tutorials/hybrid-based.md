---
title: Hybrid walkthrough
sidebar_position: 3
---

# Hybrid Implementation

The hybrid approach mixes **aggregate-based** and **DCB-based** components across an application — and, where it helps, within a single Plugin. Each entity gets the modeling strategy that fits best:

- **Independent entities** use aggregates — simple, isolated event streams with per-instance consistency
- **Interdependent entities** share a DCB event log — enabling cross-entity decision models with per-command optimistic concurrency

In this example: **Customer** stays an aggregate because its lifecycle is fully independent. **Category**, **Product + ProductDemand**, and **Order + CatalogProduct** are DCB slices because they take part in cross-slice invariants — most visibly, `AddProduct` verifies, inside its decision model, that the referenced **Category** exists and is active. A DCB slice can read a sibling slice's events from the shared log, but it cannot read an aggregate's isolated log; so the moment Product needs to consult Category, Category must be DCB too. The result: the **Ordering** plugin mixes an aggregate (Customer) with DCB slices, while the **Catalog** plugin is entirely DCB.

> Everything that isn't aggregate-vs-DCB-specific — translation slices, automations,
> extension points, extensions, and all cross-plugin wiring — is **identical** across the
> aggregate, DCB, and hybrid implementations. Only the entity modeling differs.

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

### DCB Entity: Category

A named grouping of products (e.g. "Books", "Electronics"). Category events are tagged by `categoryId` in the shared catalog DCB event log.

| State Change Slices | Commands | Events |
|---|---|---|
| `AddCategory` | `AddCategory` | `CategoryAdded` |
| `RenameCategory` | `RenameCategory` | `CategoryRenamed` |
| `ArchiveCategory` | `ArchiveCategory` | `CategoryArchived` |

| State View Slice (Stream) | Events | Queryable view |
|---|---|---|
| `Categories` | `CategoryAdded`, `CategoryRenamed`, `CategoryArchived` | `Categories` |

**Why DCB, not an aggregate?** On its own, Category's Add/Rename/Archive lifecycle would be a fine aggregate. But `AddProduct` must reject products that reference a non-existent or archived category, and it does so **inside its decision model** — it reads `CategoryAdded`/`CategoryArchived` events alongside the product's own events in a single filtered read. A DCB slice can read a sibling slice's events from the shared log, but not an aggregate's isolated log. So Category lives in the DCB log, tagged by `categoryId`, where the Product slice can consult it.

### DCB Entity: Product

A product listing with a name, description, price, and the `categoryId` it belongs to. Product events are tagged by `productId` in the shared DCB event log.

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

**Cross-entity validation:** The `AddProduct` command carries a `categoryId` (tagged in the DCB log). The runtime builds a multi-clause query that fetches the product's own events (by `productId`) **and** the referenced category's events (by `categoryId`) into one decision model — so `AddProduct` returns `CategoryNotFound` when the category is missing or archived, and `ProductAlreadyExists` for a duplicate. The emitted `ProductAdded` event carries `categoryId`, which the `Products` and `ProductDemand` views project onto their rows. This is the same mechanism Ordering's `PlaceOrder` uses to validate product references.

#### Inbound Translation: Import Product from Supplier

An **InboundTranslationSlice** receives external supplier data, validates it, and translates it into an `AddProduct` command.

| Inbound Translation Slice | External Input | Command Produced |
|---|---|---|
| `ImportProduct` | Supplier product JSON | `AddProduct` |

### DCB Entity: ProductDemand

Tracks per-product order demand. Driven entirely by events arriving from Ordering's Extension Point. Demand events are tagged by `productId` — the same tag as Product events, so the `ProductDemandView` can combine both in a single filtered read.

| State Change Slices | Commands | Events |
|---|---|---|
| `RecordProductDemand` | `RecordDemand`, `RevokeDemand` | `ProductDemandRecorded`, `ProductDemandRevoked` |

| State View Slice (Stream) | Events | Queryable view |
|---|---|---|
| `ProductDemand` | `ProductAdded`, `ProductDemandRecorded`, `ProductDemandRevoked` | `ProductDemand` |

**Why Product + ProductDemand share DCB?** ProductDemand uses the same `productId` tag as Product events. The `ProductDemand` view can query both in a single filtered read. The `RecordProductDemand` decision model can validate product existence — something that would require a cross-aggregate query in the aggregate-based approach.

> **Querying the catalog.** Every write-side entity here is a DCB slice, so the
> Catalog plugin has no `ReadModel`s — its query surface is the live-updating
> `StateViewSliceStream` views (`Categories`, `Products`, `ProductDemand`). For
> the canonical **mixed aggregate + DCB read model**, see Ordering's `Customers`
> below.

### Task: `ImportProducts`

A background **Task** (`catalog/src/Task/ImportProducts.res`) that watches an S3
bucket (`product-imports`) for uploaded product files. It is the file-triggered
counterpart to the webhook-style `ImportProduct` InboundTranslationSlice above:
both ultimately produce `AddProduct` commands, but the Task reacts to bucket
uploads while the slice reacts to inbound webhook payloads.

### The shared Catalog DCB event log

There is **no `CatalogEventLog.res` file**. The shared DCB log is *implied* by
the Category, Product, and ProductDemand slices: each slice declares the events
it produces, and the log is their union. Category events are tagged by
`categoryId`; Product and ProductDemand events by `productId`. Co-locating them
is what lets `AddProduct` read a category's lifecycle and the product's own
history in a single filtered decision read.

Conceptually, the events flowing through the shared Catalog DCB log are:

```rescript
// Illustrative union — assembled from the slices, not a file you write.
// `productId` lets Product and ProductDemand events be read together; `categoryId`
// lets AddProduct's decision model also pull in the referenced category's events.
@schema
type event =
  | CategoryAdded({categoryId: @s.matches(DcbTag.string) string, name: string})
  | CategoryRenamed({categoryId: @s.matches(DcbTag.string) string, name: string})
  | CategoryArchived({categoryId: @s.matches(DcbTag.string) string})
  | ProductAdded({productId: @s.matches(DcbTag.string) string, categoryId: @s.matches(DcbTag.string) string, name: string, /* … */})
  | ProductNameChanged({productId: @s.matches(DcbTag.string) string, name: string})
  // … ProductDescriptionChanged, ProductPriceChanged
  | ProductDemandRecorded({productId: @s.matches(DcbTag.string) string, orderId: string})
  | ProductDemandRevoked({productId: @s.matches(DcbTag.string) string, orderId: string})
```

The catalog log now carries the same Category, Product, and ProductDemand events
as the **pure DCB** implementation — Catalog is modelled identically in both. The
hybrid difference lives in **Ordering**, whose Customer remains an aggregate with
its own per-instance event log (see below).

### Extension Point: `ProductsExtensionPoint`

Outbound API from Catalog to Ordering. Translates internal Product events into a stable public vocabulary.

| EP Event | Triggered By |
|---|---|
| `ProductBecameAvailable` | `ProductAdded` |
| `ProductPriceChanged` | `ProductPriceChanged` |

### Extension: `OrdersExtension`

Inbound subscription to Ordering's `OrdersExtensionPoint`. Routes demand events to `RecordProductDemand` slice commands.

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

**Why an aggregate?** Customer's *write side* is fully independent — no cross-entity consistency with Order or CatalogProduct is needed, so its register/update/deactivate lifecycle is a natural fit for a simple aggregate. (The *read side* can still blend in other sources — see the `Customers` read model next.)

### Read Model: `Customers` (mixed aggregate + DCB)

The canonical **mixed-source** read model: one `Customers` row keyed by
`customerId`, fed by **two sources at once** —

| Source | Contributes | Events |
|---|---|---|
| `Customer` **aggregate** | profile + status | `Registered`, `EmailUpdated`, `AddressUpdated`, `Deactivated` |
| Ordering **DCB log** | `orderCount` | `OrderPlaced` (carries `customerId`) |

```rescript
type state = { email: string, address: string, deactivated: bool, orderCount: int }
```

Both source mappings live in `ordering/src/Customer/ReadModelStream/Customers_Projections.res`
and write to the **same row id** (`customerId`), so the framework merges an
aggregate's per-instance state with DCB events that reference it by a shared key.
Each mapping uses `UpdateWithDefault`, so the merge is order-independent — an
`OrderPlaced` arriving before its customer's `Registered` still creates the row.

This is the canonical place to study an **aggregate + DCB** projection — see
[Mixed-source read models](/app/components/readmodel) for the pattern. Note it is
a **`ReadModelStream`**: the same multi-source dispatch as a non-stream
`ReadModel`, plus live updates pushed to subscribed clients, so the blended
profile-and-order-count row updates in real time.

### DCB Entity: Order

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

An **AutomationSlice** automatically ships every placed order.

| Automation Slice | Trigger Event | Command Issued | Resolved By |
|---|---|---|---|
| `AutoShipOrder` | `OrderPlaced` | `ShipOrder` | `OrderShipped` |

#### Outbound Translation: Send Order Confirmation Email

An **OutboundTranslationSlice** sends a confirmation email whenever an order is placed.

| Outbound Translation Slice | Trigger Event | External Action |
|---|---|---|
| `SendOrderConfirmation` | `OrderPlaced` | Send email via `EmailService` |

`EmailService` is a real (stubbed) domain service at
`ordering/src/Service/EmailService.res`. Keeping the integration behind a service
module is the recommended pattern: the slice depends on the service interface,
and only the service knows how to talk to the outside world.

### DCB Entity: CatalogProduct

A lightweight shadow copy of Catalog product data, kept in sync via Catalog's Extension Point. CatalogProduct events are tagged by `productId` in the shared DCB event log.

| State Change Slices | Commands | Events |
|---|---|---|
| `SyncCatalogProduct` | `SyncNewProduct`, `ChangeSyncedPrice` | `CatalogProductSynced`, `CatalogProductPriceChanged` |

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
@schema
type event =
  | OrderPlaced({orderId: @s.matches(DcbTag.string) string, productIds: array<string>, /* … */})
  | OrderShipped({orderId: @s.matches(DcbTag.string) string})
  // … OrderCancelled
  | CatalogProductSynced({productId: @s.matches(DcbTag.string) string, name: string, price: float})
  | CatalogProductPriceChanged({productId: @s.matches(DcbTag.string) string, price: float})
```

Compare this with the pure DCB implementation, whose Ordering log also carries `CustomerRegistered`, `EmailChanged`, `AddressChanged`, and `CustomerDeactivated`. In the hybrid approach those events live in the Customer aggregate's own event log instead.

### Extension Point: `OrdersExtensionPoint`

Outbound API from Ordering to Catalog.

| EP Event | Triggered By |
|---|---|
| `ItemOrdered` | `OrderPlaced` |
| `ItemOrderCancelled` | `OrderCancelled` |

### Extension: `ProductsExtension`

Inbound subscription to Catalog's `ProductsExtensionPoint`.

| EP Event Received | Command Dispatched |
|---|---|
| `ProductBecameAvailable` | `SyncNewProduct` |
| `ProductPriceChanged` | `ChangeSyncedPrice` |

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

The "hybrid" is invisible in your source: a plugin that has both an `Aggregate/`
folder **and** `StateChangeSlice/` folders gets a generated `Plugin.make` call
that simply receives both `~aggregates` **and** the DCB slice arrays. The
framework routes aggregate commands to per-instance event logs and DCB commands
to the shared (implied) DCB log. **Ordering** is exactly this shape — a Customer
aggregate beside Order/CatalogProduct DCB slices — whereas **Catalog** has no
`Aggregate/` folder and is wired entirely from slices.

### The generated `catalog/src/Plugin.res`

This file is committed to git (CI compiles it directly) but is regenerated on
every build — never edit it by hand:

```rescript
// AUTO-GENERATED — do not edit. Run `npm run generate` to update.
module Make = (Platform: ReventlessInfra.Platform.T) => {
  // StateChangeSlices (Category + Product + ProductDemand — all DCB entities)
  module AddCategorySlice = Platform.StateChangeSlice.Make(AddCategory, AddCategory_Behavior)
  module AddProductSlice = Platform.StateChangeSlice.Make(AddProduct, AddProduct_Behavior)
  // … RenameCategory, ArchiveCategory, ChangeProductName/Description/Price, RecordProductDemand

  // StateViewSliceStreams (live-updating views)
  module CategoriesStreamSlice = Platform.StateViewSliceStream.Make(Categories, Categories_Projection)
  module ProductsStreamSlice = Platform.StateViewSliceStream.Make(Products, Products_Projection)
  module ProductDemandStreamSlice = Platform.StateViewSliceStream.Make(ProductDemand, ProductDemand_Projection)

  // InboundTranslationSlices
  module ImportProductSlice = Platform.InboundTranslationSlice.Make(ImportProduct, ImportProduct_Translation)

  // Tasks
  module ImportProductsTask = Platform.Task.Make(ImportProducts)

  // ExtensionPoint (outbound) + Extension (inbound)
  module Products_ExtensionPoint = Platform.ExtensionPoint.Make(Products_ExtensionPointMapping)
  module Orders_Extension = Platform.Extension.Make(Orders_Extension.Mapping)

  let make = (~uiBundleUrl=?) =>
    Platform.Plugin.make(
      ~name="Catalog",
      ~heartbeatInterval=5,
      ~tasks=[module(ImportProductsTask)],
      ~stateChangeSlices=[module(AddCategorySlice), module(AddProductSlice), /* … */ module(RecordProductDemandSlice)], // ← DCB entities
      ~stateViewSlices=[module(CategoriesStreamSlice), module(ProductsStreamSlice), module(ProductDemandStreamSlice)],
      ~inboundTranslationSlices=[module(ImportProductSlice)],
      ~extensionPoints=[module(Products_ExtensionPoint)],
      ~extensions=[module(Orders_Extension)],
      // …a pluginStructure definition and an Auto UI manifest are also generated
    )
}
```

The key point: Catalog has no `Aggregate/` folder, so its generated `Plugin.make`
takes no `~aggregates` — every write-side entity is a DCB slice. The hybrid mix
of `~aggregates` **and** DCB slice arrays in one `Plugin.make` is shown by
**Ordering** below.

### The generated `ordering/src/Plugin.res`

Ordering is generated the same way. Its `make` wires:

- the **`Customer`** aggregate, with a **`Customers` ReadModelStream** (the
  live-updating read-model variant — `Platform.ReadModelStream.Make`) — this is
  the **mixed aggregate + DCB** read model, fed by both the Customer aggregate
  and the Ordering DCB log (`orderCount`);
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

The hybrid boundary must be clean: entities that need cross-entity consistency **must** share
the same DCB event log; independent entities **should** be aggregates, since adding them to the
DCB log adds noise without benefit. Watch for the boundary shifting as requirements grow — Category
looked independent until `AddProduct` had to verify it, at which point it earned its place in the
DCB log. For the per-entity decision procedure, see
[Choosing an approach](./choosing-an-approach).

---

**Next:** [Run it locally →](./run-locally) — start the whole shop on your machine
with the local platform.
