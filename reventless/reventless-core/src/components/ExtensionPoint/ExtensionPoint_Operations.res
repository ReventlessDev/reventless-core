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
  let findOutgoingMapping = (delegateNameOpt, mappings) =>
    delegateNameOpt->Option.flatMap(delegateName =>
      mappings->Array.find((module(Mapping: Mappings.Mapping)) =>
        Mapping.delegateName == delegateName
      )
    ) // TODO: handle multiple mappings for same Target name

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

  let publishWithHooks = async (id, meta, eventJson) => {
    // Run beforePublish hook — if it throws, log the error and publish original event.
    let finalEventJson = switch EventPublish_Callback.beforePublishHook.contents {
    | None => eventJson
    | Some(hook) =>
      let published: EventPublish_Callback.publishedEvent = {
        componentName: MappingSpec.name,
        entityId: id,
        eventCount: 1,
        eventsJson: [eventJson],
        meta,
      }
      try {
        let result = await hook(published)
        result.eventsJson->Array.getUnsafe(0)
      } catch {
      | err =>
        let errMsg =
          err->JsExn.fromException->Option.flatMap(JsExn.message)->Option.getOr("unknown")
        Effect.logError(
          `ExtensionPoint(${MappingSpec.name}): beforePublishHook error: ${errMsg}`,
        )->Effect.runSync
        eventJson
      }
    }

    try await Ops.publishToEventTopic(id, meta, finalEventJson) catch {
    | err =>
      let errMsg =
        err->JsExn.fromException->Option.flatMap(JsExn.message)->Option.getOr("unknown")
      Effect.logError(
        `ExtensionPoint: Error on publishToEventTopic command: ${errMsg}`,
      )->Effect.runSync
    }

    // Run afterPublish hook — fire-and-forget, errors are caught and logged.
    switch EventPublish_Callback.afterPublishHook.contents {
    | None => ()
    | Some(hook) =>
      try {
        let published: EventPublish_Callback.publishedEvent = {
          componentName: MappingSpec.name,
          entityId: id,
          eventCount: 1,
          eventsJson: [finalEventJson],
          meta,
        }
        let _ = await hook(published)
      } catch {
      | err =>
        let errMsg =
          err->JsExn.fromException->Option.flatMap(JsExn.message)->Option.getOr("unknown")
        Effect.logError(
          `ExtensionPoint(${MappingSpec.name}): afterPublishHook error: ${errMsg}`,
        )->Effect.runSync
      }
    }
  }

  let applyEventAction = async action =>
    switch action {
    | ReventlessInfra.ExtensionPointMapping.AbstractPublishEvent(id, meta, eventJson) =>
      Effect.logInfo(
        `ExtensionPoint_Operations.applyEventAction: ${eventJson->JSON.stringify}`,
      )->Effect.runSync
      await publishWithHooks(id, meta, eventJson)
    | ReventlessInfra.ExtensionPointMapping.AbstractPublishEventAsync(promise) =>
      let (id, meta, eventJson) = await promise
      await publishWithHooks(id, meta, eventJson)
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
