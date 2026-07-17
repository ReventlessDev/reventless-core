module PluginExtensionPointSpec = ReventlessInfra.PluginExtensionPointSpec
module ExtensionMapping = ReventlessInfra.ExtensionMapping

module type Mappings = {
  module Spec: ReventlessInfra.ExtensionMapping.Spec
  module type Mapping = ExtensionMapping.T with module ExtensionPoint := Spec
  let name: string
  let mappings: array<module(Mapping)>
}

module type Ops = {
  let publishToAggregates: dict<CommandTopic.publishJsons>
  let publishToPluginExtensionPoint: CommandTopic.publishJsons
  let readModelNamesForSourceName: dict<array<string>>
  let publishToReadModels: dict<EventCollector.enqueueEvent>
  let queryEngine: Reventless.QueryEngine.operations
}

module type T = {
  let incomingJsonEventsHandler: Extension.jsonEventsHandler
  let outgoingJsonEventsHandler: Extension.jsonEventsHandler
}

module Make = (
  MappingSpec: ReventlessInfra.ExtensionMapping.Spec,
  Mappings: Mappings with module Spec := MappingSpec,
  Ops: Ops,
): T => {
  let comp = `Extension(${MappingSpec.name}.${Mappings.name})`

  let findOutgoingMapping = (delegateNameOpt, mappings) =>
    delegateNameOpt->Option.flatMap(delegateName =>
      mappings->Array.find((module(Mapping: Mappings.Mapping)) =>
        Mapping.delegateName == delegateName
      )
    ) // TODO: handle multiple mappings for same Target name

  let mapIncomingEvent = (
    event': Message.event'<string, MappingSpec.event>,
    pluginDef,
    queryEngine,
  ) =>
    Mappings.mappings
    ->Array.map((module(Mapping: Mappings.Mapping)) =>
      Mapping.mapIncomingEvent(event', pluginDef, queryEngine)
    )
    ->Array.flat

  let mapOutgoingEvent = (eventJson', pluginDef) =>
    switch eventJson'->Message.serviceNameOfMsg->findOutgoingMapping(Mappings.mappings) {
    | Some(module(Mapping)) =>
      switch Mapping.mapOutgoingEvent {
      | Some(mapOutgoingEvent) => mapOutgoingEvent(eventJson', pluginDef)
      | None =>
        EffectLogger.logError(
          ~comp,
          "mapOutgoingEvent: shouldn't be called, because Plugin EventCollector shouldn't subscribe to EventLog stream not having mapOutgoingEvent() !",
        )->Effect.runSync
        []
      }
    | None =>
      JsError.throwWithMessage(
        "ExtensionPoint.Mapping: Missing mapping for " ++ eventJson'->JSON.stringify,
      )
    }

  let publishAggregateCommand = async (aggregateName, cmdJson: Message.commandJson) => {
    EffectLogger.logInfo(
      ~comp,
      `EP→${aggregateName}: ${cmdJson.commandJson->Message.variantNameOfJson->LogFormat.bold}(${cmdJson.id})`,
    )->Effect.runSync
    let pub = Ops.publishToAggregates->Dict.get(aggregateName)->Option.getOrThrow
    try await pub([cmdJson]) catch {
    | err =>
      let errMsg = err->JsExn.fromException->Option.flatMap(JsExn.message)->Option.getOr("unknown")
      EffectLogger.logError(
        ~comp,
        `Error on publish command to aggregate ${aggregateName}: ${errMsg}`,
      )->Effect.runSync
    }
  }

  let publishPluginExtensionPointCommand = async cmdJson =>
    try await Ops.publishToPluginExtensionPoint([cmdJson]) catch {
    | err =>
      let errMsg = err->JsExn.fromException->Option.flatMap(JsExn.message)->Option.getOr("unknown")
      EffectLogger.logError(
        ~comp,
        `Error on publish command to Plugin ExtensionPoint: ${errMsg}`,
      )->Effect.runSync
    }

  let forwardCommand = (extensionPointName, commandJson: Message.commandJson) => {
    let command: PluginExtensionPointSpec.command = ForwardCommand({
      extensionPointName,
      id: commandJson.id,
      command: commandJson->Message.toMessageBody,
    })
    publishPluginExtensionPointCommand({
      Message.id: "",
      // ForwardCommand wraps the original command — derive meta so this hop carries
      // causation (causationId = original command's msgId) and inherits the rest.
      meta: Message.deriveMeta(~parent=commandJson.meta),
      commandJson: command->Message.encode(PluginExtensionPointSpec.commandSchema),
    })
  }

  let handleDirective = async handler =>
    try await handler() catch {
    | err =>
      let errMsg = err->JsExn.fromException->Option.flatMap(JsExn.message)->Option.getOr("unknown")
      EffectLogger.logError(~comp, `Error on handling directive: ${errMsg}`)->Effect.runSync
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
            ->Array.map(((aggregateName, commandJson)) =>
              publishAggregateCommand(aggregateName, commandJson)
            )
            ->Promise.all
          )
          ->Util.Promise.toUnit
        }
        promise->publish
      | AbstractPublishPluginExtensionPointCommand(commandJson) =>
        publishPluginExtensionPointCommand(commandJson)
      | AbstractPublishExtensionPointCommand(extensionPointName, commandJson) =>
        forwardCommand(extensionPointName, commandJson)
      | AbstractHandleDirective(handler) => handler->handleDirective
      }
    )

  let applyOutgoingCommandAction = async action =>
    switch action {
    | ExtensionMapping.AbstractPublishPluginExtensionPointCommand(commandJson) =>
      publishPluginExtensionPointCommand(commandJson)
    | AbstractPublishExtensionPointCommand(extensionPointName, commandJson) =>
      forwardCommand(extensionPointName, commandJson)
    | AbstractHandleDirective(handler) => handler->handleDirective
    }

  let incomingJsonEventsHandler = async (eventJson', pluginDef) => {
    EffectLogger.logInfo(~comp=comp, `incoming EP event: ${LogFormat.eventSummary(eventJson')}`)->Effect.runSync
    switch eventJson'->Message.decodeEvent'(
      Reventless.Id.StringPure.schema,
      MappingSpec.eventSchema,
    ) {
    | event' =>
      let commandActions = mapIncomingEvent(event', pluginDef, Ops.queryEngine)
      let apply = async commandActions => {
        await commandActions
        ->Array.map(applyIncomingCommandAction)
        ->Promise.all
        ->Util.Promise.toUnit
      }
      await commandActions->apply

      switch Ops.readModelNamesForSourceName
      ->Dict.get(event'.meta.service)
      ->Option.map(readModelNames =>
        readModelNames
        ->Array.filterMap(readModelName =>
          Ops.publishToReadModels
          ->Dict.get(readModelName)
          ->Option.map(enqueueEvent => enqueueEvent(0, event'.id, eventJson'->JSON.stringify))
        ) // FIXME Error handling
        ->Promise.all
      ) {
      | Some(p) =>
        let _ = await p
      | None => ()
      }

    | exception err =>
      let errMsg = err->JsExn.fromException->Option.flatMap(JsExn.message)->Option.getOr("unknown")
      EffectLogger.logError(
        ~comp,
        `Could not decode event': ${eventJson'->JSON.stringify} ${errMsg}`,
      )->Effect.runSync
    }
  }

  let outgoingJsonEventsHandler = (eventJson', pluginDef) => {
    EffectLogger.logInfo(~comp=comp, `outgoing delegate event: ${LogFormat.eventSummary(eventJson')}`)->Effect.runSync
    let commandActions = mapOutgoingEvent(eventJson', pluginDef)
    commandActions
    ->Array.map(applyOutgoingCommandAction)
    ->Promise.all
    ->Util.Promise.toUnit
  }
}
