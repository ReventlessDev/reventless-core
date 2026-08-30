---
title: The online shop example
sidebar_label: The online shop
---

# The online shop example

A small event-sourced application with two loosely-coupled plugins — **Catalog**
and **Ordering** — that integrate by ID through a versioned extension-point
protocol. The domain is familiar, maps cleanly onto event sourcing, and needs no
saga, which makes it a good first example.

This page describes what the shop *does*, in domain terms. You do not need to
read it before running the example: if you want to see it working first, go
straight to [Run it locally](./run-locally) or
[Deploy to your own AWS account](./deploy-to-aws).

## Plugin 1: Catalog

Manages the product catalogue — what is available for sale and how it is
organized. **Products** are listings with a name, description, price, and
optional image; **Categories** are named groupings that products reference by ID.

### Category commands and events

| Command | Event | What happens |
|---|---|---|
| `AddCategory` | `CategoryAdded` | Creates a new named grouping |
| `RenameCategory` | `CategoryRenamed` | Renames a category |
| `AttachCategoryImage`, `RemoveCategoryImage`, `SetPrimaryCategoryImage`, `SetCategoryImageAltText` | `CategoryImageAttached`, `CategoryImageRemoved`, `CategoryPrimaryImageSet`, `CategoryImageAltTextSet` | The category's attachment set: an ordered set of images with a primary and captions |
| `ArchiveCategory` | `CategoryArchived` | Withdraws the category from the catalogue |
| `UnarchiveCategory` | `CategoryUnarchived` | Returns an archived category to the catalogue |

### Product commands and events

| Command | Event | What happens |
|---|---|---|
| `AddProduct` | `ProductAdded` | Registers a new product — rejected if the referenced category is missing or archived |
| `ChangeProductName` | `ProductNameChanged` | Renames an existing product |
| `ChangeProductDescription` | `ProductDescriptionChanged` | Updates a product's description |
| `ChangeProductPrice` | `ProductPriceChanged` | Changes a product's price |
| `AttachProductImage`, `RemoveProductImage`, `SetPrimaryProductImage`, `SetProductImageAltText` | `ProductImageAttached`, `ProductImageRemoved`, `ProductPrimaryImageSet`, `ProductImageAltTextSet` | The product's attachment set: an ordered set of images with a primary and captions |
| `ArchiveProduct` | `ProductArchived` | Withdraws a product from sale, reversibly |
| `UnarchiveProduct` | `ProductUnarchived` | Returns an archived product to sale |
| `DiscontinueProduct` | `ProductDiscontinued` | Ends a product's life permanently |

`Change*` commands are **idempotent** — if the new value equals the current
state, no event is written. This matters because delivery is at-least-once: a
command that arrives twice must not produce two events.

Products can also be imported in bulk from a supplier feed, which validates
external data before issuing the same `AddProduct` command a person would.

### ProductDemand commands and events

`ProductDemand` is internal — never commanded directly by clients. It is driven
by events arriving from Ordering's extension point (see
[Cross-plugin integration](#cross-plugin-integration)).

| Command | Event | What happens |
|---|---|---|
| `RecordDemand` | `ProductDemandRecorded` | Records that an active order references this product |
| `RevokeDemand` | `ProductDemandRevoked` | Removes the record when the order is cancelled |

## Plugin 2: Ordering

Handles the purchase flow. **Customers** are registered buyers; **Orders** are
confirmed purchases referencing product IDs and a customer ID.

### Customer commands and events

| Command | Event | What happens |
|---|---|---|
| `Register` | `Registered` | Creates a new buyer account with name and contact details |
| `UpdateEmail` | `EmailUpdated` | Changes the customer's email address |
| `UpdateAddress` | `AddressUpdated` | Changes the customer's delivery address |
| `SetAddressLocation` / `SetLocation` | `AddressLocated` / `LocationSet` | Records geographic coordinates for the address |
| `MarkAddressUnresolvable` | `AddressUnresolvable` | Records that the address could not be located |
| `Deactivate` | `Deactivated` | Suspends the account |
| `Reactivate` | `Reactivated` | Restores a suspended account |

### Order commands and events

| Command | Event | What happens |
|---|---|---|
| `PlaceOrder` | `OrderPlaced` | Creates an order referencing product IDs, a customer ID, a shipping method (`Standard`, `Express`, or `Pickup`), and an optional delivery window — rejected if any product is unavailable |
| `ShipOrder` | `OrderShipped` | Marks the order as dispatched |
| `CancelOrder` | `OrderCancelled` | Cancels an order that has not yet shipped |
| `ReopenOrder` | `OrderReopened` | Returns a cancelled order to the placed state |

How an order leaves *placed* depends on the shipping method it was placed with.
`Express` orders are dispatched automatically; `Standard` orders wait for a batch
run to issue `ShipOrder`; `Pickup` orders are collected in store and never ship.
Only an order still in *placed* can be cancelled, so the method also determines
how long cancellation stays possible.

### CatalogProduct (internal)

A lightweight shadow copy of Catalog product data that Ordering maintains, so it
can validate and display product information at order time without querying
Catalog. Its commands (`SyncNewProduct`, `ChangeSyncedPrice`,
`WithdrawSyncedProduct`, `RelistSyncedProduct`) are driven by Catalog's extension
point, never by a client.

## What you can see and query

The shop maintains six live views, each kept current as events arrive and pushed
to connected clients as it changes:

| View | Plugin | Shows |
|---|---|---|
| `Categories` | Catalog | The category list, with archived ones marked |
| `Products` | Catalog | The catalogue, with price, image, and category |
| `ProductDemand` | Catalog | How many active orders reference each product |
| `AvailableProducts` | Ordering | What can currently be ordered |
| `Customers` | Ordering | Registered buyers and their order counts |
| `Orders` | Ordering | Orders and their lifecycle state |

## Automation and integration

Beyond the core write and read paths, the example demonstrates three reactive
features. Each reuses an existing command or event — no domain-model changes are
needed — and each is implemented differently depending on the plugin style (see
[Choosing an approach](./choosing-an-approach)):

- **Auto-ship order** — when an `Express` order is placed, an automation issues
  `ShipOrder` without anyone clicking anything.
- **Import products from a supplier feed** — external supplier data is validated
  and translated into `AddProduct` commands, so bad data is rejected at the
  boundary instead of corrupting the catalogue.
- **Send order confirmation email** — a notification triggered by `OrderPlaced`,
  with retry, kept outside the decision that accepted the order.

## Cross-plugin integration

The two plugins communicate only through IDs and a defined extension-point
protocol — neither imports the other's internal modules. (For how extension
points and extensions work, see the [Plugin System](/app/plugin-system) guide.)

**Product catalog sync (Catalog → Ordering).** When Catalog adds or reprices a
product it publishes `ProductBecameAvailable` / `ProductPriceChanged` through its
products extension point. Ordering's extension turns those into its own
`SyncNewProduct` / `ChangeSyncedPrice` commands to keep the shadow copy current.

**Demand tracking (Ordering → Catalog).** When Ordering places or cancels an
order it publishes `ItemOrdered` / `ItemOrderCancelled` (carrying `productId` and
`orderId`) through its orders extension point. Catalog's extension dispatches
`RecordDemand` / `RevokeDemand` to maintain a per-product active-order count.

The extension-point **name** is the only runtime coupling; the public event
vocabulary is kept deliberately separate from internal events, so refactoring one
plugin never breaks the cross-plugin contract.

## Three implementations of the same domain

The same shop is implemented three times — once per plugin style. The **hybrid**
one is the recommended reading, and the one the walkthrough follows;
[Choosing an approach](./choosing-an-approach) explains why, and the
[Understand the code](./choosing-an-approach) chapters cover all three.

---

**Next:** [Run it locally →](./run-locally) — no cloud account needed.
