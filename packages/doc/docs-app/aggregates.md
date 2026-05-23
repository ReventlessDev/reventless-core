---
title: Aggregates
date: 2025-01-01
draft: false
sidebar_position: 4
---

# Aggregates

The **Aggregate** pattern gives each entity its own private event stream. Commands are processed sequentially against a state machine built by replaying that stream, providing strong per-entity consistency.

## When to Use Aggregates

Use Aggregates when:
- Each entity is self-contained with its own lifecycle
- Commands are scoped to a single entity instance
- Sequential, conflict-free command processing is sufficient
- A simpler consistency model is preferred

## Architecture

```d2
Client: Client { class: client }
CommandTopic: "Command Topic\n(SQS FIFO)" { class: command-topic }
Handler: "Command Handler\n(Lambda)" { class: aggregate }
Aggregate: "Aggregate\n(State Machine)" { class: aggregate }
EventLog: "Event Log\n(DynamoDB)" { class: event-log }
EventTopic: "Event Topic\n(DynamoDB Streams)" { class: event-topic }
ReadModel: "Read Model\n(Lambda + DynamoDB)" { class: read-model }
EventMapper: "Event Mapper\n(Lambda)" { class: event-mapper }
OtherCommandTopic: Other Command Topic { class: command-topic }

Client -> CommandTopic: { class: command-flow }
CommandTopic -> Handler: { class: command-flow }
Handler -> Aggregate: { class: command-flow }
Aggregate -> EventLog: { class: event-flow }
EventLog -> EventTopic: { class: event-flow }
EventTopic -> ReadModel: { class: projection-flow }
EventTopic -> EventMapper: { class: event-flow }
EventMapper -> OtherCommandTopic: { class: command-flow }
```

## Building with Aggregates

The following example builds the **Catalog plugin** step by step, focusing on the `Product` aggregate. Products can be added and updated.

### Step 1: Define the Aggregate Spec

The Spec defines the aggregate's **identity**, **commands**, **events**, and **errors**. It lives in its own file so both the behavior and any event mappings can reference it without creating circular dependencies.

```rescript
// Product.res
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

The `@@reventless.spec` annotation auto-injects `let name` (derived from filename) and other boilerplate. The `@schema` annotation generates JSON serialization code via the [Sury `ppx`](./rescript-syntax.md#ppx). Every `command`, `event`, and `error` type must be annotated. See [PPX annotations](./rescript-syntax.md#reventless-ppx-annotations) for details.

### Step 2: Implement the Behavior

The Behavior implements the aggregate's state machine. It defines three values:

- **`initialState`** — the starting state before any events have been applied (represents a "not yet created" instance)
- **`evolve`** — calculates the next state from the current state and an event; called once per historic event during replay
- **`decide`** — takes the current state and a command, returns `result<array<event>, error>`; `Ok([...events])` accepts the command, `Error(err)` rejects it

```rescript
// ProductBehavior.res
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
  | (Created(s), UpdateName({name})) if name == s.name => Ok([]) // idempotent
  | (Created(_), UpdateName({name})) => Ok([NameUpdated({name})])
  | (Created(s), UpdateDescription({description})) if description == s.description => Ok([])
  | (Created(_), UpdateDescription({description})) => Ok([DescriptionUpdated({description})])
  | (Created(s), UpdatePrice({price})) if price == s.price => Ok([])
  | (Created(_), UpdatePrice({price})) => Ok([PriceUpdated({price})])
  }
```

### Step 3: Define the ReadModel Spec

The ReadModel Spec defines the **shape of the read-side state** stored in the query database. It is named after the plural read model (`Products`) and lives in a `ReadModel/` folder.

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

Inside a `ReadModel/` folder, `@@reventless.spec` auto-injects `let name`, `let config`, and `let subIdConfig = None`.

**Custom indexes** — to query a read model by a field other than the primary id, declare `let config` explicitly:

```rescript
// Product/ReadModel/Products.res
@@reventless.spec

@schema
type state = {
  name: string,
  description: string,
  price: float,
}

let config = Reventless.ReadModel.config(
  ~indexes=[
    {
      index: "name",
      _type: "S",
      projectionType: #ALL,
    },
  ],
  (),
)
```

**Sub-id (composite key)** — if a read model stores multiple rows per id (e.g. order line items), add `let subIdConfig`:

```rescript
// Order/ReadModel/OrderItems.res
@@reventless.spec

@schema
type state = {
  itemId: string,
  name: string,
  quantity: int,
  price: float,
}

let subIdConfig = Some({
  Reventless.ReadModel.Spec.subIdField: "itemId",
  getSubId: state => state.itemId,
})
```

With `subIdConfig`, `load(orderId)` returns an array of items sorted by the sub-id field.

### Step 4: Implement the Projection

The Projection maps aggregate events to actions on the read model. It lives in a `<Plural>_Projections.res` sibling of the read-model spec and is annotated `@@reventless.mappings`, which (inside a `ReadModel/` folder) infers the `Reventless.Projection` domain, brings `Mapping`, `Set`, `Update`, etc. into scope, and emits the `module type Mapping` wrapper. You write one `Mapping.Make` per source — passing the **source spec**, the **target read model spec**, and an anonymous module with a `project` function — plus the `let mappings` array.

```rescript
// Product/ReadModel/Products_Projections.res
@@reventless.mappings

module ProductMapping = Mapping.Make(
  Product,    // Source: name, Id, @schema type event
  Products,   // Target: name, Id, @schema type state
  {
    open Product
    // project receives {id, meta, event} and returns a list of Projection actions
    let project = ({event, id, _}) =>
      switch event {
      | Added({name, description, price}) =>
        Set(id, {Products.name: name, description, price})
      | NameUpdated({name}) => Update(id, state => {...state, name})
      | DescriptionUpdated({description}) => Update(id, state => {...state, description})
      | PriceUpdated({price}) => Update(id, state => {...state, price})
      }
  },
)

let mappings: array<module(Mapping)> = [module(ProductMapping)]
```

The available `action` variants are: `Set`, `Update`, `UpdateWithDefault`, `Delete`, `Ignore`, and others. See `Reventless.Projection` for the full list.

### Step 5: Define Event Mappings (Optional)

Event Mappings let one aggregate's events trigger commands in the same or another aggregate. They live in a `<Entity>_Mappings.res` sibling of the aggregate spec, annotated `@@reventless.mappings` — which (inside an `Aggregate/` folder) infers the `Reventless.EventMapping` domain, brings `Publish` and the `Mapping` module type into scope, and lets you write just the per-source mapping module and the `mappings` array.

The example below is from the `Order` aggregate in the Ordering plugin: when an order is placed, the framework automatically issues a `Ship` command.

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

If an aggregate has no event mappings, the generator wires `ReventlessInfra.NoEventMappings.Make(Product)` for it.

### Step 6: Assemble the Plugin

The Plugin is assembled as a **[module function](./rescript-syntax.md#functors) over `Platform.T`**. This keeps your application code decoupled from the AWS infrastructure—only the composition root imports `reventless-aws`.

```rescript
// src/Plugin.res — AUTO-GENERATED — do not edit. Run `pnpm run generate` to update.
module Make = (Platform: ReventlessInfra.Platform.T) => {
  // Aggregate: spec + behavior + event mappings (NoEventMappings when none exist)
  module ProductAggregate = Platform.Aggregate.Make(
    Product,
    Product_Behavior,
    ReventlessInfra.NoEventMappings.Make(Product),
  )

  // ReadModel: spec + projections. The wrapper module name appends `ReadModel`
  // so it doesn't shadow the bare-named `Products` spec module.
  module ProductsReadModel = Platform.ReadModel.Make(Products, Products_Projections)

  let make = () =>
    Platform.Plugin.make(
      ~name="Catalog",
      ~heartbeatInterval=60,
      ~aggregates=[module(ProductAggregate)],
      ~readModels=[module(ProductsReadModel)],
    )
}
```

## Deploying the Plugin

The composition root is the only file that imports `reventless-aws`. It instantiates the Platform with AWS config and passes it to the [plugin module function](./rescript-syntax.md#functors), then calls `makePlatform` to create the Pulumi infrastructure.

```rescript
// index.res — composition root

// Create the AWS platform (wires DynamoDB, Lambda, SQS, SNS, etc.)
module Platform = ReventlessAws.Platform.Make(Config)

// Instantiate the plugin module function with the AWS platform
module App = CatalogPlugin.Plugin.Make(Platform)

// Deploy the plugin as a Pulumi component resource
Platform.makePlatform(
  ~version=Reventless.PackageVersion.fromCwd(),
  ~plugins=[module(App)],
)
```

## High-Contention Aggregates — `MakeAsync`

By default, `Platform.Aggregate.Make` uses a standard SQS queue. Commands are processed synchronously within the Lambda invocation, and mutations return `CommandAccepted` or `CommandRejected` immediately.

For aggregates with very high write throughput (e.g. a shared inventory counter or a hot-partition entity), you can opt into an async FIFO queue with `Platform.Aggregate.MakeAsync`:

```rescript
module Make = (Platform: ReventlessInfra.Platform.T) => {
  // Standard aggregate — mutation returns CommandAccepted | CommandRejected
  module ProductAggregate = Platform.Aggregate.Make(
    Product,
    Product_Behavior,
    ReventlessInfra.NoEventMappings.Make(Product),
  )

  // High-contention aggregate — mutation returns CommandPending immediately
  module InventoryAggregate = Platform.Aggregate.MakeAsync(
    Inventory,
    Inventory_Behavior,
    ReventlessInfra.NoEventMappings.Make(Inventory),
  )

  let make = () =>
    Platform.Plugin.make(
      ~name="Catalog",
      ~heartbeatInterval=60,
      ~aggregates=[module(ProductAggregate), module(InventoryAggregate)],
    )
}
```

Both variants go in the same `~aggregates` array — the channel choice is encoded in the builder. In the AWS platform, `MakeAsync` provisions a FIFO SQS queue and its own Lambda. In the in-memory platform, both `Make` and `MakeAsync` behave identically.

When a command is dispatched to a `MakeAsync` aggregate, the mutation returns:

```graphql
{ commandPending: { msgId: "..." } }
```

The client receives the `msgId` and can poll or subscribe for the eventual outcome. Use `MakeAsync` only when you have measured contention on a specific aggregate — the default synchronous path is simpler to reason about and provides immediate feedback.

## Next Steps

- [Plugin System Overview](./plugin-system.md) - Understand the full plugin system
- [DCB Slices](./dcb-slices.md) - Learn about the DCB approach for cross-entity consistency
