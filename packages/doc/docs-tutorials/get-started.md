---
title: Tutorials Overview
sidebar_position: 1
---

# Tutorials — Online Shop Example

A small, educational event-sourced application with two loosely-coupled Plugins —
**Catalog** and **Ordering** — that integrate by ID through a versioned Extension Point
protocol. The domain is familiar, maps cleanly onto event sourcing, and needs no saga,
which makes it a good first example.

## Plugin 1: Catalog

Manages the product catalogue — what is available for sale and how it is organized.
**Products** are listings with a name, description, and price; **Categories** are named
groupings products reference by ID.

### Product commands and events

| Command | Event | What Happens |
|---|---|---|
| `AddProduct` | `ProductAdded` | Registers a new product with its name, description, and price |
| `ChangeProductName` | `ProductNameChanged` | Renames an existing product |
| `ChangeProductDescription` | `ProductDescriptionChanged` | Updates a product's description |
| `ChangeProductPrice` | `ProductPriceChanged` | Changes a product's price |

`Change*` commands are **idempotent** — if the new value equals the current state, no event is written.

### Category commands and events

| Command | Event | What Happens |
|---|---|---|
| `AddCategory` | `CategoryAdded` | Creates a new named grouping |
| `RenameCategory` | `CategoryRenamed` | Renames a category |
| `ArchiveCategory` | `CategoryArchived` | Soft-deletes a category |

### ProductDemand commands and events

`ProductDemand` is an internal entity — never commanded directly by clients. It is driven by
events arriving from Ordering's Extension Point (see [Cross-Plugin Integration](#cross-plugin-integration)).

| Command | Event | What Happens |
|---|---|---|
| `RecordDemand` | `ProductDemandRecorded` | Records that an active order references this product |
| `RevokeDemand` | `ProductDemandRevoked` | Removes the record when the order is cancelled |

## Plugin 2: Ordering

Handles the purchase flow. **Customers** are registered buyers; **Orders** are confirmed
purchases referencing product IDs and a customer ID, with a linear lifecycle.

### Customer commands and events

| Command | Event | What Happens |
|---|---|---|
| `RegisterCustomer` | `CustomerRegistered` | Creates a new buyer account with name and contact details |
| `UpdateEmail` | `EmailUpdated` | Changes the customer's email address |
| `UpdateAddress` | `AddressUpdated` | Changes the customer's delivery address |
| `DeactivateCustomer` | `CustomerDeactivated` | Suspends the account — deactivated customers cannot place orders |

### Order commands and events

| Command | Event | What Happens |
|---|---|---|
| `PlaceOrder` | `OrderPlaced` | Creates a new order referencing product IDs and a customer ID |
| `ShipOrder` | `OrderShipped` | Marks the order as dispatched — terminal success state |
| `CancelOrder` | `OrderCancelled` | Cancels an order that has not yet shipped — terminal failure state |

The order lifecycle is strictly linear: `PlaceOrder` → `ShipOrder` or `CancelOrder`; neither is reversible.

### CatalogProduct (internal)

A lightweight shadow copy of Catalog product data that Ordering maintains so it can validate
and display product information at order time without querying Catalog. Its `SyncCatalogProduct`
command (event `CatalogProductSynced`) is driven by Catalog's Extension Point.

## Automation and Integration

Beyond the core write/read patterns, the example demonstrates three reactive features. Each
reuses an existing command or event — no domain-model changes are needed — and is implemented
with a different component type per approach (see [Choosing an approach](./choosing-an-approach)):

- **Auto-Ship Order** — when an order is placed, an automation issues `ShipOrder`.
  Aggregate: stateless **Event Mappings**; DCB: a stateful **AutomationSlice**.
- **Import Product from Supplier Feed** — an anti-corruption layer validates external supplier
  data and publishes `AddProduct`. Aggregate: a file-triggered **Task** (CSV→S3); DCB: a
  webhook **InboundTranslationSlice**.
- **Send Order Confirmation Email** — a notification on `OrderPlaced`. Aggregate: a fire-and-forget
  **Side Effect**; DCB: an **OutboundTranslationSlice** with per-item retry.

## Cross-Plugin Integration

The two Plugins communicate only through IDs and a defined Extension Point protocol — neither
imports the other's internal modules. (For how Extension Points and Extensions work, see the
[Plugin System](/app/plugin-system) guide.)

**Product Catalog Sync (Catalog → Ordering).** When Catalog adds or reprices a product it
publishes `ProductBecameAvailable` / `ProductPriceChanged` through its `ProductsExtensionPoint`.
Ordering's `ProductsExtension` dispatches `SyncCatalogProduct` to keep its shadow copy current.

**Demand Tracking (Ordering → Catalog).** When Ordering places or cancels an order it publishes
`ItemOrdered` / `ItemOrderCancelled` (carrying `productId` and `orderId`) through its
`OrdersExtensionPoint`. Catalog's `OrdersExtension` dispatches `RecordDemand` / `RevokeDemand`
to maintain a per-product active-order count.

The Extension Point **name** is the only runtime coupling; the public event vocabulary is kept
deliberately separate from internal events so refactoring never breaks the cross-plugin contract.

## Implementations

The same domain is implemented three times — once per Reventless plugin style:

| Implementation | Plugin Style | Consistency | Best For |
|---|---|---|---|
| [Aggregate-Based](./aggregate-based) | One event log per aggregate instance | Per aggregate instance | Traditional DDD, isolated entity lifecycles |
| [DCB-Based](./dcb-based) | Single shared event log with tag-filtered reads | Per command (optimistic) | Cross-entity consistency, simpler infrastructure |
| [Hybrid](./hybrid-based) | Aggregates for independent entities, DCB for interdependent ones | Per entity type | Best of both |

Each implementation is split into five packages: two **spec** packages holding only the public
Extension Point contracts (`catalog-spec`, `ordering-spec`), two **plugin** packages with the
internal logic (`catalog`, `ordering`), and one **platform** package that wires everything
together. The spec packages are the only cross-plugin dependency.

Every plugin is a functor `Make(Platform: ReventlessInfra.Platform.T)` — swap `ReventlessLocal`
for `ReventlessAws` to move from local development to production with no business-logic changes.

---

**Next:** [Choosing an approach →](./choosing-an-approach) — decide between
Aggregate, DCB, and Hybrid, then follow the recommended walkthrough.
