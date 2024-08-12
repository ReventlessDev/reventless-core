---
title: Aggregate
date: 2021-11-22
draft: true
---

:::note[TODO]
- [ ] come up with consistent simple meaningfull demo examples throughout the documentation
:::

:::note[notes for later]
- ad aggregate state: Because the State won't be persisted, you should only put data there, you *really* need for validating incoming Commands.

:::

An Aggregate's business logic is defined by it's **Spec** and **Behaviour**. 

## Spec

An Aggregate Spec defines the id, name, input and output types of an Aggregate in a declarataive manner. The Spec is used at any place, where a programmatic interaction with the aggregate is desired. ([Aggregate Behaviour](#behaviour), [EventMapper](eventmapper.md), [ReadModel Projections](readmodel.md#Projections), [Extensionpoint Mappings](extensionpoint.md#mappings), [Extension Mappings](extension.md#mappings))

The Aggregate Spec needs to adhere to the following [module type](../rescript-syntax.md#module-types):

```rescript title="reventless-spec/src/AggregateSpec.res"
module type T = {
  module Id: Id.T

  let name: string

  @decco
  type command

  @decco
  type event

  @decco
  type error
}
```

### `@decco` annotation

TODO

### Id
The `Id` module defines what kind of id will be used and implements interactions with it. For more information see the [Id documentation](Id.md). (For simple scenarios Reventless provides a default string implemenation `ReventlessSpec.Id.String`.)

### name

:::note[TODO]
verify naming scope with @Martin
:::

A name is a string which must be unique in the scope of one plugin and should describe the aggregate aptly. The name will also be used "behind the scenes" to e.g. route payload to the right mappings etc.

### command

The command type states the possible inputs of the aggregate.  
There are no explicit constraints for the command type (developer can choose whichever type is best suited - proivided the serialization library has support - currently [decco](https://github.com/rescript-labs/decco)), but usually [variants](../rescript-syntax.md#variant-type) are the ideal choice.

:::tip
Command Variant Constructors should be formulated as imperative.
:::

### event

The event type states the possibles successfull results of the aggregate.  
There are no explicit constraints for the event type (developer can choose whichever type is best suited - proivided the serialization library has support - currently [decco](https://github.com/rescript-labs/decco)), but usually [variants](../rescript-syntax.md#variant-type) are the ideal choice.

:::tip
Command Variant Constructors should be formulated in past tense.
:::

### error

The error type states possible known (immediately unrecoverable) errors of the aggregate.  
Only values of this type can be passed to the Behaviour's [error function](#errors) The semantic may be chossen by the developer, but usually [variants](../rescript-syntax.md#variant-type) are the ideal choice.


### Example

```rescript title="ExampleAggregate.res"
  module Id = ReventlessSpec.Id.String

  let name = "ExampleAggregate"

  @decco
  type command = 
    | DoSomething(int)
    | DoSomethingElse(string)

  @decco
  type event =
    | SomethingHasHappened(int)
    | AnotherThingHasHappened(string)

  @decco
  type error =
    | IllegalState
    | ArbitaryError(string)
```

## Behaviour

### errors

## EventMappings

## Initialize Component (AWS Defaults)

## Initialize Component (Generic)
(
  Config: Config.T,
  Spec: ReventlessSpec.AggregateSpec.T,
  Behaviour: Behaviour.T with module Spec := Spec,
  EventMappings: EventMapper.Mappings with module Target := Spec,
  CommandGeneratorResolvers: CommandGenerator.Adapter.Resolvers with type api := Config.api,
  CommandTopicConnector: CommandTopic.Adapter.Connector,
  EventLogStorage: EventLog.Adapter.Storage,
  EventTopicPublisher: EventTopic.Adapter.Publisher,
  EventCollectorConnector: EventCollector.Adapter.Connector,
)

