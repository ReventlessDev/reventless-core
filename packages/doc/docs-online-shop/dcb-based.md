---
title: DCB-Based Implementation
sidebar_position: 3
---

# DCB-Based Implementation

The DCB (Dynamic Consistency Boundary) approach uses a **single shared event log** for a whole Plugin. Instead of one event stream per aggregate instance, all events from all entities live in the same log and are distinguished by **tags** — indexed fields embedded in every event payload.

A command handler reads only the events it cares about (filtered by tag), makes a decision, and appends new events while asserting that no conflicting events were written since it last read. This per-command optimistic concurrency replaces the per-instance locking of the traditional aggregate pattern.

---

## Plugin 1: Catalog

Manages the product catalogue — what is available for sale and how it is organized. In the DCB approach, all catalog events live in a single shared event log. Each entity is identified by a tag field embedded in its event payloads, which the framework uses to filter events for that specific entity when processing a command.

### Chapter: Product

A product listing with a name, description, and price. Product events are tagged by `productId`.

| State Change Slices | Commands | Events |
|---|---|---|
| `AddProduct` | `AddProduct` | `ProductAdded` |
| `UpdateProductName` | `UpdateProductName` | `ProductNameUpdated` |
| `UpdateProductDescription` | `UpdateProductDescription` | `ProductDescriptionUpdated` |
| `UpdateProductPrice` | `UpdateProductPrice` | `ProductPriceUpdated` |

| State View Slices | Events | Read Models |
|---|---|---|
| `ProductsView` | `ProductAdded`, `ProductNameUpdated`, `ProductDescriptionUpdated`, `ProductPriceUpdated` | `Products` |

### Chapter: Category

A named grouping of products (e.g. "Books", "Electronics"). Category events are tagged by `categoryId`. `Product` entities reference a `categoryId` by value.

| State Change Slices | Commands | Events |
|---|---|---|
| `AddCategory` | `AddCategory` | `CategoryAdded` |
| `RenameCategory` | `RenameCategory` | `CategoryRenamed` |
| `ArchiveCategory` | `ArchiveCategory` | `CategoryArchived` |

| State View Slices | Events | Read Models |
|---|---|---|
| `CategoryView` | `CategoryAdded`, `CategoryRenamed`, `CategoryArchived` | `Categories` |

---

## Plugin 2: Ordering

Handles the purchase flow — who is buying and what they ordered. Customer and order events share a single event log, with each entity identified by its own tag.

### Chapter: Customer

A registered buyer with contact details and account status. Customer events are tagged by `customerId`.

| State Change Slices | Commands | Events |
|---|---|---|
| `RegisterCustomer` | `RegisterCustomer` | `CustomerRegistered` |
| `UpdateEmail` | `UpdateEmail` | `EmailUpdated` |
| `UpdateAddress` | `UpdateAddress` | `AddressUpdated` |
| `DeactivateCustomer` | `DeactivateCustomer` | `CustomerDeactivated` |

| State View Slices | Events | Read Models |
|---|---|---|
| `CustomersView` | `CustomerRegistered`, `EmailUpdated`, `AddressUpdated`, `CustomerDeactivated` | `Customers` |

### Chapter: Order

A confirmed purchase referencing product IDs and a customer. Order events are tagged by `orderId`.

| State Change Slices | Commands | Events |
|---|---|---|
| `PlaceOrder` | `PlaceOrder` | `OrderPlaced` |
| `ShipOrder` | `ShipOrder` | `OrderShipped` |
| `CancelOrder` | `CancelOrder` | `OrderCancelled` |

| State View Slices | Events | Read Models |
|---|---|---|
| `OrdersView` | `OrderPlaced`, `OrderShipped`, `OrderCancelled` | `Orders` |

---

## Cross-Plugin Integration

As with the aggregate-based approach, `Order` references products by `ProductId` — integration by ID, not by object. Each Plugin still has its own DCB event log; they communicate only through IDs.

---

## Implementation

The following walkthrough uses the **Catalog** Plugin from `examples/dcb/catalog/` — the `Product` chapter with its StateChangeSlices, StateViewSlice, and the `CatalogPlugin` that wires everything together.

### 1. DCB Event Log Spec

The event log spec defines **all events in the Plugin** — from every chapter — in a single shared type. Tag fields are annotated with `@s.matches(DcbTag.string)` so the framework can index them and filter events by entity when processing a command.

```rescript
// CatalogEventLog.res

open ReventlessSpec
@schema
type event =
  | ProductAdded({
      productId: @s.matches(DcbTag.string) string,
      name: string,
      description: string,
      price: float,
    })
  | ProductNameUpdated({productId: @s.matches(DcbTag.string) string, name: string})
  | ProductDescriptionUpdated({
      productId: @s.matches(DcbTag.string) string,
      description: string,
    })
  | ProductPriceUpdated({productId: @s.matches(DcbTag.string) string, price: float})
  | CategoryAdded({categoryId: @s.matches(DcbTag.string) string, name: string})
  | CategoryRenamed({categoryId: @s.matches(DcbTag.string) string, name: string})
  | CategoryArchived({categoryId: @s.matches(DcbTag.string) string})
```

All events from `Product` and `Category` live in the same type. Each entity uses a different tag field name (`productId` vs `categoryId`), so the framework can filter precisely per entity.

### 2. StateChangeSlices

Each command is handled by a **StateChangeSlice** — a self-contained module that defines:

- **`command`** — the command type it handles
- **`error`** — the business errors it can return
- **`decisionModel`** — the minimal state needed to validate the command
- **`initialDecisionModel`** — the starting value before any events are replayed
- **`reduce`** — how to fold relevant events into the decision model
- **`decide`** — the business rule: given the current model, accept or reject the command

#### AddProduct — creation

`AddProduct` creates a new product. The decision model only needs to know whether a product with this `productId` already exists. If it does, the command is rejected.

```rescript
// AddProduct.res

open ReventlessSpec
open CatalogEventLog

let name = "AddProduct"
module DcbEventLogSpec = CatalogEventLog

@schema
type command =
  | AddProduct({
      productId: @s.matches(DcbTag.string) string,
      name: string,
      description: string,
      price: float,
    })

@schema
type error = | ProductAlreadyExists

type decisionModel = {exists: bool}

let initialDecisionModel = {exists: false}

let reduce = (model, event) =>
  switch event {
  | ProductAdded(_) => {exists: true}
  | _ => model
  }

let decide = (model, command) =>
  switch command {
  | AddProduct({productId, name, description, price}) =>
    if model.exists {
      Error(ProductAlreadyExists)
    } else {
      Ok([ProductAdded({productId, name, description, price})])
    }
  }
```

The `reduce` function only reacts to `ProductAdded` — any other event in the shared log is passed through unchanged. The `decide` function checks the single `exists` flag and either returns an error or emits a `ProductAdded` event.

#### UpdateProductPrice — update with idempotency

`UpdateProductPrice` modifies an existing product's price. The decision model tracks both existence and the current price, allowing the handler to reject unknown products and skip writes when the price has not changed.

```rescript
// UpdateProductPrice.res

open ReventlessSpec
open CatalogEventLog

let name = "UpdateProductPrice"
module DcbEventLogSpec = CatalogEventLog

@schema
type command =
  | UpdateProductPrice({productId: @s.matches(DcbTag.string) string, price: float})

@schema
type error = | ProductNotFound

type decisionModel = {exists: bool, currentPrice: float}

let initialDecisionModel = {exists: false, currentPrice: 0.0}

let reduce = (model, event) =>
  switch event {
  | ProductAdded({price}) => {exists: true, currentPrice: price}
  | ProductPriceUpdated({price}) => {...model, currentPrice: price}
  | _ => model
  }

let decide = (model, command) =>
  switch command {
  | UpdateProductPrice({productId, price}) =>
    if !model.exists {
      Error(ProductNotFound)
    } else if price == model.currentPrice {
      Ok([]) // idempotent — price unchanged
    } else {
      Ok([ProductPriceUpdated({productId, price})])
    }
  }
```

The `reduce` function reacts to both `ProductAdded` (to capture the initial price) and `ProductPriceUpdated` (to track subsequent changes). This is the pattern for update slices that need to compare against the current state. Returning `Ok([])` when the price is unchanged makes the command idempotent — safe to retry without side effects.

### 3. StateViewSlice

A **StateViewSlice** builds the query-side projection. It consumes events from the shared log and emits `Set` or `Update` instructions that maintain the read store.

There are two projection actions:

- **`Set(id, state)`** — creates or fully replaces the stored state for `id`
- **`Update(id, state => state)`** — applies a partial update to the existing state for `id`

```rescript
// ProductsView.res

open ReventlessSpec.Projection
open CatalogEventLog

let name = "ProductsView"
module DcbEventLogSpec = CatalogEventLog

@schema
type event = CatalogEventLog.event

@schema
type state = {productId: string, name: string, description: string, price: float}

let project = (_, event) =>
  switch event {
  | ProductAdded({productId, name, description, price}) => [
      Set(productId, {productId, name, description, price}),
    ]
  | ProductNameUpdated({productId, name}) => [Update(productId, state => {...state, name})]
  | ProductDescriptionUpdated({productId, description}) => [
      Update(productId, state => {...state, description}),
    ]
  | ProductPriceUpdated({productId, price}) => [Update(productId, state => {...state, price})]
  | _ => [] // Category events are not handled by this view
  }
```

`ProductAdded` uses `Set` because it establishes the full initial state for a new product. All subsequent events use `Update` because they only modify one field of an already-stored record — there is no need to re-specify fields that have not changed.

Unlike the aggregate-based read model, the projection logic lives directly in the slice — no separate mapping module is needed.

### 4. Plugin

The plugin composes the DCB event log, all StateChangeSlices, and all StateViewSlices using any `Platform` implementation:

```rescript
// CatalogPlugin.res

open ReventlessSpec
module Make = (Platform: Platform.T) => {
  module CatalogEventLogMaker = Platform.DcbEventLog.Make(CatalogEventLog)

  module AddProductSlice = Platform.StateChangeSlice.Make(AddProduct)
  module UpdateProductNameSlice = Platform.StateChangeSlice.Make(UpdateProductName)
  module UpdateProductDescriptionSlice = Platform.StateChangeSlice.Make(UpdateProductDescription)
  module UpdateProductPriceSlice = Platform.StateChangeSlice.Make(UpdateProductPrice)

  module ProductsViewSlice = Platform.StateViewSlice.Make(ProductsView)

  module AddCategorySlice = Platform.StateChangeSlice.Make(AddCategory)
  module RenameCategorySlice = Platform.StateChangeSlice.Make(RenameCategory)
  module ArchiveCategorySlice = Platform.StateChangeSlice.Make(ArchiveCategory)

  module CategoriesViewSlice = Platform.StateViewSlice.Make(CategoriesView)

  module DcbSpec = CatalogEventLog
}
```

The plugin is a pure composition root — no logic lives here. Swapping `Platform` is the only change needed to move from an in-memory test environment to a full AWS deployment.
