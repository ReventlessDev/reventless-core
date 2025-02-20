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

module Make = (
  Spec: Spec,
  MappingSpec: ReventlessSpec.ExtensionPointMapping.Spec,
  Mappings: Mappings with module Spec := MappingSpec,
) => {
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

  let applyCommandAction = async action =>
    switch action {
    | ExtensionPointMapping.AbstractPublishCommand(aggregateName, reference, cmdJson) =>
      let result =
        Spec.publishToAggregates
        ->Js.Dict.get(aggregateName)
        ->Belt.Option.map((publishJsons: CommandTopic.publishJsons) => publishJsons([cmdJson]))
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
