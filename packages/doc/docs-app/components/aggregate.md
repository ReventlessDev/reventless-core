---
title: Aggregate
date: 2021-11-22
draft: false
---

For a short summary of an Aggregate, see [Reventless Components Overview.](../component-overview.md#aggregate)

:::info Framework Implementation
This component follows the Reventless [Component Structure Pattern](/framework/inner-workings/component-structure-pattern), using separate files for interface definitions ([`Aggregate.res`](../../reventless/src/components/Aggregate/Aggregate.res)), builder logic ([`Aggregate_Builder.res`](../../reventless/src/components/Aggregate/Aggregate_Builder.res)), and runtime callbacks ([`Aggregate_Callback.res`](../../reventless/src/components/Aggregate/Aggregate_Callback.res)).
:::

```d2
CommandSource: Command Source { class: command-generator }
EventTarget: Event Target { class: event-collector }

Aggregate: {
  class: aggregate

  Domain: {
    class: aggregate
    Spec: Aggregate Spec { class: spec }
    Behavior: Behavior { class: spec }
    EventMappings: Event Mappings { class: spec }
  }

  CommandTopic: Command Topic { class: command-topic }
  EventLog: Event Log { class: event-log }
  EventTopic: Event Topic { class: event-topic }

  CommandTopic -> Domain: command { class: command-flow }
  Domain -> EventLog: event { class: event-flow }
  EventLog -> Domain: replay { class: replay }
  EventLog -> EventTopic: event { class: event-flow }
}

CommandSource -> Aggregate.CommandTopic: command { class: command-flow }
Aggregate.EventTopic -> EventTarget: { class: event-flow }
```

An Aggregate's business logic is defined by it's [**Spec**](#aggregate-spec), [**Behavior**](#behavior), [**Config**](../common-modules/config.md) and [**Event Mappings**](#eventmappings).

Commands are requests for change, which may be accepted (or not). Several Components can act as a Command Source: Command Generator, [Task](./task.md), [Event Mapper](#eventmappings), [Extension](./extension.md), and [Extension Point](./extensionpoint.md). Commands will never be stored. Accepted Commands result in any number of Events. Events are factual statements of the past, which cannot change. (Only new events may be created.) Events will be persisted in the Event Log. An Event Log is an "append-only" storage.
In an event-sourced system Events are the single source of truth. (note: any system based on Reventless is an event-sourced system!)

## Aggregate Spec

An Aggregate Spec defines the id, name, command and event types of an Aggregate in a declarataive manner. The Spec is used at any place, where a programmatic interaction with the aggregate is desired. ([Aggregate Behavior](#behavior), EventMapper, [ReadModel Projections](readmodel.md#projections), [Extensionpoint Mappings](extensionpoint.md#extensionpoint-mappings), [Extension Mappings](extension.md#extension-mappings))

### Example

```rescript title="Customer.res" showLineNumbers
//open Reventless

module Id = Reventless.Id.String

@decco
type id = Id.t

let name = "Customer"

@decco
type name = string
@decco
type address = string

@decco
type customer = {
  name: name,
  address: address,
}

@decco
type command =
  | Create(customer)
  | ChangeAddress(address)
  | ChangeName(name)
  | Delete

@decco
type event =
  | Created(customer)
  | AddressChanged(address)
  | NameChanged(name)
  | Unchanged
  | Deleted

@decco
type error =
  | AlreadyExisting
  | NotExisting
```

For information about `@schema` see [Schema annotation](/framework/inner-workings/serialization#schema-annotation).

### Id

See [Id](../common-modules/Id.md).

### name

A name is a string which must be unique in the scope of Aggregate names in one [plugin](./plugin.md) and should describe the aggregate aptly. The name will also be used "behind the scenes" to e.g. route payload to the right mappings etc.

### command

The command type declares the possible inputs of the aggregate.  
There are no explicit constraints for the command type (developer can choose whichever type is best suited - proivided the serialization library has support - currently [decco](https://github.com/rescript-labs/decco)), but usually [variants](../rescript-syntax.md#variant-type) are the ideal choice.

:::tip
Command Variant Constructors should be formulated as imperative.
:::

### event

The event type declares the possible results of the aggregate.  
There are no explicit constraints for the event type (developer can choose whichever type is best suited - proivided the serialization library has support - currently [decco](https://github.com/rescript-labs/decco)), but usually [variants](../rescript-syntax.md#variant-type) are the ideal choice.

:::tip
Event Variant Constructors should be formulated in past tense.
:::

### error

The error type declares possible unrecoverable errors of the aggregate.
The semantic may be chosen by the developer, but usually [variants](../rescript-syntax.md#variant-type) are the ideal choice.

## Behavior

The aggregate specific business logic is implemented in a behavior module.

It defines:

- the initial state and how to evolve it from historic events.
- how to decide on commands based on the current state.

### Example

```rescript title="Customer_Behavior.res" showLineNumbers
open Reventless
open Customer

@schema
type state = {
  address: address,
  name: name,
  deleted: bool,
}

let initialState = {address: "", name: "", deleted: true}

// (state, event) => state
let evolve = (state, event) =>
  switch event {
  | Created({Customer.address: address, name}) => {address, name, deleted: false}
  | AddressChanged(address) => {...state, address}
  | NameChanged(name) => {...state, name}
  | Unchanged => state
  | Deleted => {...state, deleted: true}
  }

// (state, command) => result<array<event>, error>
let decide = (state, command) =>
  switch (command, state) {
  | (Create(customer), {deleted: true}) => Ok([Created(customer)])
  | (Create(_), {deleted: false}) => Error(AlreadyExisting)

  | (ChangeAddress(_), {deleted: true}) => Error(NotExisting)
  | (ChangeAddress(address), {address: oldAddress}) if address != oldAddress =>
    Ok([AddressChanged(address)])
  | (ChangeAddress(_), _) => Ok([Unchanged])

  | (ChangeName(_), {deleted: true}) => Error(NotExisting)
  | (ChangeName(name), {name: oldName}) if name != oldName => Ok([NameChanged(name)])
  | (ChangeName(_), _) => Ok([Unchanged])

  | (Delete, {deleted: true}) => Ok([Unchanged])
  | (Delete, {deleted: false}) => Ok([Deleted])
  }
```

### Spec

This is a module alias to the [Aggregate Spec](#aggregate-spec) to be used.

### state

Defines the type of the state, which will be calculated by the [`evolve`](#evolve) function based on historic events, starting from [`initialState`](#initialstate).
You can choose whatever type suites your needs. Very often this will be a [record](../rescript-syntax.md#record-type).

### initialState

The `initialState` value is the starting state before any events have been applied. This represents the state of a "not yet created" aggregate instance.

### evolve

The `evolve` function calculates the next state based on the current state and the next event. It combines the former `init` and `apply` functions into a single function, with `initialState` providing the starting value.

### decide

The `decide` function takes the current state and a command, and returns `result<array<event>, error>`. It combines the former `create` and `execute` functions into a single function. Return `Ok([...events])` for accepted commands and `Error(error)` for rejected commands.

### Call Sequence

```d2
shape: sequence_diagram

CommandSource: Command Source { class: command-generator }
Aggregate: Aggregate { class: aggregate }
Behavior: Behavior { class: spec }
EventLog: Event Log { class: event-log }

CommandSource -> Aggregate: "Command1 (very first Command for this id)"
Aggregate -> EventLog: "replay(id)"
EventLog --> Aggregate: "[] (no events yet)"
Aggregate -> Behavior: "decide(initialState, Command1)"
Behavior --> Aggregate: "Ok([event1])"
Aggregate -> EventLog: "append(event1)"

CommandSource -> Aggregate: "Command2 (second Command for this id)"
Aggregate -> EventLog: "replay(id)"
EventLog --> Aggregate: "[event1] (one event persisted)"
Aggregate -> Behavior: "evolve(initialState, event1)"
Behavior --> Aggregate: state1
Aggregate -> Behavior: "decide(state1, Command2)"
Behavior --> Aggregate: "Ok([event2])"
Aggregate -> EventLog: "append(event2)"

CommandSource -> Aggregate: "Command3 (third Command for this id)"
Aggregate -> EventLog: "replay(id)"
EventLog --> Aggregate: "[event1, event2] (two events persisted)"
Aggregate -> Behavior: "evolve(initialState, event1)"
Behavior --> Aggregate: state1
Aggregate -> Behavior: "evolve(state1, event2)"
Behavior --> Aggregate: state2
Aggregate -> Behavior: "decide(state2, Command3)"
Behavior --> Aggregate: "Ok([event3])"
Aggregate -> EventLog: "append(event3)"
```

## EventMappings

Each `Aggregate` can specify `EventMapping`s from one ore more source Aggregates:

```rescript title="Customer_EventMappings.res" showLineNumbers
open Reventless

module Target = Customer

module CustomerMapping = {
  module Source = Customer

  let map = (. customerId, event, _queryEngine) =>
    switch event {
    | Customer.Created(customer) => [
        EventMapping.Publish(customerId, Customer.ChangeAddress(customer.address ++ " Suffix")),
      ]
    | _ => []
    }
}

module type Mapping = EventMapping.T with module Target := Target

let mappings: array<module(Mapping)> = [module(CustomerMapping)]

let counter = None
```

### Target

Each `EventMapping`s file has to define one `Target` module alias to its `Aggregate Spec` that all mappings are targeting to.

### Mapping module

For each source Aggregate a separate Mapping module has to be defined.

#### Source

Module alias to the source `Aggregate Spec`.

#### map

Mapping function from source `Event` to target `Command`.

### Mapping module type

For the following array of mappings a Mapping module type has to be defined, which constrains the `Target` to the `Target` module type defined above. This has to be done due to [ReScript Functor Syntax](../rescript-syntax.md#functors).

### mappings

This array has to include all mappings for this `Aggregate`.

### counter

`counter` defines if a counter should be used for this mapping. In this example no counter is needed, so it is `None`.

See [Counter](../components/counter#usage-in-eventmappings) component for further details.

## Generate Aggregate (AWS Defaults)

Finally the `Aggregate` has to be generated by providing the previously generated Modules:

```rescript title="Customer_EventMappings.res" showLineNumbers
include ReventlessAws.Aggregate.Make(Config, Customer, Customer_Behavior, Customer_EventMappings)
```

## Pulumi

The aggregate's Pulumi root component is named in this pattern: `Spec.name` and has a type of `reventless:Aggregate`.

## Identity and RequestContext

The authenticated user's [Identity](../common-modules/identity.md) is available via [RequestContext](../common-modules/request-context.md) during command processing. The `identity.userId` is persisted as `meta.user` on every event produced by the aggregate. The full identity (groups, claims, provider) is transient and available only for the duration of the request.

Application code can use `RequestContext.identity` for authorization decisions in the `decide` function by accessing it through the Effect service:

```rescript
Effect.serviceWith(RequestContext.tag, ctx => {
  let identity = ctx.identity
  if identity->Identity.hasGroup("admin") {
    // authorize admin action
  }
})
```

## Related Components

- **[EventLog](./eventlog.md)** - Stores events generated by the Aggregate
- **[CommandTopic](./commandtopic.md)** - Delivers commands to the Aggregate
- **[EventTopic](./eventtopic.md)** - Distributes events from the Aggregate's EventLog
- **[CommandGenerator](./commandgenerator.md)** - Generates commands for the Aggregate from API mutations
- **[EventMapper](./eventmapper.md)** - Maps events from other Aggregates to commands for this Aggregate
- **[ReadModel](./readmodel.md)** - Consumes events from the Aggregate to build read models
- **[Extension](./extension.md)** - Can send commands to the Aggregate via ExtensionPoints
- **[ExtensionPoint](./extensionpoint.md)** - Can receive commands from Extensions for the Aggregate
- **[Counter](./counter.md)** - Used by EventMappers for deduplication when mapping to this Aggregate
