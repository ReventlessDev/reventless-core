module type Mappings = {
  module Spec: ReventlessInfra.ExtensionPointMapping.Spec
  module type Mapping = ReventlessInfra.ExtensionPointMapping.T with module ExtensionPoint := Spec
  let mappings: array<module(Mapping)>
}

module type Spec = {
  let publishToAggregates: dict<CommandTopic.publishJsons>
  let commandTopicResources: array<Adapter.resolvedResource>
  let scheduler: Scheduler.operations
  let queryEngine: Reventless.QueryEngine.operations
  let resourceNaming: ReventlessInfra.ResourceNaming.operations
}

module type T = {
  module MappingSpec: ReventlessInfra.ExtensionPointMapping.Spec
  let handleIncomingCommands: CommandTopic.commandsHandler<
    Message.command'<Reventless.Id.String.t, MappingSpec.command>,
  >
}

module Make = (
  Spec: Spec,
  MappingSpec: ReventlessInfra.ExtensionPointMapping.Spec,
  Mappings: Mappings with module Spec := MappingSpec,
): (T with module MappingSpec = MappingSpec) => {
  module MappingSpec = MappingSpec

  let mapIncomingCommands = (topicItems, mappings, scheduler, queryEngine, resourceNaming, queue) =>
    mappings
    ->Array.map((module(Mapping: Mappings.Mapping)) =>
      Mapping.mapIncomingCommands(
        topicItems,
        ScheduleOps.create(~scheduler, ~channelResources=queue, ~resourceNaming),
        ScheduleOps.delete(~scheduler, ~channelResources=queue, ~resourceNaming),
        queryEngine,
      )
    )
    ->Array.flat

  let applyCommandAction = async action =>
    switch action {
    | ReventlessInfra.ExtensionPointMapping.AbstractPublishCommand(aggregateName, reference, cmdJson) =>
      let result =
        Spec.publishToAggregates
        ->Dict.get(aggregateName)
        ->Option.map((publishJsons: CommandTopic.publishJsons) => publishJsons([cmdJson]))
        ->Option.mapOr(
          () =>
            JsError.throwWithMessage(
              `ExtensionPoint.applyCommandAction: Aggregate ${aggregateName} doesn't exist`,
            ),
          x => {() => x},
        )
      switch result() {
      | _ => Ok(reference)
      | exception err => {
          Console.log2("ExtensionPoint: Error on publish command:", err)
          Error(reference)
        }
      }
    | AbstractCall(reference, handler) =>
      switch await handler() {
      | _ => Ok(reference)
      | exception err => {
          err->Console.log2("ExtensionPoint: Error on calling handler:")
          Error(reference)
        }
      }
    }

  let handleIncomingCommands = stream =>
    stream
    ->Stream.runCollect
    ->Effect.flatMap(topicItems =>
      Effect.promise(async () => {
        let commandActions =
          topicItems->mapIncomingCommands(
            Mappings.mappings,
            Spec.scheduler,
            Spec.queryEngine,
            Spec.resourceNaming,
            Spec.commandTopicResources,
          )
        await commandActions->Array.map(applyCommandAction)->Promise.all
      })
    )
}
