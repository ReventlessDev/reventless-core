module type Mappings = {
  module Spec: ReventlessSpec.ExtensionPointMapping.Spec
  module type Mapping = ExtensionPointMapping.T with module ExtensionPoint := Spec
  let mappings: array<module(Mapping)>
}

module type Spec = {
  let publishToEventTopic: EventTopic.publishJson
  let commandTopicResources: array<Adapter.unwrappedResource>
  let scheduler: Scheduler.operations
  let queryEngine: ReventlessSpec.QueryEngine.operations
}

module Make = (
  Spec: Spec,
  MappingSpec: ReventlessSpec.ExtensionPointMapping.Spec,
  Mappings: Mappings with module Spec := MappingSpec,
) => {
  let findOutgoingMapping = (aggregateNameOpt, mappings) =>
    aggregateNameOpt->Belt.Option.flatMap(aggregateName =>
      mappings->Belt.Array.getBy((module(Mapping: Mappings.Mapping)) =>
        Mapping.aggregateName == aggregateName
      )
    ) // TODO: handle multiple mappings for same Aggregate name

  let mapOutgoingEvent = (eventJson', mappings, scheduler, queue, queryEngine) =>
    switch eventJson'->Message.serviceNameOfMsg->findOutgoingMapping(mappings) {
    | Some(module(Mapping)) =>
      switch Mapping.mapOutgoingEvent {
      | Some(mapOutgoingEvent) =>
        mapOutgoingEvent(
          eventJson',
          Schedule.create(scheduler, queue),
          Schedule.delete(scheduler, queue),
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
      Js.Exn.raiseError(
        "ExtensionPoint.Mapping: Missing mapping for " ++ eventJson'->Js.Json.stringify,
      )
    }

  let applyEventAction = async action =>
    switch action {
    | ExtensionPointMapping.AbstractPublishEvent(id, meta, eventJson) =>
      try await Spec.publishToEventTopic(id, meta, eventJson) catch {
      | err => err->Js.log2("ExtensionPoint: Error on publishToEventTopic command:")
      }
    | ExtensionPointMapping.AbstractPublishEventAsync(promise) =>
      let publishToEventTopic = async promise => {
        let (id, meta, eventJson) = await promise
        try await Spec.publishToEventTopic(id, meta, eventJson) catch {
        | err => err->Js.log2("ExtensionPoint: Error on publishToEventTopic command:")
        }
      }
      await promise->publishToEventTopic
    | AbstractCall(handler) =>
      try await handler() catch {
      | err => err->Js.log2("ExtensionPoint: Error on calling handler:")
      }
    }

  let outgoingEventHandler = async (eventJson', _pluginDef) => {
    let eventActions = mapOutgoingEvent(
      eventJson',
      Mappings.mappings,
      Spec.scheduler,
      Spec.commandTopicResources,
      Spec.queryEngine,
    )

    await eventActions
    ->Belt.Array.map(applyEventAction)
    ->Js.Promise.all
    ->Util.Promise.toUnit
  }
}
