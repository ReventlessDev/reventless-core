module type Mappings = {
  module Spec: ReventlessSpec.ExtensionPointMapping.Spec
  module type Mapping = ReventlessSpec.ExtensionPointMapping.T with module ExtensionPoint := Spec
  let mappings: array<module(Mapping)>
}

module type Ops = {
  let publishToEventTopic: EventTopic.publishJson
  let commandTopicResources: array<Adapter.resolvedResource>
  let scheduler: Scheduler.operations
  let queryEngine: ReventlessSpec.QueryEngine.operations
  let resourceNaming: ReventlessSpec.ResourceNaming.operations
}

module Make = (
  MappingSpec: ReventlessSpec.ExtensionPointMapping.Spec,
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
          Schedule.create(~scheduler, ~channelResources=queue, ~resourceNaming),
          Schedule.delete(~scheduler, ~channelResources=queue, ~resourceNaming),
          queryEngine,
        )
      | None =>
        Logger.error(
          ~loc=__LOC__,
          "mapOutgoingEvent",
          "shouldn't be called, because Plugin EventCollector shouldn't subscribe to EventLog stream not having mapOutgoingEvent() !",
        )
        []
      }
    | None =>
      JsError.throwWithMessage(
        "ExtensionPoint.Mapping: Missing mapping for " ++ eventJson'->JSON.stringify,
      )
    }

  let applyEventAction = async action =>
    switch action {
    | ReventlessSpec.ExtensionPointMapping.AbstractPublishEvent(id, meta, eventJson) =>
      Console.log2("ExtensionPoint_Operations.applyEventAction:", eventJson->JSON.stringify)
      try await Ops.publishToEventTopic(id, meta, eventJson) catch {
      | err => err->Console.log2("ExtensionPoint: Error on publishToEventTopic command:")
      }
    | ReventlessSpec.ExtensionPointMapping.AbstractPublishEventAsync(promise) =>
      let publishToEventTopic = async promise => {
        let (id, meta, eventJson) = await promise
        try await Ops.publishToEventTopic(id, meta, eventJson) catch {
        | err => err->Console.log2("ExtensionPoint: Error on publishToEventTopic command:")
        }
      }
      await promise->publishToEventTopic
    | AbstractCall(handler) =>
      try await handler() catch {
      | err => err->Console.log2("ExtensionPoint: Error on calling handler:")
      }
    }

  let outgoingEventHandler = async (eventJson', _pluginDef) => {
    Console.log2("ExtensionPoint_Operations.outgoingEventHandler:", eventJson'->JSON.stringify)
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
