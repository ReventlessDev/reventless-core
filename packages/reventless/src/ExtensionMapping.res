open ReventlessSpec.ExtensionMapping
open ReventlessSpec.PluginExtensionPointSpec

type extensionPointName = string

/* these actions are internal to the Mapping Functor */
type abstractIncomingCommandAction =
  | AbstractPublishAggregateCommand(Aggregate.name, Message.commandJson)
  | AbstractPublishAggregateCommandAsync(Js.Promise.t<(Aggregate.name, Message.commandJson)>)
  | AbstractPublishAggregateCommandsAsync(
      Js.Promise.t<array<(Aggregate.name, Message.commandJson)>>,
    )
  | AbstractPublishPluginExtensionPointCommand(Message.commandJson)
  | AbstractPublishExtensionPointCommand(extensionPointName, Message.commandJson)
  | AbstractCall(Message.handler<unit>)

type abstractOutgoingCommandAction =
  | AbstractPublishPluginExtensionPointCommand(Message.commandJson)
  | AbstractPublishExtensionPointCommand(extensionPointName, Message.commandJson)
  | AbstractCall(Message.handler<unit>)

module type T = {
  module ExtensionPoint: Spec

  let aggregateName: string

  let mapIncomingEvent: (
    Message.event'<string, ExtensionPoint.event>,
    pluginDefinition,
    ReventlessSpec.QueryEngine.operations,
  ) => array<abstractIncomingCommandAction>

  let mapOutgoingEvent: option<
    (Js.Json.t, pluginDefinition) => array<abstractOutgoingCommandAction>,
  >
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
      let commandStr = aggregateCmd->Aggregate.command_encode->Js.Json.stringify
      Js.log(
        `ExtensionMapping incoming from ExtensionPoint ${extensionPointName} to Aggregate ${aggregateName}: Publishing command: ${commandStr} id: ${aggregateId}`,
      )
      {
        Message.id: aggregateId,
        meta: encodeMeta(meta, aggregateName),
        commandJson: aggregateCmd->Aggregate.command_encode,
        delay: None,
      }
    }

    let encodeExtensionPointCommandJson = (commandJson, ~id, ~extensionPointName, ~action) => {
      let commandStr = commandJson->Js.Json.stringify
      Js.log(
        `ExtensionMapping incoming from ExtensionPoint ${extensionPointName}: ${action}: ${commandStr} id: ${id}`,
      )
      {
        Message.id,
        meta: encodeMeta(meta, extensionPointName),
        commandJson,
        delay: None,
      }
    }

    let encodeExtensionPointCommand = (command, ~id, ~extensionPointName, ~action) =>
      command
      ->Spec.command_encode
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
        if Spec.name == ReventlessSpec.PluginExtensionPointSpec.name =>
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
      | Call(handler, callCommand) =>
        Js.log2(
          `ExtensionMapping incoming from ExtensionPoint ${extensionPointName}: Handling call command`,
          callCommand->Spec.callCommand_encode->Js.Json.stringify,
        )

        AbstractCall(() => handler(callCommand))
      }
    )
  }

  let mapIncomingEvent = doMapIncomingEvent(MappingImpl.mapIncomingEvent, ...)

  let doMapOutgoingEvent = (mapOutgoingEventImpl, aggregateEvent'Json, pluginDef) =>
    switch Message.event'_decode(
      Aggregate.Id.t_decode,
      Aggregate.event_decode,
      aggregateEvent'Json,
    ) {
    | Ok({id, meta, event}) =>
      let encodeExtensionPointCommandJson = (commandJson, ~id, ~extensionPointName, ~action) => {
        let commandStr = commandJson->Js.Json.stringify
        Js.log(
          `ExtensionMapping outgoing from Aggregate ${aggregateName}: ${action}: ${commandStr} id: ${id}`,
        )
        {
          Message.id,
          meta: encodeMeta(meta, extensionPointName),
          commandJson,
          delay: None,
        }
      }

      let encodeExtensionPointCommand = (command, ~id, ~extensionPointName, ~action) =>
        command
        ->Spec.command_encode
        ->encodeExtensionPointCommandJson(~id, ~extensionPointName, ~action)

      mapOutgoingEventImpl(id->Aggregate.Id.toString, event, meta, pluginDef)->Array.map(x =>
        switch x {
        | PublishExtensionPointCommand(id, command)
          if Spec.name == ReventlessSpec.PluginExtensionPointSpec.name =>
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
        | Call(handler, callCommand) =>
          Js.log2(
            `ExtensionMapping outgoing from Aggregate ${aggregateName}: Handling call command`,
            callCommand->Spec.callCommand_encode->Js.Json.stringify,
          )

          AbstractCall(() => handler(callCommand))
        }
      )
    | Error(err) =>
      Js.log2("ExtensionMapping.mapOutgoing: Error: Decode failure: ", err)
      []
    }

  let mapOutgoingEvent =
    MappingImpl.mapOutgoingEvent->Belt.Option.map(mapOutgoingEventImpl =>
      doMapOutgoingEvent(mapOutgoingEventImpl, ...)
    )
}
