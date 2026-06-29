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
ReadModel: "Read Model\n(Lambda)" { class: read-model }
QueryDb: "Query DB\n(DynamoDB)" { class: query-db }
EventMapper: "Event Mapper\n(Lambda)" { class: event-mapper }
OtherCommandTopic: Other Command Topic { class: command-topic }

Client -> CommandTopic: { class: command-flow }
CommandTopic -> Handler: { class: command-flow }
Handler -> Aggregate: { class: command-flow }
Aggregate -> EventLog: { class: event-flow }
EventLog -> EventTopic: { class: event-flow }
EventTopic -> ReadModel: { class: event-flow }
ReadModel -> QueryDb: project { class: projection-flow }
EventTopic -> EventMapper: { class: event-flow }
EventMapper -> OtherCommandTopic: { class: command-flow }
```

## Building with Aggregates

The following example builds the **Catalog plugin** step by step, focusing on the `Product` aggregate. Products can be added and updated.

### Step 1: Define the Aggregate Spec

The Spec defines the aggregate's **identity**, **commands**, **events**, and **errors**. It lives in its own file so both the behavior and any event mappings can reference it without creating circular dependencies.

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

The `@@reventless.spec` annotation auto-injects `let name` (derived from filename) and other boilerplate. The `@schema` annotation generates JSON serialization code via the [Sury `ppx`](./rescript-syntax.md#ppx). Every `command`, `event`, and `error` type must be annotated. See [PPX annotations](./rescript-syntax.md#reventless-ppx-annotations) for details.

### Step 2: Implement the Behavior

The Behavior implements the aggregate's state machine. It defines three values:

- **`initialState`** — the starting state before any events have been applied (represents a "not yet created" instance)
- **`evolve`** — calculates the next state from the current state and an event; called once per historic event during replay
- **`decide`** — takes the current state and a command, returns `result<array<event>, error>`; `Ok([...events])` accepts the command, `Error(err)` rejects it

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

Inside a `ReadModel/` folder, `@@reventless.spec` auto-injects `let name`, `let config`, and `let subIdConfig = None`. The row id is whatever the projection passes to `Set`/`Update` (the source aggregate's id), so a basic read model needs no key declarations of its own.

**Keys and indexes come from field annotations.** You don't hand-write `let makeId`, `let subIdConfig`, or `let config` — annotate the `@schema type state` fields and the PPX generates them:

```rescript
// Order/ReadModel/OrderItems.res
@@reventless.spec

@schema
type state = {
  @id orderId: string,        // partition key  → generates `let makeId`
  @subId itemId: string,      // sort key        → generates `let subIdConfig`
  @index name: string,        // secondary index → adds an entry to `let config`
  quantity: int,
  price: float,
}
```

- `@id` / `@compositeId` — designate the partition-key field(s).
- `@subId` / `@compositeSubId` — add a sort key, so the read model stores multiple rows per id. `load(orderId)` then returns them sorted by the sub-id field.
- `@index` / `@index("name")` — expose a secondary index so the read model can be queried by a non-id field.

See [PPX annotations](./rescript-syntax.md#reventless-ppx-annotations) for the full set (including `@resolves` cross-table joins and `@indexSubId`). For an index the annotations can't express, you can still fall back to declaring `let config = Reventless.ReadModel.config(~indexes=[...])` explicitly.

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

### Step 6: Let the Generator Assemble the Plugin

You don't write the composition root by hand. Before every build, `generate-plugin src/` (wired as the `prebuild` script, also runnable via `pnpm run generate`) scans `src/` by folder name — `Aggregate/`, `ReadModel/`, `StateChangeSlice/`, … — and wires every component it discovers into a **generated** `src/Plugin.res`. The plugin is a [module function](./rescript-syntax.md#functors) over `Platform.T`, which keeps your application code decoupled from the AWS infrastructure — only the composition root touches the platform.

For the Catalog plugin built above, the generator emits roughly:

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
      ~heartbeatInterval=5,
      ~aggregates=[module(ProductAggregate)],
      ~readModels=[module(ProductsReadModel)],
    )
}
```

`src/Plugin.res` is committed to git, so CI compiles it directly without re-running the generator. An optional `src/plugin.json` sets the plugin name and heartbeat interval; without it the generator falls back to the folder name and defaults.

## Deploying the Plugin

The composition root is the only file that imports `reventless-aws`. It instantiates the Platform with AWS config and passes it to the [plugin module function](./rescript-syntax.md#functors), then calls `makePlatform` to create the Pulumi infrastructure.

```rescript
// Main.res — composition root

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

## High-Contention Aggregates — `@@reventless.async`

By default, an aggregate uses a standard SQS queue: commands are processed synchronously within the Lambda invocation and the mutation returns `CommandAccepted` or `CommandRejected` immediately. The generator wires this with `Platform.Aggregate.Make`.

For aggregates with very high write throughput (e.g. a shared inventory counter or a hot-partition entity), opt into an async FIFO queue by adding `@@reventless.async` at the top of the **spec file** — no change to the generated `Plugin.res`:

```rescript
// Inventory/Aggregate/Inventory.res
@@reventless.spec
@@reventless.async

@schema
type command = Reserve({sku: string, quantity: int})
// ...events, error
```

On the next build, `prebuild` regenerates `Plugin.res` and the generator emits `Platform.Aggregate.MakeAsync(Inventory, Inventory_Behavior, ...)` instead of `Make` for that aggregate. The opt-in lives entirely on the spec file; you never edit the wiring by hand.

Async aggregates route to a separate FIFO-backed command-handler Lambda (`AllAggregatesAsyncCmdHandler`), distinct from the default sync `AllAggregatesCmdHandler`. Each is only provisioned when at least one aggregate of that flavor exists, so sync-only setups (the default) pay no extra Lambda cost. In the local platform, sync and async behave identically.

When a command is dispatched to an async aggregate, the mutation returns `CommandPending` instead of `CommandAccepted`/`CommandRejected`:

```graphql
{ commandPending: { msgId: "..." } }
```

The client receives the `msgId` and can poll or subscribe (`Subscription.onX`) for the eventual outcome. Reach for `@@reventless.async` only when you have measured contention on a specific aggregate — the default synchronous path is simpler to reason about and gives immediate feedback. The same attribute works on StateChangeSlice spec files; see the [Aggregate component](./components/aggregate.md#sync-vs-async-command-dispatch) and [Lambda deployment guide](/infrastructure/lambda-deployment) for the per-handler tuning knobs.

## Next Steps

- [Plugin System Overview](./plugin-system.md) - Understand the full plugin system
- [DCB Slices](./dcb-slices.md) - Learn about the DCB approach for cross-entity consistency
