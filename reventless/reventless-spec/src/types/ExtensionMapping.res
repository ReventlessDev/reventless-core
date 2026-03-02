/**
A pre-serialized command routed to a foreign extension point.
Used when an extension needs to dispatch to an extension point it does not
own — the command JSON is forwarded opaquely without re-encoding.
*/
type forwardCommand = {
  extensionPointName: string,
  id: string,
  commandJson: JSON.t,
}

type id = string

/**
Actions returned by an extension's `mapIncomingEvent` function.

When an extension point emits an event, the extension's mapping can:
- publish a command to the aggregate it wraps (`PublishAggregateCommand`)
- publish a command back to the extension point (`PublishExtensionPointCommand`)
- forward a command to another extension point opaquely (`ForwardCommand`)
- invoke an arbitrary async callback (`Call`)
*/
type incomingCommandAction<'aggregateCommand, 'extensionPointCommand, 'msg> =
  | PublishAggregateCommand(id, 'aggregateCommand)
  | PublishAggregateCommandAsync(promise<(id, 'aggregateCommand)>)
  | PublishAggregateCommandsAsync(promise<array<(id, 'aggregateCommand)>>)
  | PublishExtensionPointCommand(id, 'extensionPointCommand)
  | ForwardCommand(forwardCommand)
  | Call('msg => promise<unit>, 'msg)

/**
Actions returned by an extension's `mapOutgoingEvent` function.

When the wrapped aggregate emits an event, the extension can:
- publish a command to the extension point (`PublishExtensionPointCommand`)
- forward a command to another extension point opaquely (`ForwardCommand`)
- invoke an arbitrary async callback (`Call`)
*/
type outgoingCommandAction<'extensionPointCommand, 'msg> =
  | PublishExtensionPointCommand(id, 'extensionPointCommand)
  | ForwardCommand(forwardCommand)
  | Call('msg => promise<unit>, 'msg)

/**
Maps an extension point event to actions on the wrapped aggregate or extension point.

Called when the extension point emits an event that this extension handles.
Receives the entity ID, the event, message metadata, the plugin definition,
and the query engine.
*/
type mapIncomingEvent<
  'extensionPointEvent,
  'aggregateCommand,
  'extensionPointCommand,
  'extensionPointDirective,
> = (
  string,
  'extensionPointEvent,
  Message.meta,
  Plugin.pluginDefinition,
  QueryEngine.operations,
) => array<
  incomingCommandAction<'aggregateCommand, 'extensionPointCommand, 'extensionPointDirective>,
>

/**
Maps an aggregate event to actions on the extension point.

Optionally defined — return `None` if the aggregate's outgoing events do not
need to be reflected back through the extension point.
*/
type mapOutgoingEvent<'aggregateEvent, 'extensionPointCommand, 'extensionPointDirective> = (
  string,
  'aggregateEvent,
  Message.meta,
  Plugin.pluginDefinition,
) => array<outgoingCommandAction<'extensionPointCommand, 'extensionPointDirective>>

/**
The extension point protocol that this `Extension` connects to.
Mirrors `ExtensionPoint.Spec` so the extension can be type-checked
against the extension point's command / event / directive types.
*/
module type Spec = {
  let name: string

  @schema
  type command
  @schema
  type event
  @schema
  type directive
}

/**
Application-level implementation of an extension's bidirectional mapping.

- `ExtensionPoint` — the extension point protocol this extension connects to
- `Aggregate` — the aggregate this extension wraps
- `mapIncomingEvent` — routes extension point events to aggregate / EP commands
- `mapOutgoingEvent` — optionally routes aggregate events back to the EP
*/
module type Impl = {
  module ExtensionPoint: Spec
  module Aggregate: Aggregate.Spec

  let mapIncomingEvent: mapIncomingEvent<
    ExtensionPoint.event,
    Aggregate.command,
    ExtensionPoint.command,
    ExtensionPoint.directive,
  >

  let mapOutgoingEvent: option<
    mapOutgoingEvent<Aggregate.event, ExtensionPoint.command, ExtensionPoint.directive>,
  >
}

/**
A dummy aggregate used when an extension does not wrap a real aggregate.
Satisfies `Aggregate.Spec` with unit command / event / error types.
*/
module NoAggregate = {
  let name = "NoAggregate"

  module Id = {
    @schema
    type t = string
    type input = string
    external make: t => t = "%identity"
    external makeFromString: string => t = "%identity"
    external toString: t => t = "%identity"
    let cmp = String.compare
  }

  @schema
  type command = unit

  @schema
  type event = unit

  @schema
  type error = unit
}

open PluginExtensionPointSpec

type extensionPointName = string

/* these actions are internal to the Mapping Functor */
type abstractIncomingCommandAction =
  | AbstractPublishAggregateCommand(string, Message.commandJson)
  | AbstractPublishAggregateCommandAsync(promise<(string, Message.commandJson)>)
  | AbstractPublishAggregateCommandsAsync(promise<array<(string, Message.commandJson)>>)
  | AbstractPublishPluginExtensionPointCommand(Message.commandJson)
  | AbstractPublishExtensionPointCommand(extensionPointName, Message.commandJson)
  | AbstractCall(Handler.handler<unit>)

type abstractOutgoingCommandAction =
  | AbstractPublishPluginExtensionPointCommand(Message.commandJson)
  | AbstractPublishExtensionPointCommand(extensionPointName, Message.commandJson)
  | AbstractCall(Handler.handler<unit>)

module type T = {
  module ExtensionPoint: Spec

  let aggregateName: string

  let mapIncomingEvent: (
    Message.event'<string, ExtensionPoint.event>,
    pluginDefinition,
    QueryEngine.operations,
  ) => array<abstractIncomingCommandAction>

  let mapOutgoingEvent: option<(JSON.t, pluginDefinition) => array<abstractOutgoingCommandAction>>
}

module type Mappings = {
  module Spec: Spec
  module type Mapping = T with module ExtensionPoint := Spec
  let name: string
  let mappings: array<module(Mapping)>
}

module Make = (Spec: Spec, MappingImpl: Impl with module ExtensionPoint := Spec): (
  T with module ExtensionPoint := Spec
) => {
  module Aggregate = MappingImpl.Aggregate
  let aggregateName = Aggregate.name
  let extensionPointName = Spec.name

  let encodeMeta = (meta: Message.meta, service) => {
    ...meta,
    service,
    msgId: Message.uuid(),
  }

  let doMapIncomingEvent = (
    mapIncomingEventImpl,
    {Message.id: id, event, meta},
    pluginDef,
    queryEngine,
  ) => {
    let encodeAggregateCommandJson = (aggregateCmd, aggregateId) => {
      let commandStr = aggregateCmd->Message.encode(Aggregate.commandSchema)->JSON.stringify
      Console.log(
        `ExtensionMapping incoming from ExtensionPoint ${extensionPointName} to Aggregate ${aggregateName}: Publishing command: ${commandStr} id: ${aggregateId}`,
      )
      {
        Message.id: aggregateId,
        meta: encodeMeta(meta, aggregateName),
        commandJson: aggregateCmd->Message.encode(Aggregate.commandSchema),
      }
    }

    let encodeExtensionPointCommandJson = (commandJson, ~id, ~extensionPointName, ~action) => {
      let commandStr = commandJson->JSON.stringify
      Console.log(
        `ExtensionMapping incoming from ExtensionPoint ${extensionPointName}: ${action}: ${commandStr} id: ${id}`,
      )
      {
        Message.id,
        meta: encodeMeta(meta, extensionPointName),
        commandJson,
      }
    }

    let encodeExtensionPointCommand = (command, ~id, ~extensionPointName, ~action) =>
      command
      ->Message.encode(Spec.commandSchema)
      ->encodeExtensionPointCommandJson(~id, ~extensionPointName, ~action)

    mapIncomingEventImpl(id, event, meta, pluginDef, queryEngine)->Array.map(x =>
      switch x {
      | PublishAggregateCommand(aggregateId, aggregateCmd) =>
        AbstractPublishAggregateCommand(
          aggregateName,
          aggregateCmd->encodeAggregateCommandJson(aggregateId),
        )
      | PublishAggregateCommandAsync(promise) =>
        let toCommandJson = async promise => {
          let (aggregateId, aggregateCmd) = await promise
          (aggregateName, aggregateCmd->encodeAggregateCommandJson(aggregateId))
        }
        AbstractPublishAggregateCommandAsync(promise->toCommandJson)
      | PublishAggregateCommandsAsync(promise) =>
        let toCommandJsons = async promise =>
          (await promise)->Array.map(((aggregateId, aggregateCmd)) => (
            aggregateName,
            aggregateCmd->encodeAggregateCommandJson(aggregateId),
          ))
        AbstractPublishAggregateCommandsAsync(promise->toCommandJsons)
      | PublishExtensionPointCommand(id, command)
        if Spec.name == PluginExtensionPointSpec.name =>
        AbstractPublishPluginExtensionPointCommand(
          command->encodeExtensionPointCommand(
            ~id,
            ~extensionPointName,
            ~action="Publish PluginExtensionPoint command",
          ),
        )
      | PublishExtensionPointCommand(id, command) =>
        AbstractPublishExtensionPointCommand(
          extensionPointName,
          command->encodeExtensionPointCommand(
            ~id,
            ~extensionPointName,
            ~action="Publish ExtensionPoint command",
          ),
        )
      | ForwardCommand({extensionPointName, id, commandJson}) =>
        AbstractPublishExtensionPointCommand(
          extensionPointName,
          commandJson->encodeExtensionPointCommandJson(
            ~id,
            ~extensionPointName,
            ~action="Forward ExtensionPoint command",
          ),
        )
      | Call(handler, directive) =>
        Console.log2(
          `ExtensionMapping incoming from ExtensionPoint ${extensionPointName}: Handling directive`,
          directive->Message.encode(Spec.directiveSchema)->JSON.stringify,
        )

        AbstractCall(() => handler(directive))
      }
    )
  }

  let mapIncomingEvent = doMapIncomingEvent(MappingImpl.mapIncomingEvent, ...)

  let doMapOutgoingEvent = (mapOutgoingEventImpl, aggregateEvent'Json, pluginDef) =>
    switch aggregateEvent'Json->Message.decodeEvent'(Aggregate.Id.schema, Aggregate.eventSchema) {
    | {id, meta, event} =>
      let encodeExtensionPointCommandJson = (commandJson, ~id, ~extensionPointName, ~action) => {
        let commandStr = commandJson->JSON.stringify
        Console.log(
          `ExtensionMapping outgoing from Aggregate ${aggregateName}: ${action}: ${commandStr} id: ${id}`,
        )
        {
          Message.id,
          meta: encodeMeta(meta, extensionPointName),
          commandJson,
        }
      }

      let encodeExtensionPointCommand = (command, ~id, ~extensionPointName, ~action) =>
        command
        ->Message.encode(Spec.commandSchema)
        ->encodeExtensionPointCommandJson(~id, ~extensionPointName, ~action)

      mapOutgoingEventImpl(id->Aggregate.Id.toString, event, meta, pluginDef)->Array.map(x =>
        switch x {
        | PublishExtensionPointCommand(id, command)
          if Spec.name == PluginExtensionPointSpec.name =>
          AbstractPublishPluginExtensionPointCommand(
            command->encodeExtensionPointCommand(
              ~id,
              ~extensionPointName,
              ~action="Publish PluginExtensionPoint command",
            ),
          )

        | PublishExtensionPointCommand(id, command) =>
          AbstractPublishExtensionPointCommand(
            extensionPointName,
            command->encodeExtensionPointCommand(
              ~id,
              ~extensionPointName,
              ~action="Publish ExtensionPoint command",
            ),
          )
        | ForwardCommand({extensionPointName, id, commandJson}) =>
          AbstractPublishExtensionPointCommand(
            extensionPointName,
            commandJson->encodeExtensionPointCommandJson(
              ~id,
              ~extensionPointName,
              ~action="Forward ExtensionPoint command",
            ),
          )
        | Call(handler, directive) =>
          Console.log2(
            `ExtensionMapping outgoing from Aggregate ${aggregateName}: Handling directive`,
            directive->Message.encode(Spec.directiveSchema)->JSON.stringify,
          )

          AbstractCall(() => handler(directive))
        }
      )
    | exception err =>
      Console.log2("ExtensionMapping.mapOutgoing: Error: Decode failure: ", err)
      []
    }

  let mapOutgoingEvent =
    MappingImpl.mapOutgoingEvent->Option.map(mapOutgoingEventImpl =>
      doMapOutgoingEvent(mapOutgoingEventImpl, ...)
    )
}
