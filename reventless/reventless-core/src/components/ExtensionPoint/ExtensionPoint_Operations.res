module type Mappings = {
  module Spec: ReventlessInfra.ExtensionPointMapping.Spec
  module type Mapping = ReventlessInfra.ExtensionPointMapping.T with module ExtensionPoint := Spec
  let mappings: array<module(Mapping)>
}

module type Ops = {
  let publishToEventTopic: EventTopic.publishJson
  let commandTopicResources: array<Adapter.resolvedResource>
  let scheduler: Scheduler.operations
  let queryEngine: Reventless.QueryEngine.operations
  let resourceNaming: ReventlessInfra.ResourceNaming.operations
}

module Make = (
  MappingSpec: ReventlessInfra.ExtensionPointMapping.Spec,
  Mappings: Mappings with module Spec := MappingSpec,
  Ops: Ops,
) => {
  let findOutgoingMapping = (aggregateNameOpt, mappings) =>
    aggregateNameOpt->Option.flatMap(aggregateName =>
      mappings->Array.find((module(Mapping: Mappings.Mapping)) =>
        Mapping.aggregateName == aggregateName
      )
    ) // TODO: handle multiple mappings for same Aggregate name

  let mapOutgoingEvent = (eventJson', mappings, scheduler, queue, queryEngine, resourceNaming) =>
    switch eventJson'->Message.serviceNameOfMsg->findOutgoingMapping(mappings) {
    | Some(module(Mapping)) =>
      switch Mapping.mapOutgoingEvent {
      | Some(mapOutgoingEvent) =>
        mapOutgoingEvent(
          eventJson',
          ScheduleOps.create(~scheduler, ~channelResources=queue, ~resourceNaming),
          ScheduleOps.delete(~scheduler, ~channelResources=queue, ~resourceNaming),
          queryEngine,
        )
      | None =>
        Effect.logError(
          "mapOutgoingEvent: shouldn't be called, because Plugin EventCollector shouldn't subscribe to EventLog stream not having mapOutgoingEvent() !",
        )->Effect.runSync
        []
      }
    | None =>
      JsError.throwWithMessage(
        "ExtensionPoint.Mapping: Missing mapping for " ++ eventJson'->JSON.stringify,
      )
    }

  let applyEventAction = async action =>
    switch action {
    | ReventlessInfra.ExtensionPointMapping.AbstractPublishEvent(id, meta, eventJson) =>
      Effect.logInfo(
        `ExtensionPoint_Operations.applyEventAction: ${eventJson->JSON.stringify}`,
      )->Effect.runSync
      try await Ops.publishToEventTopic(id, meta, eventJson) catch {
      | err =>
        let errMsg =
          err->JsExn.fromException->Option.flatMap(JsExn.message)->Option.getOr("unknown")
        Effect.logError(
          `ExtensionPoint: Error on publishToEventTopic command: ${errMsg}`,
        )->Effect.runSync
      }
    | ReventlessInfra.ExtensionPointMapping.AbstractPublishEventAsync(promise) =>
      let publishToEventTopic = async promise => {
        let (id, meta, eventJson) = await promise
        try await Ops.publishToEventTopic(id, meta, eventJson) catch {
        | err =>
          let errMsg =
            err->JsExn.fromException->Option.flatMap(JsExn.message)->Option.getOr("unknown")
          Effect.logError(
            `ExtensionPoint: Error on publishToEventTopic command: ${errMsg}`,
          )->Effect.runSync
        }
      }
      await promise->publishToEventTopic
    | AbstractCall(handler) =>
      try await handler() catch {
      | err =>
        let errMsg =
          err->JsExn.fromException->Option.flatMap(JsExn.message)->Option.getOr("unknown")
        Effect.logError(`ExtensionPoint: Error on calling handler: ${errMsg}`)->Effect.runSync
      }
    }

  let outgoingJsonEventsHandler = async (eventJson', _pluginDef) => {
    Effect.logInfo(
      `ExtensionPoint_Operations.outgoingJsonEventsHandler: ${eventJson'->JSON.stringify}`,
    )->Effect.runSync
    let eventActions = mapOutgoingEvent(
      eventJson',
      Mappings.mappings,
      Ops.scheduler,
      Ops.commandTopicResources,
      Ops.queryEngine,
      Ops.resourceNaming,
    )

    await eventActions
    ->Array.map(applyEventAction)
    ->Promise.all
    ->Util.Promise.toUnit
  }
}
