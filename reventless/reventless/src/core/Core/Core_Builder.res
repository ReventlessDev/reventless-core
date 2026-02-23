open Core_Helpers

module Make = (
  RuntimeEnvironment: Runtime.Environment,
  EventCollectorChannel: EventCollector_Adapter.Channel
    with type runtimeParts = RuntimeEnvironment.parts,
  QueryEngineAdapter: QueryDb_Adapter.QueryEngineAdapter,
  ClonerRunner: Cloner.Adapter.Runner,
  CoreRuntimeBuilder: PluginRuntime_Builder.T
    with module EventCollectorChannel = EventCollectorChannel
    and type runtimeParts = RuntimeEnvironment.parts,
) => {
  type api = ClonerRunner.api

  let construct = (
    ~version,
    ~extensionPoints: array<module(ReventlessSpec.ExtensionPoint.T)>,
    ~aggregates: array<module(ReventlessSpec.Aggregate.T with type api = api)>,
    ~readModels: array<module(ReventlessSpec.ReadModel.T with type api = api and type role = 'role)>,
    ~scheduler: Pulumi.Output.t<Scheduler.operations>,
    ~resourceNaming: ReventlessSpec.ResourceNaming.operations,
    ~api: ClonerRunner.api,
    ~apiRole: 'role,
    self,
    _,
  ) => {
    let opts = {Pulumi.ComponentResource.parent: self->Component.toPulumiResource}
    let name = Core.componentType->ComponentType.toName

    let aggregatesWithoutEventMappers = aggregates->createAggregatesWithoutEventMappers(~api, opts)
    let allEventTopics = Aggregate.allEventTopics(aggregatesWithoutEventMappers)
    let readModelsOutputs = readModels->createReadModels(~api, ~apiRole, allEventTopics, opts)

    let allQueryDbs = readModelsOutputs->ReadModel.allQueryDbs
    let queryEngine = QueryEngineAdapter.make(allQueryDbs)

    let (aggregatesOutputs, extensionPointsOutputs, eventCollectorOutputs) =
      (
        aggregateResources->Pulumi.Output.allDict,
        publishToAggregates->Pulumi.Output.allDict,
        queryEngine,
        scheduler,
      )
      ->Pulumi.Output.all4
      ->Pulumi.Output.apply(((aggregateResources, publishToAggregates, queryEngine, scheduler)) => {
        let aggregatesOutputs = addEventMappers(allEventTopics, queryEngine)

        let (extensionPointsOutputs, extensionPointsOutgoingEventHandlers) =
          extensionPoints->createExtensionPoints(
            ~aggregateResources,
            ~publishToAggregates,
            ~scheduler,
            ~queryEngine,
            ~resourceNaming,
            ~opts,
          )

        let aggregateNames =
          extensionPointsOutputs
          ->Array.map(extensionPointOutputs =>
            extensionPointOutputs.aggregateNames->Belt.Set.String.fromArray
          )
          ->Array.reduce(Belt.Set.String.empty, (acc, names) => acc->Belt.Set.String.union(names))

        let eventTopics = aggregatesOutputs->Aggregate.filterEventTopics(aggregateNames)

        module EventCollectorHelper = MakeEventCollectorHelper(
          RuntimeEnvironment,
          EventCollectorChannel,
          CoreRuntimeBuilder,
        )
        let (eventCollector, eventCollectorOutputs) = EventCollectorHelper.make(
          ~name,
          ~eventTopics,
          ~opts,
        )

        let _ =
          extensionPointsOutgoingEventHandlers
          ->Pulumi.Output.all
          ->Pulumi.Output.flatMap(extensionPointsOutgoingEventHandlers =>
            EventCollectorHelper.connect(
              ~eventCollector,
              ~eventTopics,
              ~extensionPointsOutputs,
              ~extensionPointsOutgoingEventHandlers,
            )
          )
        (aggregatesOutputs, extensionPointsOutputs, eventCollectorOutputs)
      })
      ->Pulumi.Output.unzip3

    module Cloner = Cloner.Make(ClonerRunner)
    let cloner = Cloner.make(~api, ~opts)

    self->Component.setOutputs({
      Core.version,
      eventCollector: eventCollectorOutputs,
      extensionPoints: extensionPointsOutputs->Pulumi.Output.apply(extensionPointsOutputs =>
        extensionPointsOutputs->Array.map(ep => (ep.name, ep))->Dict.fromArray
      ),
      aggregates: aggregatesOutputs,
      readModels: readModelsOutputs,
      cloner: cloner->Component.outputs,
    })
  }

  let make = (
    ~version,
    ~extensionPoints,
    ~aggregates: array<module(ReventlessSpec.Aggregate.T with type api = api)>,
    ~readModels: array<module(ReventlessSpec.ReadModel.T with type api = api and type role = 'role)>,
    ~scheduler,
    ~api: ClonerRunner.api,
    ~apiRole: 'role,
    ~resourceNaming,
  ): Core.component =>
    Component.make(
      ~componentType=Core.componentType->ComponentType.toString,
      ~name="Core",
      ~construct=construct(
        ~version,
        ~extensionPoints,
        ~aggregates,
        ~readModels,
        ~scheduler,
        ~api,
        ~apiRole,
        ~resourceNaming,
        ...
      ),
      ~opts=None,
    )
}
