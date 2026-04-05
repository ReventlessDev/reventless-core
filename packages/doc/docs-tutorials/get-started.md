---
title: Tutorials Overview
sidebar_position: 1
---

# Tutorials — Online Shop Example

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

## Automation and Integration

Beyond the core write-side and read-side patterns, the Online Shop includes three additional features that demonstrate reactive automation, external input processing, and outbound side effects.

### Auto-Ship Order (Ordering)

When an order is placed, an automation automatically issues a `ShipOrder` command — closing the order lifecycle without manual intervention. In the aggregate-based approach this is a stateless **EventMapper** (fire-and-forget). In the DCB approach this is a stateful **AutomationSlice** with a TODO list that tracks pending shipments and marks them resolved when `OrderShipped` arrives.

```
OrderPlaced  ──►  [automation]  ──►  ShipOrder command  ──►  OrderShipped
```

This feature uses the existing `ShipOrder` command and `OrderShipped` event — no domain model changes are needed.

### Import Product from Supplier Feed (Catalog)

An external supplier system sends product data in its own format (SKU, title, unit price in cents, currency). A translation layer validates the input, converts the supplier format to domain fields (field renaming, unit conversion, currency validation), and publishes an `AddProduct` command. In the aggregate-based approach this is a file-triggered **Task** (CSV upload to S3). In the DCB approach this is a webhook-triggered **InboundTranslationSlice** with schema validation and an audit log.

```
External input  ──►  [anti-corruption layer]  ──►  AddProduct command
```

This feature reuses the existing `AddProduct` command — no domain model changes are needed.

### Send Order Confirmation Email (Ordering)

When an order is placed, a notification is sent to the customer via an external email service. In the aggregate-based approach this is a fire-and-forget **SideEffectHandler**. In the DCB approach this is an **OutboundTranslationSlice** with a TODO list providing per-item retry and status tracking.

```
OrderPlaced  ──►  [outbound handler]  ──►  EmailService.send(...)
```

This feature uses the existing `OrderPlaced` event — no domain model changes are needed. The email service call is stubbed for the example.

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

The same domain is implemented three times — once using each core Reventless plugin style:

| Implementation | Plugin Style | Consistency | Best For |
|---|---|---|---|
| [Aggregate-Based](./aggregate-based) | One event log per aggregate instance | Per aggregate instance | Traditional DDD, isolated entity lifecycles |
| [DCB-Based](./dcb-based) | Single shared event log with tag-filtered reads | Per command (optimistic) | Cross-entity consistency, simpler infrastructure |
| [Hybrid](./hybrid-based) | Mixed — aggregates for independent entities, DCB for interdependent entities | Per entity type | Best of both — isolated streams where simple, cross-entity decisions where needed |

All three implementations cover the full **Catalog** and **Ordering** Plugins — including cross-plugin integration — and serve as a concrete reference for comparing the approaches side by side.

### Package Structure

Each implementation is split into **five packages** — two spec packages containing only the public Extension Point contracts, two plugin packages with all internal business logic, and one platform assembly package that wires everything together:

| Package | Purpose |
|---|---|
| `catalog-spec` | Catalog's public Extension Point spec (`ProductsExtensionPoint`) — depended on by Ordering |
| `ordering-spec` | Ordering's public Extension Point spec (`OrdersExtensionPoint`) — depended on by Catalog |
| `catalog` | Catalog plugin implementation — aggregates/slices, read models, extension point mapping, extension |
| `ordering` | Ordering plugin implementation — aggregates/slices, read models, extension point mapping, extension |
| `online-shop-*` | Platform assembly — creates the in-memory platform, instantiates both plugins, wires the core |

The spec packages are the **only cross-plugin dependency**. Catalog depends on `ordering-spec` (to subscribe to its Extension Point), and Ordering depends on `catalog-spec` (to subscribe to its Extension Point). Neither plugin package imports the other plugin's internal modules — only spec packages cross the boundary.

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

#### Spec packages — the public contract

Each Plugin's Extension Point contract lives in a dedicated **spec package** (`catalog-spec`, `ordering-spec`) that is separate from the Plugin implementation. The spec package contains only the Extension Point definition — the `name`, `event`, `command`, and `directive` types that form the public API.

This separation is what makes cross-plugin integration possible without coupling: Catalog depends on `ordering-spec` (not on the `ordering` package), and Ordering depends on `catalog-spec` (not on `catalog`). The spec packages are small, stable, and change only when the public contract changes.

#### Extension Point — outbound API

An **Extension Point** is the contract a Plugin publishes for others to subscribe to. Its spec (in the spec package) defines:

- **`name`** — a stable string identifier shared by both sides (e.g. `"Catalog.Products"`). This is the only value that must match between the publishing Plugin and its subscribers.
- **`event`** — the public event vocabulary. These are intentionally different from internal event types so internal refactoring does not break the cross-plugin contract.
- **`command`** — inbound commands the Extension Point accepts (typically `unit` for read-only Extension Points).
- **`directive`** — reserved for framework use (typically `unit`).

An **Extension Point Mapping** sits in the publishing Plugin's implementation package (not the spec package). It translates internal events to Extension Point events using `PublishEvent(id, extensionPointEvent)`, deciding which internal events to expose and how to rename or reshape them for the public API.

#### Extension — inbound subscription

An **Extension** is the subscription a Plugin registers to receive events from another Plugin's Extension Point. It references the other Plugin's spec package and provides:

- An **Extension Mapping** — translates incoming Extension Point events to internal commands using `PublishAggregateCommand(id, command)` (aggregate-based) or the equivalent DCB form. One Extension can register multiple mappings if different Extension Point events route to different internal entities.

The subscribing Plugin depends only on the other Plugin's spec package — never on its implementation. This is what allows both Plugins to be deployed and versioned independently.

#### The components in this example

Each Plugin has an Extension Point (outbound) and an Extension (inbound), spread across spec and implementation packages:

| Component | Package | Direction | Purpose |
|---|---|---|---|
| `ProductsExtensionPoint` (spec) | `catalog-spec` | — | Public contract: `ProductBecameAvailable`, `ProductPriceChanged` |
| `ProductsExtensionPointMapping` | `catalog` | Catalog → Ordering | `ProductAdded` → `ProductBecameAvailable`, `ProductPriceUpdated` → `ProductPriceChanged` |
| `OrdersExtension` | `catalog` | Ordering → Catalog | `ItemOrdered` → `RecordDemand`, `ItemOrderCancelled` → `RevokeDemand` |
| `OrdersExtensionPoint` (spec) | `ordering-spec` | — | Public contract: `ItemOrdered`, `ItemOrderCancelled` |
| `OrdersExtensionPointMapping` | `ordering` | Ordering → Catalog | `OrderPlaced` → `ItemOrdered` (per product), `OrderCancelled` → `ItemOrderCancelled` |
| `ProductsExtension` | `ordering` | Catalog → Ordering | `ProductBecameAvailable` → `SyncCatalogProduct`, `ProductPriceChanged` → `SyncCatalogProduct` |

#### Dependency graph

```
catalog-spec ◄─── ordering (depends on Catalog's public EP contract)
ordering-spec ◄── catalog  (depends on Ordering's public EP contract)
```

Neither `catalog` nor `ordering` depends on each other's implementation — only on each other's spec package.

#### Why this protocol works

The Extension Point name is the only runtime coupling. At deploy time, both Plugins register their Extension Points and Extensions with the framework, which wires up the message routing. Neither Plugin needs to know how the other is deployed, what storage it uses, or even what language it is written in. The spec package separation enforces this boundary at the package level — it is structurally impossible to accidentally import another Plugin's internals.

---

## Comparing the Approaches

| Aspect | Aggregate-Based | DCB-Based | Hybrid |
|---|---|---|---|
| Event storage | One log per aggregate instance | Single shared log per Plugin | Both: per-aggregate logs + shared DCB log |
| Consistency boundary | Per aggregate instance (sequential) | Per command (optimistic concurrency) | Per entity type — aggregate or optimistic |
| State for decisions | Full aggregate state | Minimal `decisionModel` per slice | Both patterns coexist |
| Cross-entity consistency | Not directly supported | Supported — slices can read across items | Supported for DCB entities only |
| Read model wiring | Separate projection mapping modules | `project` function inline in the slice | Both patterns coexist |
| Infrastructure footprint | More event log tables | Fewer tables, more events per table | Middle ground |

Choose the aggregate-based approach when entity lifecycles are independent and you want the simplest possible consistency model. Choose DCB when you need consistency across multiple entities in the same command, or when you want to avoid the overhead of per-instance event streams.

### Combining Both Approaches

The framework supports both `~aggregates` and DCB slice arrays in the same `Plugin.make` call. This lets you model each entity with the approach that fits best:

- **Independent entities** — like Category and Customer — stay as aggregates with isolated event streams and per-instance consistency
- **Interdependent entities** — like Product + ProductDemand and Order + CatalogProduct — share a DCB event log with tag-filtered reads and per-command optimistic concurrency

The DCB event log in a hybrid Plugin is **smaller** than in the pure DCB approach because it excludes the aggregate entities' events. For example, the hybrid `CatalogEventLog` contains only Product and ProductDemand events — Category events live in the Category aggregate's own event log.

Cross-plugin communication via Extension Points is identical regardless of whether the source entity uses an aggregate or DCB internally. The EP contract abstracts away the internal modeling choice.

### Automation and Integration Components

The three additional features are implemented with different component types in each approach, highlighting the trade-offs:

| Feature | Aggregate-Based | DCB-Based | Hybrid |
|---|---|---|---|
| Auto-Ship Order | **EventMapper** | **AutomationSlice** | **AutomationSlice** (DCB) |
| Import Product from Supplier | **Task** (S3 file upload) | **InboundTranslationSlice** (webhook) | **InboundTranslationSlice** (DCB) |
| Send Order Confirmation Email | **SideEffectHandler** | **OutboundTranslationSlice** | **OutboundTranslationSlice** (DCB) |

Aggregate-based components are simpler but offer less built-in reliability. DCB-based slices provide more operational guarantees (retry, audit, status tracking) at the cost of additional infrastructure.
