module type Mappings = {
  module Spec: ReventlessSpec.ExtensionPointMapping.Spec
  module type Mapping = ExtensionPointMapping.T with module ExtensionPoint := Spec
  let mappings: array<module(Mapping)>
}

module type Spec = {
  let publishToAggregates: dict<ReventlessSpec.CommandTopic.publishJsons>
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

  let mapIncomingCommands = (topicItems, mappings, scheduler, queryEngine, queue) =>
    mappings
    ->Belt.Array.map((module(Mapping: Mappings.Mapping)) =>
      Mapping.mapIncomingCommands(
        topicItems,
        Schedule.create(scheduler, queue),
        Schedule.delete(scheduler, queue),
        queryEngine,
      )
    )
    ->Belt.Array.concatMany

  let mapOutgoingEvent = (event'Json, mappings, scheduler, queue, queryEngine) =>
    switch event'Json->Message.serviceNameOfMsg->findOutgoingMapping(mappings) {
    | Some(module(Mapping)) =>
      switch Mapping.mapOutgoingEvent {
      | Some(mapOutgoingEvent) =>
        mapOutgoingEvent(
          event'Json,
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
        "ExtensionPoint.Mapping: Missing mapping for " ++ event'Json->Js.Json.stringify,
      )
    }

  let applyCommandAction = async action =>
    switch action {
    | ExtensionPointMapping.AbstractPublishCommand(aggregateName, reference, cmdJson) =>
      let result =
        Spec.publishToAggregates
        ->Js.Dict.get(aggregateName)
        ->Belt.Option.map((publishJsons: ReventlessSpec.CommandTopic.publishJsons) =>
          publishJsons([cmdJson])
        )
        ->Belt.Option.mapWithDefault(
          () =>
            Js.Exn.raiseError(
              `ExtensionPoint.applyCommandAction: Aggregate ${aggregateName} doesn't exist`,
            ),
          x => {() => x},
        )
      switch result() {
      | _ => Belt.Result.Ok(reference)
      | exception err => {
          Js.log2("ExtensionPoint: Error on publish command:", err)
          Belt.Result.Error(reference)
        }
      }
    | AbstractCall(reference, handler) =>
      switch await handler() {
      | _ => Belt.Result.Ok(reference)
      | exception err => {
          err->Js.log2("ExtensionPoint: Error on calling handler:")
          Belt.Result.Error(reference)
        }
      }
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

  let outgoingEventHandler = async (event'Json, _pluginDef) => {
    let eventActions = mapOutgoingEvent(
      event'Json,
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
  let incomingCommandsHandler = async topicItems => {
    let commandActions =
      topicItems->mapIncomingCommands(
        Mappings.mappings,
        Spec.scheduler,
        Spec.queryEngine,
        Spec.commandTopicResources,
      )

    await commandActions->Belt.Array.map(applyCommandAction)->Js.Promise.all
  }
}
