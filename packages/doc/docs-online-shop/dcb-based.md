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
| `ProductView` | `ProductAdded`, `ProductNameUpdated`, `ProductDescriptionUpdated`, `ProductPriceUpdated` | `Products` |

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
| `CustomerView` | `CustomerRegistered`, `EmailUpdated`, `AddressUpdated`, `CustomerDeactivated` | `Customers` |

### Chapter: Order

A confirmed purchase referencing product IDs and a customer. Order events are tagged by `orderId`.

| State Change Slices | Commands | Events |
|---|---|---|
| `PlaceOrder` | `PlaceOrder` | `OrderPlaced` |
| `ShipOrder` | `ShipOrder` | `OrderShipped` |
| `CancelOrder` | `CancelOrder` | `OrderCancelled` |

| State View Slices | Events | Read Models |
|---|---|---|
| `OrderView` | `OrderPlaced`, `OrderShipped`, `OrderCancelled` | `Orders` |

---

## Cross-Plugin Integration

As with the aggregate-based approach, `Order` references products by `ProductId` — integration by ID, not by object. Each Plugin still has its own DCB event log; they communicate only through IDs.

---

## Implementation

The following walkthrough uses the **ItemCatalog** example from `examples/dcb/`, covering create, rename, and archive operations for catalog items.

### 1. DCB Event Log Spec

The event log spec defines all events in the Plugin and marks which fields are **DCB tags** — indexed values the framework uses to filter events per item.

```rescript
// ItemEventLog.res

@schema
type event =
  | ItemCreated({itemId: @s.matches(Reventless.DcbTag.string) string, name: string})
  | ItemRenamed({itemId: @s.matches(Reventless.DcbTag.string) string, newName: string})
  | ItemArchived({itemId: @s.matches(Reventless.DcbTag.string) string})
```

The `@s.matches(Reventless.DcbTag.string)` annotation on `itemId` tells the framework to index that field as a tag. When a command handler requests events for a given `itemId`, only the matching subset is loaded from the shared log — even though all items share the same physical storage.

### 2. StateChangeSlices

Each command is handled by a **StateChangeSlice** — a self-contained module that defines:

- **`command`** — the command type it handles
- **`error`** — the business errors it can return
- **`decisionModel`** — the minimal state needed to validate the command
- **`reduce`** — how to fold events into the decision model
- **`decide`** — the business rule: given the current model, accept or reject the command

#### CreateItem

Rejects duplicate creation via optimistic concurrency: if `ItemCreated` is already in the log for this `itemId`, the command fails.

```rescript
// CreateItem.res

let name = "CreateItem"
module DcbEventLogSpec = ItemEventLog

@schema
type command =
  | CreateItem({
      itemId: @s.matches(Reventless.DcbTag.string) string,
      name: string,
    })

@schema
type error = | ItemAlreadyExists

type decisionModel = {exists: bool, archived: bool}

let initialDecisionModel = {exists: false, archived: false}

let reduce = (model, event) =>
  switch event {
  | ItemEventLog.ItemCreated(_) => {exists: true, archived: false}
  | ItemEventLog.ItemArchived(_) => {...model, archived: true}
  | _ => model
  }

let decide = (model, command) =>
  switch command {
  | CreateItem({itemId, name}) =>
    if model.exists { Error(ItemAlreadyExists) }
    else { Ok([ItemEventLog.ItemCreated({itemId, name})]) }
  }
```

#### RenameItem

Requires the item to exist and not be archived before accepting the rename.

```rescript
// RenameItem.res

let name = "RenameItem"
module DcbEventLogSpec = ItemEventLog

@schema
type command =
  | RenameItem({
      itemId: @s.matches(Reventless.DcbTag.string) string,
      newName: string,
    })

@schema
type error =
  | ItemNotFound
  | ItemAlreadyArchived

type decisionModel = {exists: bool, archived: bool}

let initialDecisionModel = {exists: false, archived: false}

let reduce = (model, event) =>
  switch event {
  | ItemEventLog.ItemCreated(_) => {exists: true, archived: false}
  | ItemEventLog.ItemArchived(_) => {...model, archived: true}
  | _ => model
  }

let decide = (model, command) =>
  switch command {
  | RenameItem({itemId, newName}) =>
    if !model.exists    { Error(ItemNotFound) }
    else if model.archived { Error(ItemAlreadyArchived) }
    else { Ok([ItemEventLog.ItemRenamed({itemId, newName})]) }
  }
```

#### ArchiveItem

Archives an item. Idempotent — if the item is already archived the command succeeds with no new events.

```rescript
// ArchiveItem.res

let name = "ArchiveItem"
module DcbEventLogSpec = ItemEventLog

@schema
type command = | ArchiveItem({itemId: @s.matches(Reventless.DcbTag.string) string})

@schema
type error = | ItemNotFound

type decisionModel = {exists: bool, archived: bool}

let initialDecisionModel = {exists: false, archived: false}

let reduce = (model, event) =>
  switch event {
  | ItemEventLog.ItemCreated(_) => {exists: true, archived: false}
  | ItemEventLog.ItemArchived(_) => {...model, archived: true}
  | _ => model
  }

let decide = (model, command) =>
  switch command {
  | ArchiveItem({itemId}) =>
    if !model.exists   { Error(ItemNotFound) }
    else if model.archived { Ok([]) } // idempotent — already archived
    else { Ok([ItemEventLog.ItemArchived({itemId})]) }
  }
```

### 3. StateViewSlice

A **StateViewSlice** builds the query-side projection. It consumes events from the shared log and emits `Set` instructions that update the read store keyed by `itemId`.

```rescript
// ItemView.res

let name = "ItemView"
module DcbEventLogSpec = ItemEventLog

@schema
type event = ItemEventLog.event

@schema
type state = {itemId: string, name: string, archived: bool}

let project = (existingState, event) =>
  switch event {
  | ItemEventLog.ItemCreated({itemId, name}) =>
      [ReventlessSpec.Projection.Set(itemId, {itemId, name, archived: false})]
  | ItemEventLog.ItemRenamed({itemId, newName}) =>
      switch existingState {
      | Some(state) =>
        [ReventlessSpec.Projection.Set(itemId, {...state, name: newName})]
      | None => []
      }
  | ItemEventLog.ItemArchived({itemId}) =>
      switch existingState {
      | Some(state) =>
        [ReventlessSpec.Projection.Set(itemId, {...state, archived: true})]
      | None => []
      }
  }
```

Unlike the aggregate-based read model, the `project` function receives the current stored state (`existingState`) directly — there is no separate event-to-read-model mapping layer.

### 4. Plugin

The plugin composes the DCB event log, all StateChangeSlices, and the StateViewSlice using any `Platform` implementation:

```rescript
// ItemCatalogPlugin.res

module Make = (Platform: ReventlessSpec.Platform.T) => {
  module ItemEventLogMaker = Platform.DcbEventLog.Make(ItemEventLog)

  module CreateItemSlice  = Platform.StateChangeSlice.Make(CreateItem)
  module RenameItemSlice  = Platform.StateChangeSlice.Make(RenameItem)
  module ArchiveItemSlice = Platform.StateChangeSlice.Make(ArchiveItem)

  module ItemViewSlice = Platform.StateViewSlice.Make(ItemView)

  module DcbSpec = ItemEventLog
}
```

At deploy time, the plugin is instantiated with a concrete platform — in-memory for tests, AWS for production. The shared event log and all slices are wired together by passing the same `dcbEventLog` instance to each slice.

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
