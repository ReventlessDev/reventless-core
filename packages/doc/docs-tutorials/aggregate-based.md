---
title: Aggregate-Based Implementation
---

# Aggregate-Based Implementation

The aggregate-based approach uses a **separate event log per aggregate instance**. Each entity in the domain is modelled as an aggregate with its own stream of events. Commands are processed by loading the aggregate's event history, running business logic, and appending new events to that aggregate's log.

This is the traditional event sourcing pattern and the starting point for most Reventless applications.

---

## Plugin 1: Catalog

Manages the product catalogue — what is available for sale and how it is organized.

### Aggregate: `Product`

A product listing with name, description, and price. Commands and events use short names scoped to the aggregate (`Product.Add`, `Product.Added`).

| Commands | Events |
|---|---|
| `Add` | `Added` |
| `UpdateName` | `NameUpdated` |
| `UpdateDescription` | `DescriptionUpdated` |
| `UpdatePrice` | `PriceUpdated` |

### Aggregate: `Category`

A named grouping of products (e.g. "Books", "Electronics"). `Product` aggregates reference a `categoryId`.

| Commands | Events |
|---|---|
| `Add` | `Added` |
| `Rename` | `Renamed` |
| `Archive` | `Archived` |

### Aggregate: `ProductDemand`

Tracks per-product order demand. Driven entirely by events arriving from Ordering's Extension Point — no direct commands are sent by UI clients.

| Commands | Events |
|---|---|
| `Record` | `Recorded` |
| `Revoke` | `Revoked` |

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
| `ProductDemands` | `Product` + `ProductDemand` | Per-product order count, initialized from `Product.Added` |

### Extension Point: `Products_ExtensionPoint`

Outbound API from Catalog to Ordering. Translates internal `Product` events into a stable public vocabulary.

| EP Event | Triggered By |
|---|---|
| `ProductBecameAvailable` | `Product.Added` |
| `ProductPriceChanged` | `Product.PriceUpdated` |

### Extension: `Orders_Extension`

Inbound subscription to Ordering's `Orders_ExtensionPoint`. Routes demand events to `ProductDemand` aggregate commands.

| EP Event Received | Command Dispatched |
|---|---|
| `ItemOrdered` | `ProductDemand.Record` |
| `ItemOrderCancelled` | `ProductDemand.Revoke` |

---

## Plugin 2: Ordering

Handles the purchase flow — who is buying and what they ordered.

### Aggregate: `Customer`

A registered buyer with contact details and account status.

| Commands | Events |
|---|---|
| `Register` | `Registered` |
| `UpdateEmail` | `EmailUpdated` |
| `UpdateAddress` | `AddressUpdated` |
| `Deactivate` | `Deactivated` |

### Aggregate: `Order`

A confirmed purchase referencing product IDs and a `customerId`. Clear, linear lifecycle.

| Commands | Events |
|---|---|
| `Place` | `Placed` |
| `Ship` | `Shipped` |
| `Cancel` | `Cancelled` |

### Event Mappings: Auto-Ship Order

When an `Order.Placed` event is emitted, an event mapping automatically issues an `Order.Ship` command for the same aggregate. Stateless fire-and-forget — no TODO list, no resolution tracking. The mappings live in `Order_Mappings.res` alongside the aggregate.

| Source Event | Target Command |
|---|---|
| `Order.Placed` | `Order.Ship` (same aggregate ID) |

### Side Effect: Send Order Confirmation Email

When an `Order.Placed` event is emitted, a side effect calls a (stubbed) email service. Fire-and-forget — no retry tracking, no TODO list. Hosted on the `OrderNotifications` Task.

| Source Event | Side Effect |
|---|---|
| `Order.Placed` | `EmailService.sendOrderConfirmation` |

### Aggregate: `CatalogProduct`

A shadow replica of Catalog product data, kept in sync via Catalog's Extension Point. Allows Ordering to validate product references without querying Catalog at command time.

| Commands | Events |
|---|---|
| `Sync` | `Synced` |
| `UpdatePrice` | `PriceUpdated` |

### Extension Point: `Orders_ExtensionPoint`

Outbound API from Ordering to Catalog. Publishes order lifecycle events that Catalog's demand tracking subscribes to. A batch `Order.Placed` (multiple product IDs) is decomposed into one `ItemOrdered` per product.

| EP Event | Triggered By |
|---|---|
| `ItemOrdered` | `Order.Placed` (one per product) |
| `ItemOrderCancelled` | `Order.Cancelled` (one per product) |

### Extension: `Products_Extension`

Inbound subscription to Catalog's `Products_ExtensionPoint`. Routes product availability events to `CatalogProduct` aggregate commands.

| EP Event Received | Command Dispatched |
|---|---|
| `ProductBecameAvailable` | `CatalogProduct.Sync` |
| `ProductPriceChanged` | `CatalogProduct.UpdatePrice` |

---

## Cross-Plugin Integration

The two plugins communicate exclusively through Extension Points. Neither plugin imports the other's internal modules — only the shared EP specs are referenced.

```
Catalog                            Ordering
───────────────────────────────────────────────────────
Products_ExtensionPoint  ──────►  Products_Extension
                                  (syncs CatalogProduct)

Orders_Extension  ◄─────────────  Orders_ExtensionPoint
(updates ProductDemand)
```

---

## Implementation

The following walkthrough uses the **Catalog** Plugin from `examples/online-shop-aggregates/catalog/` — the `Product` aggregate with its read model, the `ProductDemand` aggregate for demand tracking, the `Products_ExtensionPoint`, the `Orders_Extension`, and the generated `Plugin` that wires everything together.

Each component is **split** into a spec file (`<Name>.res`, annotated `@@reventless.spec`) and a body file (e.g. `<Name>_Behavior.res`, `<Name>_Projections.res`). The PPX auto-injects boilerplate — `let name`, `module Id`, `let moduleUrl`, the `open`/`module Spec` lines, projection mapping wrappers, read-model `config`, default authorization, and visibility — so the source you write contains only domain logic. The folder a file lives in (`Aggregate/`, `ReadModel/`, `Task/`, …) tells the PPX and the plugin generator what kind of component it is.

### 1. Aggregate Spec

The spec module defines the vocabulary for the aggregate: its commands, the events it can emit, and the errors it can return. It lives in `Product/Aggregate/Product.res`. The `@@reventless.spec` annotation derives `let name = "Product"` from the filename and injects `module Id` and `let moduleUrl` — you write only the types.

```rescript
// Product/Aggregate/Product.res
@@reventless.spec

@schema
type command =
  | Add({name: string, description: string, price: float})
  | UpdateName({name: string})
  | UpdateDescription({description: string})
  | UpdatePrice({price: float})

@schema
type event =
  | Added({name: string, description: string, price: float})
  | NameUpdated({name: string})
  | DescriptionUpdated({description: string})
  | PriceUpdated({price: float})

@schema
type error =
  | ProductAlreadyExists
  | ProductNotFound
```

The `@schema` attribute generates JSON serialization automatically via the Sury PPX — no hand-written encoders or decoders needed. The aggregate ID is supplied by the framework at command time, so it is not part of the command or event payloads.

### 2. Behavior

The behavior module implements the aggregate's state machine. It lives next to the spec at `Product/Aggregate/Product_Behavior.res` and is annotated `@@reventless.behavior`, which auto-injects `open Spec` / `module Spec = Product` (derived from the filename) and `let moduleUrl`. It defines the state type and three functions that the framework calls at runtime:

| Value | Role |
|---|---|
| `initialState` | The starting state before any event is replayed (a "not yet created" instance) |
| `evolve` | Folds the current state and an event into the next state; called once per historic event during replay |
| `decide` | Takes the current state and a command, returns `result<array<event>, error>` — `Ok([...])` accepts, `Error(err)` rejects |

```rescript
// Product/Aggregate/Product_Behavior.res
@@reventless.behavior

@schema
type state =
  | NotCreated
  | Created({name: string, description: string, price: float})

let initialState = NotCreated

let evolve = (state, event) =>
  switch (state, event) {
  | (NotCreated, Added({name, description, price})) => Created({name, description, price})
  | (Created(_), Added({name, description, price})) => Created({name, description, price})
  | (Created(s), NameUpdated({name})) => Created({...s, name})
  | (Created(s), DescriptionUpdated({description})) => Created({...s, description})
  | (Created(s), PriceUpdated({price})) => Created({...s, price})
  | (NotCreated, _) => state
  }

let decide = (state, command) =>
  switch (state, command) {
  | (NotCreated, Add({name, description, price})) =>
    Ok([Added({name, description, price})])
  | (NotCreated, UpdateName(_)) => Error(ProductNotFound)
  | (NotCreated, UpdateDescription(_)) => Error(ProductNotFound)
  | (NotCreated, UpdatePrice(_)) => Error(ProductNotFound)
  | (Created(_), Add(_)) => Error(ProductAlreadyExists)
  | (Created(s), UpdateName({name})) if name == s.name => Ok([])
  | (Created(_), UpdateName({name})) => Ok([NameUpdated({name: name})])
  | (Created(s), UpdateDescription({description})) if description == s.description => Ok([])
  | (Created(_), UpdateDescription({description})) =>
    Ok([DescriptionUpdated({description: description})])
  | (Created(s), UpdatePrice({price})) if price == s.price => Ok([])
  | (Created(_), UpdatePrice({price})) => Ok([PriceUpdated({price: price})])
  }
```

Update commands are idempotent: if the incoming value matches the current state `decide` returns `Ok([])`, producing no write.

### 3. Read Model

The read model is also split: a spec file `Product/ReadModel/Products.res` (the shape of the stored view) and a projections file `Product/ReadModel/Products_Projections.res` (how events maintain it). Inside a `ReadModel/` folder, `@@reventless.spec` auto-injects `let config` and `let subIdConfig = None` for you.

```rescript
// Product/ReadModel/Products.res
@@reventless.spec

@schema
type state = {
  name: string,
  description: string,
  price: float,
}
```

The projections file is annotated `@@reventless.mappings`, which infers the domain from the `ReadModel/` folder, brings `Mapping`, `Set`, `Update`, etc. into scope, and emits the `module type Mapping` wrapper. You write the per-source `Mapping.Make` modules and the `let mappings` array. Each mapping's `project` function returns a `Set` or `Update` action on the read model store:

```rescript
// Product/ReadModel/Products_Projections.res
@@reventless.mappings

module ProductMapping = Mapping.Make(
  Product,
  Products,
  {
    open Product
    let project = ({event, id, _}) =>
      switch event {
      | Added({name, description, price}) =>
        Set(id, {Products.name: name, description, price})
      | NameUpdated({name}) => Update(id, state => {...state, name})
      | DescriptionUpdated({description}) =>
        Update(id, state => {...state, description})
      | PriceUpdated({price}) => Update(id, state => {...state, price})
      }
  },
)

let mappings: array<module(Mapping)> = [module(ProductMapping)]
```

A read model can consume events from **multiple aggregates**. The `ProductDemands` read model (`ProductDemand/ReadModel/ProductDemands.res`) combines events from both `Product` (to initialise the entry) and `ProductDemand` (to track the order count). Its projections file declares one `Mapping.Make` per source:

```rescript
// ProductDemand/ReadModel/ProductDemands_Projections.res
@@reventless.mappings

module ProductMapping = Mapping.Make(
  Product,
  ProductDemands,
  {
    open Product
    let project = ({event, id, _}) =>
      switch event {
      | Added({name}) =>
        Set(id, {ProductDemands.name: name, orderCount: 0})
      | _ => Ignore
      }
  },
)

module ProductDemandMapping = Mapping.Make(
  ProductDemand,
  ProductDemands,
  {
    open ProductDemand
    let project = ({event, id, _}) =>
      switch event {
      | Recorded(_) =>
        Update(id, (state: ProductDemands.state) => {...state, orderCount: state.orderCount + 1})
      | Revoked(_) =>
        Update(id, (state: ProductDemands.state) => {...state, orderCount: max(0, state.orderCount - 1)})
      }
  },
)

let mappings: array<module(Mapping)> = [module(ProductMapping), module(ProductDemandMapping)]
```

### 4. Extension Point

An **Extension Point** is the outbound API that Catalog publishes for other Plugins to subscribe to. It has two parts: a **spec** (the stable public contract, living in the `catalog-spec` package) and a **mapping** (the translation from internal events to EP events, in the `catalog` package).

The spec defines the stable public vocabulary — the events that Ordering will depend on. This is intentionally different from the internal `Product` event types so that internal refactoring does not break the cross-plugin contract. It lives in `catalog-spec/src/Products_ExtensionPoint.res`; in a `*Spec` namespace `@@reventless.spec` derives the dotted name `"Catalog.Products"` automatically:

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

The mapping (`ExtensionPoint/Products_ExtensionPointMapping.res`) translates internal `Product` aggregate events to the stable EP vocabulary. It is annotated `@@reventless.spec`, which brings `PublishEvent` into scope. The internal aggregate is referenced as `module Delegate = Product`. Only events that Ordering needs to observe are mapped — everything else is ignored:

```rescript
// ExtensionPoint/Products_ExtensionPointMapping.res
@@reventless.spec

module ExtensionPoint = CatalogSpec.Products_ExtensionPoint
module Delegate = Product

let mapIncomingCommand = (_id, _command, _meta) => []

let mapOutgoingEvent = Some((id, event, _meta, _queryEngine) =>
  switch event {
  | Product.Added({name, price}) => [
      PublishEvent(id, CatalogSpec.Products_ExtensionPoint.ProductBecameAvailable({productId: id, name, price})),
    ]
  | Product.PriceUpdated({price}) => [
      PublishEvent(id, CatalogSpec.Products_ExtensionPoint.ProductPriceChanged({productId: id, price})),
    ]
  | _ => []
  }
)
```

`PublishEvent(id, event)` routes the EP event to all Extensions that have subscribed to this Extension Point.

### 5. Extension

An **Extension** is the inbound subscription that Catalog registers to receive events from Ordering's Extension Point. Catalog decodes the incoming events through Ordering's spec package (`ordering-spec`) — it never depends on Ordering's implementation.

The extension file (`Extension/Orders_Extension.res`) is annotated `@@reventless.extension`, which brings `PublishAggregateCommand` into scope. It exposes a `module Mapping` that names the source Extension Point and the internal `Delegate` aggregate, then routes each incoming EP event to a command. Here, `ItemOrdered` triggers a `Record` command on the `ProductDemand` aggregate for the referenced product:

```rescript
// Extension/Orders_Extension.res
@@reventless.extension

module Mapping = {
  module ExtensionPoint = OrderingSpec.Orders_ExtensionPoint
  module Delegate = ProductDemand

  open ExtensionPoint
  open Delegate
  let mapIncomingEvent = (_id, event, _meta, _pluginDef, _queryEngine) =>
    switch event {
    | ItemOrdered({productId, orderId}) => [
        PublishAggregateCommand(productId, Record({orderId: orderId})),
      ]
    | ItemOrderCancelled({productId, orderId}) => [
        PublishAggregateCommand(productId, Revoke({orderId: orderId})),
      ]
    }

  let mapOutgoingEvent = None
}
```

`PublishAggregateCommand(id, command)` dispatches the command to the aggregate identified by `id` — in this case the `ProductDemand` aggregate for the given `productId`. When the local target is a StateChangeSlice instead of an Aggregate, use `PublishStateChangeSliceCommand(command)`; the framework derives the FIFO grouping id from the command's `@partitionTag` field, so no id argument is needed.

### 6. Plugin

The plugin wires all aggregates, read models, the Extension Point, the Extension, and the Task together using any `Platform` implementation. **You do not write this file** — it is generated at `src/Plugin.res` by `generate-plugin`, which scans `src/` by folder name and emits the composition root before each build. It carries an "AUTO-GENERATED — do not edit" banner. Each component is wired with a two-argument `Make` (spec + body); aggregates take a third argument for their event mappings (`NoEventMappings.Make(<Spec>)` when there are none):

```rescript
// src/Plugin.res — AUTO-GENERATED — do not edit. Run `npm run generate` to update.
module Make = (Platform: ReventlessInfra.Platform.T) => {
  // Aggregates
  module CategoryAggregate = Platform.Aggregate.Make(
    Category,
    Category_Behavior,
    ReventlessInfra.NoEventMappings.Make(Category),
  )
  module ProductAggregate = Platform.Aggregate.Make(
    Product,
    Product_Behavior,
    ReventlessInfra.NoEventMappings.Make(Product),
  )
  module ProductDemandAggregate = Platform.Aggregate.Make(
    ProductDemand,
    ProductDemand_Behavior,
    ReventlessInfra.NoEventMappings.Make(ProductDemand),
  )

  // ReadModels
  module CategoriesReadModel = Platform.ReadModel.Make(Categories, Categories_Projections)
  module ProductDemandsReadModel = Platform.ReadModel.Make(ProductDemands, ProductDemands_Projections)
  module ProductsReadModel = Platform.ReadModel.Make(Products, Products_Projections)

  // Tasks
  module ImportProductsTask = Platform.Task.Make(ImportProducts)

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
      ~aggregates=[module(CategoryAggregate), module(ProductAggregate), module(ProductDemandAggregate)],
      ~readModels=[module(CategoriesReadModel), module(ProductDemandsReadModel), module(ProductsReadModel)],
      ~tasks=[module(ImportProductsTask)],
      // ...pluginStructure and AutoUI manifest omitted for brevity
    )
}
```

The plugin is referenced from the platform assembly as `CatalogPlugin.Plugin.Make(Platform)` — note the `.Plugin.` segment (the namespace is `CatalogPlugin`, the generated module is `Plugin`). Swapping `Platform` is the only change needed to move from an in-memory test environment to a full AWS deployment:

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

### 7. Event Mappings

**Event mappings** route events from one aggregate to commands on the same or a different aggregate. They live in a `<Entity>_Mappings.res` sibling of the aggregate spec and replace `NoEventMappings.Make(<Spec>)` as the third argument to `Platform.Aggregate.Make`.

The file is annotated `@@reventless.mappings`, which (inside an `Aggregate/` folder) infers the `Reventless.EventMapping` domain, brings `Publish` and the `Mapping` module type into scope, and wires the source/target. You write the per-source `Mapping` module — with a `module Source` and a `map` function — and the `let mappings` array.

Here, `Order.Placed` triggers an automatic `Order.Ship` command on the same aggregate:

```rescript
// Order/Aggregate/Order_Mappings.res
@@reventless.mappings

module AutoShipMapping = {
  module Source = Order

  let map = (orderId, event, _queryEngine) =>
    switch event {
    | Order.Placed(_) => [Publish(orderId, Order.Ship)]
    | _ => []
    }
}

let mappings: array<module(Mapping)> = [module(AutoShipMapping)]
```

The plugin generator detects the `Order_Mappings.res` sibling and wires it as the third argument automatically:

```rescript
module OrderAggregate = Platform.Aggregate.Make(
  Order,
  Order_Behavior,
  Order_Mappings,  // generated; replaces NoEventMappings.Make(Order)
)
```

### 8. Side Effect

A **side effect** executes imperative work (e.g. sending emails, calling APIs) when aggregate events are emitted. Side effects are fire-and-forget — they do not produce new events or commands.

A side effect module lives at `<Entity>/SideEffect/<Entity>_<Name>.res`, is annotated `@@reventless.spec`, and defines the `Source` it subscribes to plus an `execute` function:

```rescript
// Order/SideEffect/Order_EmailNotification.res
@@reventless.spec

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

Side effects are hosted on a **Task**. The Task file (`Task/OrderNotifications.res`) is annotated `@@reventless.task` — which injects `let name` from the filename — and lists its side effects in the `setup` function:

```rescript
// Task/OrderNotifications.res
@@reventless.task

let setup = (_queryEngine, _queryBucketName, _opts) => {
  Task.sideEffects: [module(Order_EmailNotification): module(SideEffect.T)],
}
```

The plugin generator discovers the Task and wires it into `~tasks` in the generated `Plugin.res`:

```rescript
module OrderNotificationsTask = Platform.Task.Make(OrderNotifications)
// ...
~tasks=[module(OrderNotificationsTask)],
```

### 9. Task

A **Task** is a serverless handler triggered by S3 events. It can publish commands, manage schedules, and execute side effects. Like the side-effect host above, a Task file lives in `Task/` and is annotated `@@reventless.task` (which injects `let name` from the filename).

Here, the `ImportProducts` Task watches an S3 bucket for CSV uploads and publishes `Product.Add` commands:

```rescript
// Task/ImportProducts.res
@@reventless.task

let importCallback = (~eventName, ~key) => {
  if eventName->String.includes("ObjectCreated") {
    Console.log("[ImportProducts] Processing file: " ++ key)

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
        [
          {
            id: key,
            meta,
            commandJson: Product.Add({
              name: "Imported Product",
              description: "Imported from " ++ key,
              price: 9.99,
            })->Message.encode(Product.commandSchema),
          },
        ],
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

The plugin generator discovers Tasks under `Task/` and wires them into `~tasks` in the generated `Plugin.res` automatically.
