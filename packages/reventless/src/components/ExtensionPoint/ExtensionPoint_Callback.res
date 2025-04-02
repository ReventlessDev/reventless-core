module type Mappings = {
  module Spec: ReventlessSpec.ExtensionPointMapping.Spec
  module type Mapping = ExtensionPointMapping.T with module ExtensionPoint := Spec
  let mappings: array<module(Mapping)>
}

module type Spec = {
  let publishToAggregates: dict<CommandTopic.publishJsons>
  let commandTopicResources: array<Adapter.unwrappedResource>
  let scheduler: Scheduler.operations
  let queryEngine: ReventlessSpec.QueryEngine.operations
}

module type T = {
  module MappingSpec: ReventlessSpec.ExtensionPointMapping.Spec
  let handleIncomingCommands: CommandTopic.commandsHandler<
    Message.command'<ReventlessSpec.Id.String.t, MappingSpec.command>,
  >
}

module Make = (
  Spec: Spec,
  MappingSpec: ReventlessSpec.ExtensionPointMapping.Spec,
  Mappings: Mappings with module Spec := MappingSpec,
): (T with module MappingSpec = MappingSpec) => {
  module MappingSpec = MappingSpec

  let mapIncomingCommands = (topicItems, mappings, scheduler, queryEngine, queue) =>
    mappings
    ->Array.map((module(Mapping: Mappings.Mapping)) =>
      Mapping.mapIncomingCommands(
        topicItems,
        Schedule.create(scheduler, queue),
        Schedule.delete(scheduler, queue),
        queryEngine,
      )
    )
    ->Array.flat

  let applyCommandAction = async action =>
    switch action {
    | ExtensionPointMapping.AbstractPublishCommand(aggregateName, reference, cmdJson) =>
      let result =
        Spec.publishToAggregates
        ->Js.Dict.get(aggregateName)
        ->Option.map((publishJsons: CommandTopic.publishJsons) => publishJsons([cmdJson]))
        ->Option.mapOr(
          () =>
            Js.Exn.raiseError(
              `ExtensionPoint.applyCommandAction: Aggregate ${aggregateName} doesn't exist`,
            ),
          x => {() => x},
        )
      switch result() {
      | _ => Ok(reference)
      | exception err => {
          Js.log2("ExtensionPoint: Error on publish command:", err)
          Error(reference)
        }
      }
    | AbstractCall(reference, handler) =>
      switch await handler() {
      | _ => Ok(reference)
      | exception err => {
          err->Js.log2("ExtensionPoint: Error on calling handler:")
          Error(reference)
        }
      }
    }

  let handleIncomingCommands = async topicItems => {
    let commandActions =
      topicItems->mapIncomingCommands(
        Mappings.mappings,
        Spec.scheduler,
        Spec.queryEngine,
        Spec.commandTopicResources,
      )

    await commandActions->Array.map(applyCommandAction)->Js.Promise.all
  }
}
