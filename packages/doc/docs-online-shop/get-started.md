---
title: Overview
sidebar_position: 1
---

# Online Shop Example

A simple, educational event-sourced application covering two Plugins.

## Overview

The **Online Shop** domain is universally familiar and maps cleanly onto event sourcing concepts. It features two Plugins — **Catalog** and **Ordering** — illustrating different domain lifecycles and cross-context integration by ID.

## Why This Domain Works Well

| Property | Reason |
|---|---|
| Universal familiarity | Everyone understands an online shop |
| Clear domain lifecycles | Each concept has obvious, distinct state transitions |
| Cross-context reference | `Order` references `Product.id` — integration by ID |
| Different event shapes | `Category` is reference-like; `Order` is transactional |
| No saga required | Plugins are loosely coupled — good for a first example |

---

## Plugin 1: Catalog

Manages the product catalogue — what is available for sale and how it is organized.

**Products** are listings with a name, description, and price. **Categories** are named groupings (e.g. "Books", "Electronics") that products can reference by ID.

### Product commands and events

| Command | Event | What Happens |
|---|---|---|
| `AddProduct` | `ProductAdded` | Registers a new product with its name, description, and price |
| `UpdateProductName` | `ProductNameUpdated` | Renames an existing product |
| `UpdateProductDescription` | `ProductDescriptionUpdated` | Updates a product's description |
| `UpdateProductPrice` | `ProductPriceUpdated` | Changes a product's price |

Update commands are **idempotent** — if the new value is the same as the current state, no event is written.

### Category commands and events

| Command | Event | What Happens |
|---|---|---|
| `AddCategory` | `CategoryAdded` | Creates a new named grouping |
| `RenameCategory` | `CategoryRenamed` | Renames a category |
| `ArchiveCategory` | `CategoryArchived` | Soft-deletes a category |

### ProductDemand commands and events

`ProductDemand` is an internal entity — it is never commanded directly by clients. Instead it is driven by events arriving from Ordering's Extension Point (see [Cross-Plugin Integration](#cross-plugin-integration) below).

| Command | Event | What Happens |
|---|---|---|
| `RecordDemand` | `ProductDemandRecorded` | Records that an active order references this product |
| `RevokeDemand` | `ProductDemandRevoked` | Removes the record when the corresponding order is cancelled |

Both commands are idempotent — re-delivering the same event produces no duplicate write.

---

## Plugin 2: Ordering

Handles the purchase flow — who is buying and what they ordered.

**Customers** are registered buyers with contact details and account status. **Orders** are confirmed purchases referencing product IDs and a customer ID, with a clear linear lifecycle from placement to shipping or cancellation.

### Customer commands and events

| Command | Event | What Happens |
|---|---|---|
| `RegisterCustomer` | `CustomerRegistered` | Creates a new buyer account with name and contact details |
| `UpdateEmail` | `EmailUpdated` | Changes the customer's email address |
| `UpdateAddress` | `AddressUpdated` | Changes the customer's delivery address |
| `DeactivateCustomer` | `CustomerDeactivated` | Suspends the account — deactivated customers cannot place new orders |

### Order commands and events

| Command | Event | What Happens |
|---|---|---|
| `PlaceOrder` | `OrderPlaced` | Creates a new order with one or more line items referencing product IDs and a customer ID |
| `ShipOrder` | `OrderShipped` | Marks the order as dispatched — terminal success state |
| `CancelOrder` | `OrderCancelled` | Cancels an order that has not yet shipped — terminal failure state |

The order lifecycle is strictly linear: `PlaceOrder` → `ShipOrder` or `CancelOrder`. Neither shipping nor cancellation can be undone.

### CatalogProduct commands and events

`CatalogProduct` is an internal entity — a lightweight shadow copy of Catalog product data maintained by Ordering so it can validate and display product information at order time without querying Catalog directly.

| Command | Event | What Happens |
|---|---|---|
| `SyncCatalogProduct` | `CatalogProductSynced` | Updates the local copy when Catalog publishes a product availability or price change |

---

## Cross-Plugin Integration

The two Plugins are loosely coupled — they communicate only through IDs and through a defined Extension Point protocol. Neither Plugin imports the other's internal modules.

### Use case 1: Product Catalog Sync (Catalog → Ordering)

When Catalog adds a product, it publishes a `ProductBecameAvailable` event through its `ProductsExtensionPoint`. Ordering's `ProductsExtension` receives this event and dispatches a `SyncCatalogProduct` command to its own `CatalogProduct` entity.

This keeps a lightweight shadow copy of product data inside Ordering, enabling order validation and display without coupling Ordering to Catalog's internal structure or querying Catalog at command time. When a product's price changes, Catalog publishes `ProductPriceChanged` and Ordering updates its shadow copy in the same way.

```
Catalog                              Ordering
─────────────────────────────────────────────────────────
Product.ProductAdded
  └─ ProductsExtensionPoint  ──────►  ProductsExtension
       ProductBecameAvailable             └─ SyncCatalogProduct
                                              CatalogProduct.CatalogProductSynced

Product.ProductPriceUpdated
  └─ ProductsExtensionPoint  ──────►  ProductsExtension
       ProductPriceChanged                └─ SyncCatalogProduct
                                              CatalogProduct.CatalogProductSynced
```

### Use case 2: Demand Tracking (Ordering → Catalog)

When Ordering places an order, it publishes an `ItemOrdered` event through its `OrdersExtensionPoint`, carrying the `productId` and `orderId`. Catalog's `OrdersExtension` receives this event and dispatches a `RecordDemand` command to its `ProductDemand` entity for the referenced product.

This lets Catalog maintain a per-product active order count — useful for popularity ranking, inventory planning, or surfacing high-demand products. When an order is cancelled, Ordering publishes `ItemOrderCancelled` and Catalog revokes the demand record, decrementing the count.

```
Ordering                             Catalog
─────────────────────────────────────────────────────────
Order.OrderPlaced
  └─ OrdersExtensionPoint  ────────►  OrdersExtension
       ItemOrdered                        └─ RecordDemand
                                              ProductDemand.ProductDemandRecorded

Order.OrderCancelled
  └─ OrdersExtensionPoint  ────────►  OrdersExtension
       ItemOrderCancelled                 └─ RevokeDemand
                                              ProductDemand.ProductDemandRevoked
```

---

## Implementations

The same domain is implemented twice — once using each core Reventless plugin style:

| Implementation | Plugin Style | Consistency | Best For |
|---|---|---|---|
| [Aggregate-Based](./aggregate-based) | One event log per aggregate instance | Per aggregate instance | Traditional DDD, isolated entity lifecycles |
| [DCB-Based](./dcb-based) | Single shared event log with tag-filtered reads | Per command (optimistic) | Cross-entity consistency, simpler infrastructure |

Both implementations cover the full **Catalog** and **Ordering** Plugins — including cross-plugin integration — and serve as a concrete reference for comparing the two approaches side by side.

---

## Common Features

Despite their different consistency models, both implementations share the same structural patterns.

### Platform Abstraction

Every plugin is a module function `Make(Platform: Platform.T)`. Swapping the `Platform` argument is the only change needed to move between environments:

| Platform | Used For |
|---|---|
| `ReventlessInMemory` | Unit tests and local development |
| `ReventlessAws` | Production deployment on AWS |

No business logic changes are needed when switching platforms.

### Extension Point and Extension Protocol

Plugins communicate through **Extension Points** and **Extensions** — a stable, versioned API layer that decouples Plugins from each other's internals. The protocol is identical in both the aggregate-based and DCB-based implementations.

#### Extension Point — outbound API

An **Extension Point** is the contract a Plugin publishes for others to subscribe to. It defines:

- **`name`** — a stable string identifier shared by both sides (e.g. `"Catalog.Products"`). This is the only value that must match between the publishing Plugin and its subscribers.
- **`event`** — the public event vocabulary. These are intentionally different from internal event types so internal refactoring does not break the cross-plugin contract.
- **`command`** — inbound commands the Extension Point accepts (typically `unit` for read-only Extension Points).
- **`directive`** — reserved for framework use (typically `unit`).

An **Extension Point Mapping** sits next to the spec in the publishing Plugin. It translates internal events to Extension Point events using `PublishEvent(id, extensionPointEvent)`, deciding which internal events to expose and how to rename or reshape them for the public API.

#### Extension — inbound subscription

An **Extension** is the subscription a Plugin registers to receive events from another Plugin's Extension Point. It has two parts:

- A **local copy of the Extension Point spec** — the subscribing Plugin declares its own copy of the Extension Point's `name`, `event`, and `command` types. Only the spec is copied, never any internal modules. This is what allows both Plugins to be deployed and versioned independently.
- An **Extension Mapping** — translates incoming Extension Point events to internal commands using `PublishAggregateCommand(id, command)` (aggregate-based) or the equivalent DCB form. One Extension can register multiple mappings if different Extension Point events route to different internal entities.

#### The four components in this example

| Component | Lives In | Direction | Translates |
|---|---|---|---|
| `ProductsExtensionPointSpec` | Catalog | — | Public contract: `ProductBecameAvailable`, `ProductPriceChanged` |
| `ProductsExtensionPointMapping` | Catalog | Catalog → Ordering | `ProductAdded` → `ProductBecameAvailable`, `ProductPriceUpdated` → `ProductPriceChanged` |
| `OrdersExtensionPointSpec` (local copy) | Catalog | — | Local copy of Ordering's contract: `ItemOrdered`, `ItemOrderCancelled` |
| `OrdersExtension` | Catalog | Ordering → Catalog | `ItemOrdered` → `RecordDemand`, `ItemOrderCancelled` → `RevokeDemand` |

Ordering holds the symmetric counterparts: `OrdersExtensionPointSpec` (the original), `OrdersExtensionPointMapping`, a local copy of `ProductsExtensionPointSpec`, and `ProductsExtension`.

#### Why this protocol works

The Extension Point name is the only runtime coupling. At deploy time, both Plugins register their Extension Points and Extensions with the framework, which wires up the message routing. Neither Plugin needs to know how the other is deployed, what storage it uses, or even what language it is written in.

---

## Comparing the Two Approaches

| Aspect | Aggregate-Based | DCB-Based |
|---|---|---|
| Event storage | One log per aggregate instance | Single shared log per Plugin |
| Consistency boundary | Per aggregate instance (sequential) | Per command (optimistic concurrency) |
| State for decisions | Full aggregate state | Minimal `decisionModel` per slice |
| Cross-entity consistency | Not directly supported | Supported — slices can read across items |
| Read model wiring | Separate projection mapping modules | `project` function inline in the slice |
| Infrastructure footprint | More event log tables | Fewer tables, more events per table |

Choose the aggregate-based approach when entity lifecycles are independent and you want the simplest possible consistency model. Choose DCB when you need consistency across multiple entities in the same command, or when you want to avoid the overhead of per-instance event streams.
