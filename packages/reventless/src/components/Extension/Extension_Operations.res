module type Mappings = {
  module Spec: ReventlessSpec.ExtensionMapping.Spec
  module type Mapping = ExtensionMapping.T with module ExtensionPoint := Spec
  let name: string
  let mappings: array<module(Mapping)>
}

module type Spec = {
  let publishToAggregates: dict<CommandTopic.publishJsons>
  let publishToCorePluginExtensionPoint: CommandTopic.publishJsons
  let readModelNamesForSourceName: Js.Dict.t<array<string>>
  let publishToReadModels: Js.Dict.t<EventCollector.enqueueEvent>
  let queryEngine: ReventlessSpec.QueryEngine.operations
}

module type T = {
  let incomingEventHandler: Extension.eventHandler
  let outgoingEventHandler: Extension.eventHandler
}

module Make = (
  Spec: Spec,
  MappingSpec: ReventlessSpec.ExtensionMapping.Spec,
  Mappings: Mappings with module Spec := MappingSpec,
): T => {
  let findOutgoingMapping = (aggregateNameOpt, mappings) =>
    aggregateNameOpt->Belt.Option.flatMap(aggregateName =>
      mappings->Belt.Array.getBy((module(Mapping: Mappings.Mapping)) =>
        Mapping.aggregateName == aggregateName
      )
    ) // TODO: handle multiple mappings for same Aggregate name

  let mapIncomingEvent = (
    event': Message.event'<string, MappingSpec.event>,
    pluginDef,
    queryEngine,
  ) =>
    Mappings.mappings
    ->Belt.Array.map((module(Mapping: Mappings.Mapping)) =>
      Mapping.mapIncomingEvent(event', pluginDef, queryEngine)
    )
    ->Belt.Array.concatMany

  let mapOutgoingEvent = (eventJson', pluginDef) =>
    switch eventJson'->Message.serviceNameOfMsg->findOutgoingMapping(Mappings.mappings) {
    | Some(module(Mapping)) =>
      switch Mapping.mapOutgoingEvent {
      | Some(mapOutgoingEvent) => mapOutgoingEvent(eventJson', pluginDef)
      | None =>
        Logger.error(
          ~loc=__LOC__,
          "mapOutgoingEvent",
          "shouldn't be called, because Plugin EventCollector shouldn't subscribe to EventLog stream not having mapOutgoingEvent() !",
        )
        []
      }
    | None =>
      Js.Exn.raiseError(
        "ExtensionPoint.Mapping: Missing mapping for " ++ eventJson'->Js.Json.stringify,
      )
    }

  let publishAggregateCommand = async (aggregateName, cmdJson) => {
    let pub = Spec.publishToAggregates->Js.Dict.get(aggregateName)->Belt.Option.getExn
    try await pub([cmdJson]) catch {
    | err => Js.log2(`Extension: Error on publish command to aggregate ${aggregateName}:`, err)
    }
  }

  let publishCorePluginExtensionPointCommand = async cmdJson =>
    try await Spec.publishToCorePluginExtensionPoint([cmdJson]) catch {
    | err => Js.log2(`Extension: Error on publish command to Core.Plugin ExtensionPoint:`, err)
    }

  let forwardCommand = (extensionPointName, commandJson: Message.commandJson) =>
    publishCorePluginExtensionPointCommand({
      Message.id: "",
      meta: {
        ...commandJson.meta,
        msgId: Message.uuid(),
      },
      commandJson: ForwardCommand({
        extensionPointName,
        id: commandJson.id,
        command: commandJson->Message.toMessageBody,
      })->ReventlessSpec.PluginExtensionPointSpec.command_encode,
      delay: None,
    })

  let handle = async handler =>
    try await handler() catch {
    | err => Js.log2("ExtensionPoint: Error on calling handler:", err)
    }

  let applyIncomingCommandAction = async action =>
    await (
      switch action {
      | ExtensionMapping.AbstractPublishAggregateCommand(aggregateName, commandJson) =>
        publishAggregateCommand(aggregateName, commandJson)
      | AbstractPublishAggregateCommandAsync(promise) => {
          let (aggregateName, commandJson) = await promise
          publishAggregateCommand(aggregateName, commandJson)
        }
      | AbstractPublishAggregateCommandsAsync(promise) =>
        let publish = async promise => {
          await promise
          ->Util.Promise.mapOk(arr =>
            arr
            ->Belt.Array.map(((aggregateName, commandJson)) =>
              publishAggregateCommand(aggregateName, commandJson)
            )
            ->Js.Promise.all
          )
          ->Util.Promise.toUnit
        }
        promise->publish
      | AbstractPublishPluginExtensionPointCommand(commandJson) =>
        publishCorePluginExtensionPointCommand(commandJson)
      | AbstractPublishExtensionPointCommand(extensionPointName, commandJson) =>
        forwardCommand(extensionPointName, commandJson)
      | AbstractCall(handler) => handler->handle
      }
    )

  let applyOutgoingCommandAction = async action =>
    switch action {
    | ExtensionMapping.AbstractPublishPluginExtensionPointCommand(commandJson) =>
      publishCorePluginExtensionPointCommand(commandJson)
    | AbstractPublishExtensionPointCommand(extensionPointName, commandJson) =>
      forwardCommand(extensionPointName, commandJson)
    | AbstractCall(handler) => handler->handle
    }

  let incomingEventHandler = async (eventJson', pluginDef) => {
    let event' = Message.event'_decode(
      ReventlessSpec.Id.StringPure.t_decode,
      MappingSpec.event_decode,
      eventJson',
    )

    switch event' {
    | Belt.Result.Ok(event') =>
      let commandActions = mapIncomingEvent(event', pluginDef, Spec.queryEngine)
      let apply = async commandActions => {
        await commandActions
        ->Belt.Array.map(applyIncomingCommandAction)
        ->Js.Promise.all
        ->Util.Promise.toUnit
      }
      await commandActions->apply

      switch Spec.readModelNamesForSourceName
      ->Js.Dict.get(event'.meta.service)
      ->Belt.Option.map(readModelNames =>
        readModelNames
        ->Belt.Array.keepMap(readModelName =>
          Spec.publishToReadModels
          ->Js.Dict.get(readModelName)
          ->Belt.Option.map(
            enqueueEvent => enqueueEvent(0, event'.id, eventJson'->Js.Json.stringify),
          )
        ) // FIXME Error handling
        ->Js.Promise.all
      ) {
      | Some(p) =>
        let _ = await p
      | None => ()
      }

    | Error(msg) => Js.log2("Could not decode event':", msg)
    }
  }

  let outgoingEventHandler = (eventJson', pluginDef) => {
    let commandActions = mapOutgoingEvent(eventJson', pluginDef)
    commandActions
    ->Belt.Array.map(applyOutgoingCommandAction)
    ->Js.Promise.all
    ->Util.Promise.toUnit
  }
}
