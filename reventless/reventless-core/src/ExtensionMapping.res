open ReventlessSpec.ExtensionMapping
open PluginExtensionPointSpec

type extensionPointName = string

/* these actions are internal to the Mapping Functor */
type abstractIncomingCommandAction =
  | AbstractPublishAggregateCommand(Aggregate.name, Message.commandJson)
  | AbstractPublishAggregateCommandAsync(promise<(Aggregate.name, Message.commandJson)>)
  | AbstractPublishAggregateCommandsAsync(promise<array<(Aggregate.name, Message.commandJson)>>)
  | AbstractPublishPluginExtensionPointCommand(Message.commandJson)
  | AbstractPublishExtensionPointCommand(extensionPointName, Message.commandJson)
  | AbstractCall(Message.handler<unit>)

type abstractOutgoingCommandAction =
  | AbstractPublishPluginExtensionPointCommand(Message.commandJson)
  | AbstractPublishExtensionPointCommand(extensionPointName, Message.commandJson)
  | AbstractCall(ReventlessSpec.Handler.handler<unit>)

module type T = {
  module ExtensionPoint: Spec

  let aggregateName: string

  let mapIncomingEvent: (
    Message.event'<string, ExtensionPoint.event>,
    pluginDefinition,
    ReventlessSpec.QueryEngine.operations,
  ) => array<abstractIncomingCommandAction>

  let mapOutgoingEvent: option<(JSON.t, pluginDefinition) => array<abstractOutgoingCommandAction>>
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
