open Core_Helpers

module Make = (
  Config: Config.T,
  RuntimeEnvironment: Runtime.Environment,
  EventCollectorChannel: EventCollector_Adapter.Channel
    with type runtimeParts = RuntimeEnvironment.parts,
  QueryEngineAdapter: QueryDb_Adapter.QueryEngineAdapter,
  ClonerRunner: Cloner.Adapter.Runner with type api := Config.api,
  CoreRuntimeBuilder: PluginRuntime_Builder.T
    with module EventCollectorChannel = EventCollectorChannel
    and type runtimeParts = RuntimeEnvironment.parts,
) => {
  let construct = (
    ~version,
    ~extensionPoints: array<module(ExtensionPoint.T)>,
    ~aggregates: array<module(Aggregate.T)>,
    ~readModels: array<module(ReadModel.T)>,
    ~scheduler: Pulumi.Output.t<Scheduler.operations>,
    self,
    _,
  ) => {
    let opts = {Pulumi.ComponentResource.parent: self->Component.toPulumiResource}
    let name = Core.componentType->ComponentType.toName

    let aggregatesWithoutEventMappers = aggregates->createAggregatesWithoutEventMappers(opts)
    let allEventTopics = Aggregate.allEventTopics(aggregatesWithoutEventMappers)
    let readModelsOutputs = readModels->createReadModels(allEventTopics, opts)

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
        let aggregatesOutputs = aggregates->addEventMappers(allEventTopics, queryEngine)

        let (extensionPointsOutputs, extensionPointsOutgoingEventHandlers) =
          extensionPoints->createExtensionPoints(
            ~aggregateResources,
            ~publishToAggregates,
            ~scheduler,
            ~queryEngine,
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

    module Cloner = Cloner.Make(Config, ClonerRunner)
    let cloner = Cloner.make(~opts)

    self->Component.setOutputs({
      Core.version,
      eventCollector: eventCollectorOutputs,
      extensionPoints: extensionPointsOutputs->Pulumi.Output.apply(extensionPointsOutputs =>
        extensionPointsOutputs
        ->Array.map(ep => (ep.name, ep))
        ->Js.Dict.fromArray
      ),
      aggregates: aggregatesOutputs,
      readModels: readModelsOutputs,
      cloner: cloner->Component.outputs,
    })
  }

  let make = (~version, ~extensionPoints, ~aggregates, ~readModels, ~scheduler): Core.component =>
    Component.make(
      ~componentType=Core.componentType->ComponentType.toString,
      ~name="Core",
      ~construct=construct(~version, ~extensionPoints, ~aggregates, ~readModels, ~scheduler, ...),
      ~opts=None
    )
}
