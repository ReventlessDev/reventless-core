---
title: Aggregate-Based Implementation
sidebar_position: 2
---

# Aggregate-Based Implementation

The aggregate-based approach uses a **separate event log per aggregate instance**. Each entity in the domain is modelled as an aggregate with its own stream of events. Commands are processed by loading the aggregate's event history, running business logic, and appending new events to that aggregate's log.

This is the traditional event sourcing pattern and the starting point for most Reventless applications.

---

## Plugin 1: Catalog

Manages the product catalogue — what is available for sale and how it is organized.

### Aggregate: `Product`

A product listing with name, description, and price.

| Commands | Events |
|---|---|
| `AddProduct` | `ProductAdded` |
| `UpdateProductName` | `ProductNameUpdated` |
| `UpdateProductDescription` | `ProductDescriptionUpdated` |
| `UpdateProductPrice` | `ProductPriceUpdated` |

### Aggregate: `Category`

A named grouping of products (e.g. "Books", "Electronics"). `Product` aggregates reference a `CategoryId`.

| Commands | Events |
|---|---|
| `AddCategory` | `CategoryAdded` |
| `RenameCategory` | `CategoryRenamed` |
| `ArchiveCategory` | `CategoryArchived` |

### Aggregate: `ProductDemand`

Tracks per-product order demand. Driven entirely by events arriving from Ordering's Extension Point — no direct commands are sent by UI clients.

| Commands | Events |
|---|---|
| `RecordDemand` | `ProductDemandRecorded` |
| `RevokeDemand` | `ProductDemandRevoked` |

### Task: Import Products from CSV

A file-triggered Task that watches an S3 bucket for CSV uploads and publishes `Product.Add` commands for each row.

| Trigger | Action |
|---|---|
| S3 `ObjectCreated` on `product-imports` bucket | Parse file, publish `Product.Add` commands |

### Read Models

| Read Model | Source Aggregates | What It Tracks |
|---|---|---|
| `Products` | `Product` | All product listings with current name, description, and price |
| `Categories` | `Category` | All category names |
| `ProductDemand` | `Product` + `ProductDemand` | Per-product order count, initialized from `ProductAdded` |

### Extension Point: `ProductsExtensionPoint`

Outbound API from Catalog to Ordering. Translates internal `Product` events into a stable public vocabulary.

| EP Event | Triggered By |
|---|---|
| `ProductBecameAvailable` | `Product.ProductAdded` |
| `ProductPriceChanged` | `Product.ProductPriceUpdated` |

### Extension: `OrdersExtension`

Inbound subscription to Ordering's `OrdersExtensionPoint`. Routes demand events to `ProductDemand` aggregate commands.

| EP Event Received | Command Dispatched |
|---|---|
| `ItemOrdered` | `ProductDemand.RecordDemand` |
| `ItemOrderCancelled` | `ProductDemand.RevokeDemand` |

---

## Plugin 2: Ordering

Handles the purchase flow — who is buying and what they ordered.

### Aggregate: `Customer`

A registered buyer with contact details and account status.

| Commands | Events |
|---|---|
| `RegisterCustomer` | `CustomerRegistered` |
| `UpdateEmail` | `EmailUpdated` |
| `UpdateAddress` | `AddressUpdated` |
| `DeactivateCustomer` | `CustomerDeactivated` |

### Aggregate: `Order`

A confirmed purchase referencing `Product` IDs and a `CustomerId`. Clear, linear lifecycle.

| Commands | Events |
|---|---|
| `PlaceOrder` | `OrderPlaced` |
| `ShipOrder` | `OrderShipped` |
| `CancelOrder` | `OrderCancelled` |

### EventMapper: Auto-Ship Order

When an `Order.Placed` event is emitted, the EventMapper automatically issues an `Order.Ship` command for the same aggregate. Stateless fire-and-forget — no TODO list, no resolution tracking.

| Source Event | Target Command |
|---|---|
| `Order.Placed` | `Order.Ship` (same aggregate ID) |

### SideEffectHandler: Send Order Confirmation Email

When an `Order.Placed` event is emitted, a side effect calls a (stubbed) email service. Fire-and-forget — no retry tracking, no TODO list. Hosted on the `OrderNotifications` Task.

| Source Event | Side Effect |
|---|---|
| `Order.Placed` | `EmailService.sendOrderConfirmation` |

### Aggregate: `CatalogProduct`

A shadow replica of Catalog product data, kept in sync via Catalog's Extension Point. Allows Ordering to validate product references without querying Catalog at command time.

| Commands | Events |
|---|---|
| `SyncCatalogProduct` | `CatalogProductSynced` |

### Extension Point: `OrdersExtensionPoint`

Outbound API from Ordering to Catalog. Publishes order lifecycle events that Catalog's demand tracking subscribes to.

| EP Event | Triggered By |
|---|---|
| `ItemOrdered` | `Order.OrderPlaced` |
| `ItemOrderCancelled` | `Order.OrderCancelled` |

### Extension: `ProductsExtension`

Inbound subscription to Catalog's `ProductsExtensionPoint`. Routes product availability events to `CatalogProduct` aggregate commands.

| EP Event Received | Command Dispatched |
|---|---|
| `ProductBecameAvailable` | `CatalogProduct.SyncCatalogProduct` |
| `ProductPriceChanged` | `CatalogProduct.SyncCatalogProduct` |

---

## Cross-Plugin Integration

The two plugins communicate exclusively through Extension Points. Neither plugin imports the other's internal modules — only the shared EP specs are referenced.

```
Catalog                          Ordering
───────────────────────────────────────────────────────
ProductsExtensionPoint  ──────►  ProductsExtension
                                 (syncs CatalogProduct)

OrdersExtension  ◄──────────────  OrdersExtensionPoint
(updates ProductDemand)
```

---

## Implementation

The following walkthrough uses the **Catalog** Plugin from `examples/aggregate/catalog/` — the `Product` aggregate with its read model, the `ProductDemand` aggregate for demand tracking, the `ProductsExtensionPoint`, the `OrdersExtension`, and the `CatalogPlugin` that wires everything together.

### 1. Aggregate Spec

The spec module defines the vocabulary for the aggregate: its commands, the events it can emit, and the errors it can return.

```rescript
// Product.res

open Reventless
module Id = Id.String

let name = "Product"

@schema
type command =
  | AddProduct({productId: string, name: string, description: string, price: float})
  | UpdateProductName({productId: string, name: string})
  | UpdateProductDescription({productId: string, description: string})
  | UpdateProductPrice({productId: string, price: float})

@schema
type event =
  | ProductAdded({productId: string, name: string, description: string, price: float})
  | ProductNameUpdated({productId: string, name: string})
  | ProductDescriptionUpdated({productId: string, description: string})
  | ProductPriceUpdated({productId: string, price: float})

@schema
type error =
  | ProductAlreadyExists
  | ProductNotFound
```

The `@schema` attribute generates JSON serialization automatically via the Sury PPX — no hand-written encoders or decoders needed.

### 2. Behavior

The behavior module implements the aggregate's state machine. It defines the in-memory state type and provides four functions that the framework calls at runtime:

| Function | Called when |
|---|---|
| `init` | The first event is replayed (aggregate does not yet exist) |
| `apply` | Subsequent events are replayed to rebuild state |
| `create` | A command arrives for an aggregate that does not yet exist |
| `execute` | A command arrives for an aggregate that already exists |

```rescript
// ProductBehavior.res

open Reventless
open Product

module Spec = Product

@schema
type state = {name: string, description: string, price: float}

let init = event =>
  switch event {
  | ProductAdded({name, description, price}) => {name, description, price}
  | ProductNameUpdated(_)
  | ProductDescriptionUpdated(_)
  | ProductPriceUpdated(_) =>
    throw(Message.InvalidEvent(event->Message.encode(eventSchema)))
  }

let apply = (state, event) =>
  switch event {
  | ProductAdded({name, description, price}) => {name, description, price}
  | ProductNameUpdated({name})               => {...state, name}
  | ProductDescriptionUpdated({description}) => {...state, description}
  | ProductPriceUpdated({price})             => {...state, price}
  }

let create = (command, _context, errorHandler) =>
  switch command {
  | AddProduct({productId, name, description, price}) => [
      ProductAdded({productId, name, description, price}),
    ]
  | UpdateProductName(_)
  | UpdateProductDescription(_)
  | UpdateProductPrice(_) =>
    errorHandler(ProductNotFound, command, _context)
  }

let execute = (state, command, context, errorHandler) =>
  switch command {
  | AddProduct(_) =>
    errorHandler(ProductAlreadyExists, command, context)
  | UpdateProductName({name}) if name == state.name => []
  | UpdateProductName({productId, name}) =>
    [ProductNameUpdated({productId, name})]
  | UpdateProductDescription({description})
    if description == state.description => []
  | UpdateProductDescription({productId, description}) => [
      ProductDescriptionUpdated({productId, description}),
    ]
  | UpdateProductPrice({price}) if price == state.price => []
  | UpdateProductPrice({productId, price}) =>
    [ProductPriceUpdated({productId, price})]
  }
```

Update commands are idempotent: if the incoming value matches the current state the handler returns an empty event list, producing no write.

### 3. Read Model

The read model defines the query-side view and how aggregate events are projected into it.

```rescript
// ProductsReadModel.res

open Reventless
module Id = Id.String

@schema
type state = {
  productId: string,
  name: string,
  description: string,
  price: float,
}

let name = "Products"
```

Projection mappings subscribe to aggregate events and translate them to `Set` or `Update` instructions on the read model store:

```rescript
// ProductsProjections.res

open Reventless
open Reventless.Projection

module ProductMapping = Mapping.Make(
  Product,
  ProductsReadModel,
  {
    let map = ({Message.event: event, id, _}) =>
      switch event {
      | Product.ProductAdded({productId, name, description, price}) =>
        Projection.Set(id, {
          ProductsReadModel.productId,
          name,
          description,
          price,
        })
      | Product.ProductNameUpdated({name}) =>
        Update(id, state => {...state, name})
      | Product.ProductDescriptionUpdated({description}) =>
        Update(id, state => {...state, description})
      | Product.ProductPriceUpdated({price}) =>
        Update(id, state => {...state, price})
      }
  },
)

module Mappings = Mappings.Make(ProductsReadModel)

let mappings: array<module(Mappings.Mapping)> = [module(ProductMapping)]
```

A read model can consume events from **multiple aggregates**. The `ProductDemand` read model combines events from both `Product` (to initialise the entry) and `ProductDemand` (to track the order count):

```rescript
// ProductDemandProjections.res

open Reventless
open Reventless.Projection

module ProductMapping = Mapping.Make(
  Product,
  ProductDemandReadModel,
  {
    let map = ({Message.event: event, id, _}) =>
      switch event {
      | Product.ProductAdded({productId, name}) =>
        Set(id, {ProductDemandReadModel.productId, name, orderCount: 0})
      | _ => Ignore
      }
  },
)

module ProductDemandMapping = Mapping.Make(
  ProductDemand,
  ProductDemandReadModel,
  {
    let map = ({Message.event: event, id, _}) =>
      switch event {
      | ProductDemand.ProductDemandRecorded(_) =>
        Update(id, (state: ProductDemandReadModel.state) => {...state, orderCount: state.orderCount + 1})
      | ProductDemand.ProductDemandRevoked(_) =>
        Update(id, (state: ProductDemandReadModel.state) => {...state, orderCount: max(0, state.orderCount - 1)})
      }
  },
)

module Mappings = Mappings.Make(ProductDemandReadModel)

let mappings: array<module(Mappings.Mapping)> = [module(ProductMapping), module(ProductDemandMapping)]
```

### 4. Extension Point

An **Extension Point** is the outbound API that Catalog publishes for other Plugins to subscribe to. It has two parts: a **spec** (the stable public contract) and a **mapping** (the translation from internal events to EP events).

The spec defines the stable public vocabulary — the events that Ordering will depend on. This is intentionally different from the internal `Product` event types so that internal refactoring does not break the cross-plugin contract:

```rescript
// ProductsExtensionPointSpec.res

let name = "Catalog.Products"

@schema
type command = unit // read-only: no inbound commands

@schema
type event =
  | ProductBecameAvailable({productId: string, name: string, price: float})
  | ProductPriceChanged({productId: string, price: float})

@schema
type directive = unit
```

The mapping translates internal `Product` aggregate events to the stable EP vocabulary. Only events that Ordering needs to observe are mapped — everything else is ignored:

```rescript
// ProductsExtensionPointMapping.res

open Reventless.ExtensionPointMapping

module ExtensionPoint = ProductsExtensionPointSpec
module Aggregate = Product

let mapIncomingCommand = (_id, _command, _meta) => []

let mapOutgoingEvent = Some((_id, event, _meta, _queryEngine) =>
  switch event {
  | Product.ProductAdded({productId, name, price}) => [
      PublishEvent(
        productId,
        ProductsExtensionPointSpec.ProductBecameAvailable({productId, name, price}),
      ),
    ]
  | Product.ProductPriceUpdated({productId, price}) => [
      PublishEvent(productId, ProductsExtensionPointSpec.ProductPriceChanged({productId, price})),
    ]
  | _ => []
  }
)
```

`PublishEvent(id, event)` routes the EP event to all Extensions that have subscribed to this Extension Point.

### 5. Extension

An **Extension** is the inbound subscription that Catalog registers to receive events from Ordering's Extension Point. It has two parts: a **spec** (a local copy of Ordering's EP contract) and a **mapping** (the translation from EP events to internal commands).

The local spec copy allows Catalog to decode incoming events without depending on any Ordering module:

```rescript
// OrdersExtensionPointSpec.res

let name = "Ordering.Orders"

@schema
type command = unit

@schema
type event =
  | ItemOrdered({productId: string, orderId: string, customerId: string})
  | ItemOrderCancelled({productId: string, orderId: string})

@schema
type directive = unit
```

The mapping routes each incoming EP event to an aggregate command. Here, `ItemOrdered` triggers a `RecordDemand` command on the `ProductDemand` aggregate for the referenced product:

```rescript
// OrdersExtension.res

open Reventless.ExtensionMapping

module Spec = OrdersExtensionPointSpec

module DemandMappingImpl = {
  module ExtensionPoint = Spec
  module Aggregate = ProductDemand

  let mapIncomingEvent = (_id, event, _meta, _pluginDef, _queryEngine) =>
    switch event {
    | Spec.ItemOrdered({productId, orderId}) => [
        PublishAggregateCommand(
          productId,
          ProductDemand.RecordDemand({productId, orderId}),
        ),
      ]
    | Spec.ItemOrderCancelled({productId, orderId}) => [
        PublishAggregateCommand(
          productId,
          ProductDemand.RevokeDemand({productId, orderId}),
        ),
      ]
    }

  let mapOutgoingEvent = None
}

module DemandMappingT = ReventlessCore.ExtensionMapping.Make(Spec, DemandMappingImpl)

module Mappings = {
  module Spec = Spec
  module type Mapping = ReventlessCore.ExtensionMapping.T with module ExtensionPoint := Spec
  let name = "CatalogDemand"
  let mappings: array<module(Mapping)> = [module(DemandMappingT)]
}
```

`PublishAggregateCommand(id, command)` dispatches the command to the aggregate identified by `id` — in this case the `ProductDemand` aggregate for the given `productId`.

### 6. Plugin

The plugin wires all aggregates, read models, the Extension Point, and the Extension together using any `Platform` implementation. It is a pure composition root — no business logic lives here:

```rescript
// CatalogPlugin.res

open Reventless
open Reventless.Projection

module Make = (Platform: Platform.T) => {
  module ProductAggregate = Platform.Aggregate.Make(
    Product,
    ProductBehavior,
    NoEventMappings.Make(Product),
  )

  module CategoryAggregate = Platform.Aggregate.Make(
    Category,
    CategoryBehavior,
    NoEventMappings.Make(Category),
  )

  module ProductMappings: Mappings with module Target := ProductsReadModel = {
    module ProductMappings = Mappings.Make(ProductsReadModel)
    module type Mapping = ProductMappings.Mapping
    let mappings = ProductsProjections.mappings
  }

  module ProductReadModel = Platform.ReadModel.Make(ProductsReadModel, ProductMappings)

  module CategoryMappings: Mappings with module Target := CategoriesReadModel = {
    module CategoryMappings = Mappings.Make(CategoriesReadModel)
    module type Mapping = CategoryMappings.Mapping
    let mappings = CategoriesProjections.mappings
  }

  module CategoryReadModel = Platform.ReadModel.Make(CategoriesReadModel, CategoryMappings)

  // Demand tracking — driven by Ordering's OrdersExtensionPoint
  module ProductDemandAggregate = Platform.Aggregate.Make(
    ProductDemand,
    ProductDemandBehavior,
    NoEventMappings.Make(ProductDemand),
  )

  module ProductDemandMappings: Mappings with module Target := ProductDemandReadModel = {
    module ProductDemandMappings = Mappings.Make(ProductDemandReadModel)
    module type Mapping = ProductDemandMappings.Mapping
    let mappings = ProductDemandProjections.mappings
  }

  module ProductDemandReadModelMaker = Platform.ReadModel.Make(
    ProductDemandReadModel,
    ProductDemandMappings,
  )

  // Compile the Products extension point mapping, then build the EP component
  module ProductsEPMappingT = ReventlessCore.ExtensionPointMapping.Make(
    ProductsExtensionPointSpec,
    ProductsExtensionPointMapping,
  )
  module ProductsEPMappings = {
    module Spec = ProductsExtensionPointSpec
    module type Mapping = ExtensionPointMapping.T with module ExtensionPoint := Spec
    let mappings: array<module(Mapping)> = [module(ProductsEPMappingT)]
  }
  module ProductsExtensionPointMaker = Platform.ExtensionPoint.Make(
    ProductsExtensionPointSpec,
    ProductsEPMappings,
  )

  // Build the Orders extension (subscribing to Ordering's EP)
  module OrdersExtensionMaker = ReventlessCore.Extension_Builder.Make(
    OrdersExtensionPointSpec,
    OrdersExtension.Mappings,
  )
}
```

Swapping `Platform` is the only change needed to move from an in-memory test environment to a full AWS deployment.

### 7. EventMapper

An **EventMapper** routes events from one aggregate to commands on the same or a different aggregate. It replaces `NoEventMappings` as the third argument to `Platform.Aggregate.Make`.

Here, `Order.Placed` triggers an automatic `Order.Ship` command on the same aggregate:

```rescript
// Order_EventMappings.res

open Reventless

module Target = Order

module AutoShipMapping = {
  module Source = Order
  module Target = Order

  let map = (orderId, event, _queryEngine) =>
    switch event {
    | Order.Placed(_) => [EventMapping.Publish(orderId, Order.Ship)]
    | _ => []
    }
}

module type Mapping = EventMapping.T with module Target := Target

let mappings: array<module(Mapping)> = [module(AutoShipMapping)]

let counter = None
```

The EventMapper module satisfies the `EventMapper.Mappings` module type. Wire it into the plugin by replacing `NoEventMappings.Make(Order)`:

```rescript
module OrderAggregate = Platform.Aggregate.Make(
  Order,
  OrderBehavior,
  Order_EventMappings,  // was: NoEventMappings.Make(Order)
)
```

### 8. SideEffectHandler

A **SideEffectHandler** executes imperative side effects (e.g. sending emails, calling APIs) when aggregate events are emitted. Side effects are fire-and-forget — they do not produce new events or commands.

A side effect module defines the `Source` it subscribes to and an `execute` function:

```rescript
// Order_EmailNotification.res

module Source = {
  let name = Order.name
  module Id = Order.Id
  @schema type event = Order.event
}

let execute = async (orderId, _meta, event, _queryEngine) =>
  switch event {
  | Order.Placed({customerId}) =>
    await EmailService.sendOrderConfirmation(
      ~email=customerId,
      ~orderId=orderId->Order.Id.toString,
    )
  | _ => ()
  }
```

Side effects are hosted on a **Task**. The Task's `setup` function lists them in its `sideEffects` field:

```rescript
// OrderNotifications.res

open Reventless

let name = "OrderNotifications"

let setup = (_queryEngine, _queryBucketName, _opts) => {
  Task.sideEffects: [module(Order_EmailNotification): module(SideEffect.T)],
}
```

Wire the Task into the plugin:

```rescript
module OrderNotificationsTask = Platform.Task.Make(OrderNotifications)

// In Plugin.make:
~tasks=[module(OrderNotificationsTask)],
```

### 9. Task

A **Task** is a serverless handler triggered by S3 events. It can publish commands, manage schedules, and execute side effects.

Here, the `ImportProducts` Task watches an S3 bucket for CSV uploads and publishes `Product.Add` commands:

```rescript
// ImportProducts.res

open Reventless

let name = "ImportProducts"

let importCallback = (~eventName, ~key) => {
  if eventName->String.includes("ObjectCreated") {
    let meta: Message.meta = {
      service: "ImportProducts",
      time: Date.now()->Float.toString,
      ip: "",
      user: "system",
      msgId: key,
      correlationId: key,
    }

    [
      Task.PublishCommands(
        "Product",
        [{id: key, meta, commandJson: Product.Add({
            name: "Imported Product",
            description: "Imported from " ++ key,
            price: 9.99,
          })->Message.encode(Product.commandSchema)}],
      ),
    ]->Promise.resolve
  } else {
    []->Promise.resolve
  }
}

let setup = (_queryEngine, _queryBucketName, _opts) => {
  Task.buckets: [
    {
      bucketName: "product-imports",
      bucketMode: Task.Read,
      callback: importCallback,
    },
  ],
}
```

Wire the Task into the plugin:

```rescript
module ImportProductsTask = Platform.Task.Make(ImportProducts)

// In Plugin.make:
~tasks=[module(ImportProductsTask)],
```
