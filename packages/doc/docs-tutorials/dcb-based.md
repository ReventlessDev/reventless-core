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
| `ChangeProductName` | `ChangeProductName` | `ProductNameChanged` |
| `ChangeProductDescription` | `ChangeProductDescription` | `ProductDescriptionChanged` |
| `ChangeProductPrice` | `ChangeProductPrice` | `ProductPriceChanged` |

| State View Slices | Events | Read Models |
|---|---|---|
| `Products` | `ProductAdded`, `ProductNameChanged`, `ProductDescriptionChanged`, `ProductPriceChanged` | `Products` |

#### Inbound Translation: Import Product from Supplier

An **InboundTranslationSlice** is an anti-corruption layer that receives external data, validates it, and translates it into an internal command. Unlike the other slice types, it is triggered by an explicit `receive` call (e.g. from an API endpoint), not by events.

`ImportProduct` accepts supplier JSON with SKU, title, description, unit price (in cents), and currency. It validates the input and translates it into an `AddProduct` command. Like every slice, it is **split** into a spec file (the types) and a `_Translation.res` body (the logic).

| Inbound Translation Slice | External Input | Command Produced |
|---|---|---|
| `ImportProduct` | Supplier product JSON | `AddProduct` |

```rescript
// Product/InboundTranslationSlice/ImportProduct.res
@@reventless.spec

@schema
type externalInput = {
  sku: string,
  title: string,
  desc: string,
  unitPrice: int,
  currency: string,
}

@schema
type command = AddProduct({
  productId: string,
  name: string,
  description: string,
  price: float,
})

let targetName = "AddProduct"
```

```rescript
// Product/InboundTranslationSlice/ImportProduct_Translation.res
@@reventless.translation

let translate = input =>
  if input.currency !== "USD" {
    Error("Unsupported currency: " ++ input.currency)
  } else if input.unitPrice <= 0 {
    Error("Price must be positive")
  } else if input.sku === "" {
    Error("SKU is required")
  } else {
    Ok([(
      input.sku,
      AddProduct({
        productId: input.sku,
        name: input.title,
        description: input.desc,
        price: Int.toFloat(input.unitPrice) /. 100.0,
      }),
    )])
  }
```

`translate` performs three validations (currency, price, SKU) before producing the command. It returns an **array** of `(id, command)` pairs — one slice invocation can fan out into several commands. The price is converted from cents to dollars. The SKU becomes the `productId` of the produced command, linking the imported product to the `AddProduct` StateChangeSlice (named via `targetName`) for duplicate detection. Inside a `*Slice/` folder the `@s.matches(Reventless.DcbTag.string)` tag annotation is applied automatically by `@@reventless.spec` — you never write it by hand.

The framework automatically exposes `Catalog_ImportProduct` as a GraphQL mutation. The `externalInput` fields become the mutation arguments (`sku`, `title`, `desc`, `unitPrice`, `currency`). No manual API wiring is needed — the resolver handles parsing, validation, translation, and command publishing internally.

### Chapter: Category

A named grouping of products (e.g. "Books", "Electronics"). Category events are tagged by `categoryId`. `Product` entities reference a `categoryId` by value.

| State Change Slices | Commands | Events |
|---|---|---|
| `AddCategory` | `AddCategory` | `CategoryAdded` |
| `RenameCategory` | `RenameCategory` | `CategoryRenamed` |
| `ArchiveCategory` | `ArchiveCategory` | `CategoryArchived` |

| State View Slices | Events | Read Models |
|---|---|---|
| `Categories` | `CategoryAdded`, `CategoryRenamed`, `CategoryArchived` | `Categories` |

### Chapter: ProductDemand

Tracks per-product order demand. Driven entirely by events arriving from Ordering's Extension Point. Demand events are tagged by `productId` — the same tag as `Product` events, so the `ProductDemand` view can combine both.

| State Change Slices | Commands | Events |
|---|---|---|
| `RecordProductDemand` | `RecordDemand`, `RevokeDemand` | `ProductDemandRecorded`, `ProductDemandRevoked` |

| State View Slices | Events | Read Models |
|---|---|---|
| `ProductDemand` | `ProductAdded`, `ProductDemandRecorded`, `ProductDemandRevoked` | `ProductDemand` |

### Extension Point: `Products_ExtensionPoint`

Outbound API from Catalog to Ordering. Translates internal catalog events into a stable public vocabulary.

| EP Event | Triggered By |
|---|---|
| `ProductBecameAvailable` | `ProductAdded` |
| `ProductPriceChanged` | `ProductPriceChanged` |

### Extension: `Orders_Extension`

Inbound subscription to Ordering's `Orders_ExtensionPoint`. Routes demand events to `RecordProductDemand` slice commands.

| EP Event Received | Command Dispatched |
|---|---|
| `ItemOrdered` | `RecordDemand` |
| `ItemOrderCancelled` | `RevokeDemand` |

---

## Plugin 2: Ordering

Handles the purchase flow — who is buying and what they ordered. Customer and order events share a single event log, with each entity identified by its own tag.

### Chapter: Customer

A registered buyer with contact details and account status. Customer events are tagged by `customerId`.

| State Change Slices | Commands | Events |
|---|---|---|
| `RegisterCustomer` | `RegisterCustomer` | `CustomerRegistered` |
| `ChangeEmail` | `ChangeEmail` | `EmailChanged` |
| `ChangeAddress` | `ChangeAddress` | `AddressChanged` |
| `DeactivateCustomer` | `DeactivateCustomer` | `CustomerDeactivated` |

| State View Slices | Events | Read Models |
|---|---|---|
| `Customers` | `CustomerRegistered`, `EmailChanged`, `AddressChanged`, `CustomerDeactivated` | `Customers` |

### Chapter: Order

A confirmed purchase referencing product IDs and a customer. Order events are tagged by `orderId`.

| State Change Slices | Commands | Events |
|---|---|---|
| `PlaceOrder` | `PlaceOrder` | `OrderPlaced` |
| `ShipOrder` | `ShipOrder` | `OrderShipped` |
| `CancelOrder` | `CancelOrder` | `OrderCancelled` |

| State View Slices | Events | Read Models |
|---|---|---|
| `Orders` | `OrderPlaced`, `OrderShipped`, `OrderCancelled` | `Orders` |

#### Automation: Auto-Ship Order

An **AutomationSlice** implements the TODO list pattern: it collects pending items from events, processes them by issuing commands, and resolves items when the expected outcome event arrives.

`AutoShipOrder` automatically ships every placed order. When `OrderPlaced` is emitted, a TODO item is created. The slice processes it by issuing a `ShipOrder` command. When `OrderShipped` arrives, the TODO item is resolved.

| Automation Slice | Trigger Event | Command Issued | Resolved By |
|---|---|---|---|
| `AutoShipOrder` | `OrderPlaced` | `ShipOrder` | `OrderShipped` |

The slice is split into a spec (the TODO item, command, and tuning) and an `_Automation.res` body. The body declares one or more **source modules** (each a `Mapping.Make` over the events it consumes) plus the `process` function. The consumed-event set is derived from the source mappings — there is no hand-written event-log union.

```rescript
// Order/AutomationSlice/AutoShipOrder.res
@@reventless.spec

@schema
type todoItem = {orderId: string}

@schema
type command = ShipOrder({orderId: string})

let maxRetries = 3
let heartbeatInterval = 60
let targetName = "ShipOrder"
```

```rescript
// Order/AutomationSlice/AutoShipOrder_Automation.res
@@reventless.automation

// Single DCB source — events from the ordering plugin's own event log.
module OrderingDcbSource = {
  let name = "OrderingDcbEventLog"
  @schema
  type event =
    | OrderPlaced({orderId: string})
    | OrderShipped({orderId: string})
}

module FromOrderingDcb = Mapping.Make(
  OrderingDcbSource,
  AutoShipOrder,
  {
    open OrderingDcbSource

    let collect = (event, _ctx) =>
      switch event {
      | OrderPlaced({orderId}) => [(orderId, ({orderId: orderId}: AutoShipOrder.todoItem))]
      | OrderShipped(_) => []
      }

    let resolve = event =>
      switch event {
      | OrderShipped({orderId}) => Some(orderId)
      | OrderPlaced(_) => None
      }
  },
)

let mappings: array<module(Mapping)> = [module(FromOrderingDcb)]

let process = (id, _item) => Some((id, ShipOrder({orderId: id})))
```

`collect` creates a TODO keyed by `orderId` whenever an order is placed. `resolve` marks the TODO as done when the corresponding `OrderShipped` event appears. `process` converts each pending TODO into a `ShipOrder` command targeting the same `orderId`.

#### Outbound Translation: Send Order Confirmation Email

An **OutboundTranslationSlice** bridges internal events to external systems. Like AutomationSlice it uses the TODO list pattern, but instead of issuing a command it calls an external service. The fire-and-forget variant returns `Ok(None)` — no command back into the system.

`SendOrderConfirmation` sends a confirmation email whenever an order is placed. It splits into a spec (the consumed event, outbound item, and tuning) and a `_Translation.res` body (the `collect` and `translate` pipelines).

| Outbound Translation Slice | Trigger Event | External Action |
|---|---|---|
| `SendOrderConfirmation` | `OrderPlaced` | Send email via `EmailService` |

```rescript
// Order/OutboundTranslationSlice/SendOrderConfirmation.res
@@reventless.spec

@schema
type consumedEvent =
  | OrderPlaced({orderId: string, customerId: string})

@schema
type outboundItem = {orderId: string, customerId: string}

@schema
type inboundCommand = unit

let maxRetries = 3
let heartbeatInterval = 60
let targetName = None
```

```rescript
// Order/OutboundTranslationSlice/SendOrderConfirmation_Translation.res
@@reventless.translation

let collect = event =>
  switch event {
  | OrderPlaced({orderId, customerId}) => [(orderId, {orderId, customerId})]
  }

let translate = async (_id, item) => {
  try {
    await EmailService.sendOrderConfirmation(
      ~email=item.customerId,
      ~orderId=item.orderId,
    )
    Ok(None)
  } catch {
  | exn =>
    let msg =
      exn
      ->JsExn.fromException
      ->Option.flatMap(JsExn.message)
      ->Option.getOr("email send failed")
    Error(msg)
  }
}
```

`collect` captures the order ID and customer ID from `OrderPlaced`. `translate` calls the external email service and returns `Ok(None)` on success (fire-and-forget — no command back; `targetName = None` signals no inbound command). On failure it returns `Error(msg)` so the framework can retry up to `maxRetries` times.

---

## Cross-Plugin Integration

As with the aggregate-based approach, `Order` references products by `ProductId` — integration by ID, not by object. Each Plugin still has its own DCB event log; they communicate only through Extension Points.

---

## Implementation

The following walkthrough uses the **Catalog** Plugin from `examples/online-shop-dcb/catalog/` — the `Product` chapter with its StateChangeSlices, StateViewSlices, the `ProductDemand` view for demand tracking, the `Products_ExtensionPoint`, the `Orders_Extension`, and the generated `Plugin` that wires everything together.

There is **no hand-written event-log spec file**. In the DCB approach the plugin's event log is simply the union of the events declared by its slices — each slice owns the events it produces (`event`) and the events it reads (`consumedEvent`). The framework assembles the shared log from these declarations. Every slice is **split** into a spec file (`@@reventless.spec`, the types) and a body file (`_Behavior.res`, `_Projection.res`, `_Translation.res`, or `_Automation.res`, the logic). Because the files live inside a `*Slice/` folder, `@@reventless.spec` automatically applies `@s.matches(Reventless.DcbTag.string)` to every `*Id` field — you never write the tag annotation by hand.

### 1. StateChangeSlices

Each command is handled by a **StateChangeSlice**, split across two files:

The **spec** declares:

- **`consumedEvent`** — the events this slice reads from the shared log to build its decision state
- **`command`** — the command type it handles
- **`error`** — the business errors it can return
- **`event`** — the events it produces on success

The **behavior** (`_Behavior.res`, `@@reventless.behavior`) declares:

- **`state`** — the minimal decision state needed to validate the command
- **`initialState`** — the starting value before any events are replayed
- **`evolve`** — how to fold consumed events into the decision state
- **`decide`** — the business rule: given the current state, accept or reject the command

#### AddProduct — creation

`AddProduct` creates a new product. The decision state only needs to know whether a product with this `productId` already exists. If it does, the command is rejected.

```rescript
// Product/StateChangeSlice/AddProduct.res
@@reventless.spec

@schema
type consumedEvent =
  | ProductAdded

@schema
type command =
  | AddProduct({
      productId: string,
      name: string,
      description: string,
      price: float,
    })

@schema
type error = ProductAlreadyExists

@schema
type event =
  | ProductAdded({
      productId: string,
      name: string,
      description: string,
      price: float,
    })
```

```rescript
// Product/StateChangeSlice/AddProduct_Behavior.res
@@reventless.behavior

type state = {exists: bool}

let initialState = {exists: false}

let evolve = (_state, event) =>
  switch event {
  | ProductAdded => {exists: true}
  }

let decide = (state, command) =>
  switch command {
  | AddProduct({productId, name, description, price}) =>
    if state.exists {
      Error(ProductAlreadyExists)
    } else {
      Ok([ProductAdded({productId, name, description, price})])
    }
  }
```

The `consumedEvent` type lists only `ProductAdded` — the framework delivers just those events (tag-filtered by `productId`) so `evolve` builds the single `exists` flag. The `decide` function checks the flag and either returns an error or emits a `ProductAdded` event.

#### ChangeProductPrice — update with idempotency

`ChangeProductPrice` modifies an existing product's price. The decision state tracks both existence and the current price, allowing the handler to reject unknown products and skip writes when the price has not changed.

```rescript
// Product/StateChangeSlice/ChangeProductPrice.res
@@reventless.spec

@schema
type consumedEvent =
  | ProductAdded({price: float})
  | ProductPriceChanged({price: float})

@schema
type command = ChangeProductPrice({productId: string, price: float})

@schema
type error = ProductNotFound

@schema
type event = ProductPriceChanged({productId: string, price: float})
```

```rescript
// Product/StateChangeSlice/ChangeProductPrice_Behavior.res
@@reventless.behavior

type state = {exists: bool, currentPrice: float}

let initialState = {exists: false, currentPrice: 0.0}

let evolve = (state, event) =>
  switch event {
  | ProductAdded({price}) => {exists: true, currentPrice: price}
  | ProductPriceChanged({price}) => {...state, currentPrice: price}
  }

let decide = (state, command) =>
  switch command {
  | ChangeProductPrice({productId, price}) =>
    if !state.exists {
      Error(ProductNotFound)
    } else if price == state.currentPrice {
      Ok([]) // idempotent — price unchanged
    } else {
      Ok([ProductPriceChanged({productId, price})])
    }
  }
```

`consumedEvent` lists both `ProductAdded` (to capture the initial price) and `ProductPriceChanged` (to track subsequent changes) — each declaring only the fields `evolve` needs. Returning `Ok([])` when the price is unchanged makes the command idempotent — safe to retry without side effects.

#### RecordProductDemand — driven by an Extension

`RecordProductDemand` is not called by UI clients. It is dispatched internally by the `Orders_Extension` whenever Ordering's Extension Point emits an `ItemOrdered` or `ItemOrderCancelled` event. The decision state tracks which order IDs have already been recorded to make the operation idempotent. Because this slice is the **target of an Extension**, its produced events mark `productId` with `@partitionTag` so the framework can derive the FIFO grouping id from the command.

```rescript
// Product/StateChangeSlice/RecordProductDemand.res
@@reventless.spec

@schema
type consumedEvent =
  | ProductDemandRecorded({orderId: string})
  | ProductDemandRevoked({orderId: string})

@schema
type command =
  | RecordDemand({productId: string, orderId: string})
  | RevokeDemand({productId: string, orderId: string})

@schema
type error = unit // always succeeds — demand recording is idempotent

@schema
type event =
  | ProductDemandRecorded({
      @partitionTag productId: string,
      orderId: string,
    })
  | ProductDemandRevoked({
      @partitionTag productId: string,
      orderId: string,
    })
```

```rescript
// Product/StateChangeSlice/RecordProductDemand_Behavior.res
@@reventless.behavior

type state = {recordedOrderIds: array<string>}
let initialState = {recordedOrderIds: []}

let evolve = (state, event) =>
  switch event {
  | ProductDemandRecorded({orderId}) => {
      recordedOrderIds: Array.concat(state.recordedOrderIds, [orderId]),
    }
  | ProductDemandRevoked({orderId}) => {
      recordedOrderIds: state.recordedOrderIds->Array.filter(id => id !== orderId),
    }
  }

let decide = (state, command) =>
  switch command {
  | RecordDemand({productId, orderId}) =>
    if state.recordedOrderIds->Array.includes(orderId) {
      Ok([]) // idempotent
    } else {
      Ok([ProductDemandRecorded({productId, orderId})])
    }
  | RevokeDemand({productId, orderId}) =>
    if !(state.recordedOrderIds->Array.includes(orderId)) {
      Ok([]) // idempotent
    } else {
      Ok([ProductDemandRevoked({productId, orderId})])
    }
  }
```

### 2. StateViewSlices

A **StateViewSlice** builds the query-side projection. It is split into a spec (the view `state` and the `consumedEvent` set it reacts to) and a `_Projection.res` body (`@@reventless.projection`, which brings `Set`, `Update`, `UpdateWithDefault`, and `Delete` into scope). The `project` function returns instructions that maintain the read store:

- **`Set(id, state)`** — creates or fully replaces the stored state for `id`
- **`Update(id, state => state)`** — applies a partial update to the existing state for `id`
- **`UpdateWithDefault(id, default, state => state)`** — updates if present, otherwise seeds with `default`

The view spec is named after the read model it produces — `Products`, not `ProductsView`.

#### Products

```rescript
// Product/StateViewSlice/Products.res
@@reventless.spec

@schema
type state = {productId: string, name: string, description: string, price: float}

@schema
type consumedEvent =
  | ProductAdded({productId: string, name: string, description: string, price: float})
  | ProductNameChanged({productId: string, name: string})
  | ProductDescriptionChanged({productId: string, description: string})
  | ProductPriceChanged({productId: string, price: float})
```

```rescript
// Product/StateViewSlice/Products_Projection.res
@@reventless.projection

let project = ({event}) =>
  switch event {
  | ProductAdded({productId, name, description, price}) => [
      Set(productId, {productId, name, description, price}),
    ]
  | ProductNameChanged({productId, name}) => [Update(productId, state => {...state, name})]
  | ProductDescriptionChanged({productId, description}) => [
      Update(productId, state => {...state, description}),
    ]
  | ProductPriceChanged({productId, price}) => [Update(productId, state => {...state, price})]
  }
```

`ProductAdded` uses `Set` because it establishes the full initial state for a new product. All subsequent events use `Update` because they only modify one field of an already-stored record. The view's `consumedEvent` type names exactly the events it cares about, so no catch-all `_ => []` branch is needed.

#### ProductDemand

A StateViewSlice can consume events from multiple chapters in the same shared log. `ProductDemand` reads both `ProductAdded` (to initialise the entry with the product name) and the demand events (to maintain the order count). `UpdateWithDefault` seeds the row on first sight and folds in later updates:

```rescript
// Product/StateViewSlice/ProductDemand.res
@@reventless.spec

@schema
type state = {productId: string, name: string, orderCount: int}

@schema
type consumedEvent =
  | ProductAdded({productId: string, name: string})
  | ProductDemandRecorded({productId: string})
  | ProductDemandRevoked({productId: string})
```

```rescript
// Product/StateViewSlice/ProductDemand_Projection.res
@@reventless.projection

let project = ({event}) =>
  switch event {
  | ProductAdded({productId, name}) =>
    [UpdateWithDefault(productId, {productId, name, orderCount: 0}, s => {...s, name})]
  | ProductDemandRecorded({productId}) =>
    [Update(productId, s => {...s, orderCount: s.orderCount + 1})]
  | ProductDemandRevoked({productId}) =>
    [Update(productId, s => {...s, orderCount: max(0, s.orderCount - 1)})]
  }
```

Because `ProductDemand` events use the `productId` tag — the same tag as `Product` events — the framework delivers both event types to this slice in a single filtered read. No cross-aggregate join is needed at query time.

Unlike the aggregate-based read model, the projection logic lives directly in the slice's `_Projection.res` body — no separate `Mapping.Make` module is needed.

### 3. Extension Point

An **Extension Point** is the outbound API that Catalog publishes for other Plugins to subscribe to. It has two parts: a **spec** (the stable public contract, in the `catalog-spec` package) and a **mapping** (the translation from internal events to EP events, in the `catalog` package).

The spec defines the stable public vocabulary — identical to the aggregate-based implementation because the EP contract is independent of the internal storage model. It lives in `catalog-spec/src/Products_ExtensionPoint.res`:

```rescript
// catalog-spec/src/Products_ExtensionPoint.res
@@reventless.spec

@schema
type command = unit // read-only: no inbound commands

@schema
type event =
  | ProductBecameAvailable({productId: string, name: string, price: float})
  | ProductPriceChanged({productId: string, price: float})

@schema
type directive = unit
```

The DCB mapping (`ExtensionPoint/Products_ExtensionPointMapping.res`, annotated `@@reventless.spec`) declares a `module Delegate` that carries just the events relevant to the extension point. Its `name` must equal `<pluginName>DcbEventLog` (here `"CatalogDcbEventLog"`) so the dispatch resolves to the topic the plugin registers under:

```rescript
// ExtensionPoint/Products_ExtensionPointMapping.res
@@reventless.spec

module ExtensionPoint = CatalogSpec.Products_ExtensionPoint

// DCB adapter: the event type used for outgoing event mapping.
// `name` MUST equal `<pluginName>DcbEventLog`.
module Delegate = {
  let name = "CatalogDcbEventLog"
  @schema
  type event =
    | ProductAdded({productId: string, name: string, description: string, price: float})
    | ProductPriceChanged({productId: string, price: float})
}

let mapIncomingCommand = (_id, _command, _meta) => []

let mapOutgoingEvent = Some((_id, event, _meta, _queryEngine) =>
  switch event {
  | Delegate.ProductAdded({productId, name, price}) => [
      PublishEvent(
        productId,
        CatalogSpec.Products_ExtensionPoint.ProductBecameAvailable({productId, name, price}),
      ),
    ]
  | Delegate.ProductPriceChanged({productId, price}) => [
      PublishEvent(productId, CatalogSpec.Products_ExtensionPoint.ProductPriceChanged({productId, price})),
    ]
  }
)
```

The mapping logic mirrors the aggregate-based approach — only the `module Delegate` declaration differs (a slim event type instead of a full aggregate spec).

### 4. Extension

An **Extension** is the inbound subscription that Catalog registers to receive events from Ordering's Extension Point. Catalog decodes the incoming events through Ordering's spec package (`ordering-spec`) — it never depends on Ordering's implementation.

The extension file (`Extension/Orders_Extension.res`, annotated `@@reventless.extension`) exposes a `module Mapping` naming the source Extension Point and the local `Delegate` slice (`RecordProductDemand`). It uses `PublishStateChangeSliceCommand` — no id is passed because the framework derives the FIFO grouping id from the command's `@partitionTag` field:

```rescript
// Extension/Orders_Extension.res
@@reventless.extension

module Mapping = {
  module ExtensionPoint = OrderingSpec.Orders_ExtensionPoint
  module Delegate = RecordProductDemand

  open ExtensionPoint
  open RecordProductDemand
  let mapIncomingEvent = (_id, event, _meta, _pluginDef, _queryEngine) =>
    switch event {
    | ItemOrdered({productId, orderId}) => [
        PublishStateChangeSliceCommand(RecordDemand({productId, orderId})),
      ]
    | ItemOrderCancelled({productId, orderId}) => [
        PublishStateChangeSliceCommand(RevokeDemand({productId, orderId})),
      ]
    }

  let mapOutgoingEvent = None
}
```

The mapping logic — routing `ItemOrdered` to `RecordDemand` and `ItemOrderCancelled` to `RevokeDemand` — is the same as in the aggregate-based approach. The only difference is that `Delegate` references a `StateChangeSlice` and the action is `PublishStateChangeSliceCommand` instead of `PublishAggregateCommand`.

### 5. Plugin

The plugin composes all StateChangeSlices, StateViewSlices, the InboundTranslationSlice, the Extension Point, and the Extension using any `Platform` implementation. **You do not write this file** — it is generated at `src/Plugin.res` by `generate-plugin`, which scans `src/` by folder name before each build. It carries an "AUTO-GENERATED — do not edit" banner. Each slice is wired with a two-argument `Make` (spec + body):

```rescript
// src/Plugin.res — AUTO-GENERATED — do not edit. Run `npm run generate` to update.
module Make = (Platform: ReventlessInfra.Platform.T) => {
  // StateChangeSlices
  module AddCategorySlice = Platform.StateChangeSlice.Make(AddCategory, AddCategory_Behavior)
  module AddProductSlice = Platform.StateChangeSlice.Make(AddProduct, AddProduct_Behavior)
  module ArchiveCategorySlice = Platform.StateChangeSlice.Make(ArchiveCategory, ArchiveCategory_Behavior)
  module ChangeProductDescriptionSlice = Platform.StateChangeSlice.Make(ChangeProductDescription, ChangeProductDescription_Behavior)
  module ChangeProductNameSlice = Platform.StateChangeSlice.Make(ChangeProductName, ChangeProductName_Behavior)
  module ChangeProductPriceSlice = Platform.StateChangeSlice.Make(ChangeProductPrice, ChangeProductPrice_Behavior)
  module RecordProductDemandSlice = Platform.StateChangeSlice.Make(RecordProductDemand, RecordProductDemand_Behavior)
  module RenameCategorySlice = Platform.StateChangeSlice.Make(RenameCategory, RenameCategory_Behavior)

  // StateViewSlices
  module CategoriesSlice = Platform.StateViewSlice.Make(Categories, Categories_Projection)
  module ProductDemandSlice = Platform.StateViewSlice.Make(ProductDemand, ProductDemand_Projection)
  module ProductsSlice = Platform.StateViewSlice.Make(Products, Products_Projection)

  // InboundTranslationSlices
  module ImportProductSlice = Platform.InboundTranslationSlice.Make(ImportProduct, ImportProduct_Translation)

  // ExtensionPoints
  module Products_ExtensionPoint = Platform.ExtensionPoint.Make(Products_ExtensionPointMapping)

  // Extensions
  module Orders_Extension = Platform.Extension.Make(Orders_Extension.Mapping)

  let make = () =>
    Platform.Plugin.make(
      ~name="Catalog",
      ~heartbeatInterval=5,
      ~extensionPoints=[module(Products_ExtensionPoint)],
      ~extensions=[module(Orders_Extension)],
      ~stateChangeSlices=[module(AddCategorySlice), module(AddProductSlice), module(ArchiveCategorySlice), module(ChangeProductDescriptionSlice), module(ChangeProductNameSlice), module(ChangeProductPriceSlice), module(RecordProductDemandSlice), module(RenameCategorySlice)],
      ~stateViewSlices=[module(CategoriesSlice), module(ProductDemandSlice), module(ProductsSlice)],
      ~inboundTranslationSlices=[module(ImportProductSlice)],
      // ...pluginStructure omitted for brevity
    )
}
```

The plugin is referenced from the platform assembly as `CatalogPlugin.Plugin.Make(Platform)` — note the `.Plugin.` segment. Swapping `Platform` is the only change needed to move from an in-memory test environment to a full AWS deployment:

```rescript
// platform-local/src/Main.res
module Platform = ReventlessLocal.Platform.Make()

module Catalog = CatalogPlugin.Plugin.Make(Platform)
module Ordering = OrderingPlugin.Plugin.Make(Platform)

Platform.makePlatform(
  ~version=Reventless.PackageVersion.fromCwd(),
  ~plugins=[module(Catalog), module(Ordering)],
)

Platform.startServers()
```
