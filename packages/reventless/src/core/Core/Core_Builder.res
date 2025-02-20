module Make = (
  Config: Config.T,
  EventCollectorChannel: EventCollector_Adapter.Channel,
  QueryEngineAdapter: QueryDb_Adapter.QueryEngineAdapter,
  ClonerRunner: Cloner.Adapter.Runner with type api := Config.api,
) => {
  type readModel = {
    module_: module(ReadModel.T),
    readModel: ReadModel.component,
  }

  let construct = (
    ~version,
    ~extensionPoints: array<module(ExtensionPoint.T)>,
    ~aggregates: array<module(Aggregate.T)>,
    ~readModels: array<module(ReadModel.T)>,
    ~scheduler: Scheduler.operations,
    self,
    _,
  ) => {
    let opts = {Pulumi.ComponentResource.parent: self->Component.toPulumiResource}

    let addEventMapperFns = Js.Dict.empty()
    let publishToAggregates = Js.Dict.empty()

    let aggregatesWithoutEventMappers =
      aggregates
      ->Belt.Array.map((module(SpecificAggregate: Aggregate.T)) => {
        let aggregate = SpecificAggregate.make(~opts)
        addEventMapperFns->Js.Dict.set(
          SpecificAggregate.Spec.name,
          (aggregate->Component.extractOutputs).addEventMapper,
        )
        publishToAggregates->Js.Dict.set(
          SpecificAggregate.Spec.name,
          aggregate->Component.operations->Pulumi.Output.apply(({publishJsons}) => publishJsons),
        )
        aggregate->Component.extractOutputs
      })
      ->Belt.Array.map(aggregate => {(aggregate.name, aggregate)})
      ->Js.Dict.fromArray

    let allEventTopics = Aggregate.allEventTopics(aggregatesWithoutEventMappers)

    let readModels = readModels->Belt.Array.map((module(SpecificReadModel: ReadModel.T)) => {
      let readModel = SpecificReadModel.make(~allEventTopics, ~opts)
      (SpecificReadModel.Spec.name, {module_: module(SpecificReadModel), readModel})
    })
    let readModelsOutputs =
      readModels
      ->Js.Dict.fromArray
      ->Js.Dict.entries
      ->Belt.Array.map(((name, {readModel})) => (name, readModel->Component.extractOutputs))
      ->Js.Dict.fromArray

    let allQueryDbs = readModelsOutputs->ReadModel.allQueryDbs
    let queryEngine = QueryEngineAdapter.make(allQueryDbs)

    let aggregatesOutputs = Js.Dict.map(
      addEventMapperFn => addEventMapperFn(allEventTopics, queryEngine),
      addEventMapperFns,
    )

    let (extensionPointsOutputs, eventCollectorOutputs) =
      publishToAggregates
      ->Pulumi.Output.allDict
      ->Pulumi.Output.apply(publishToAggregates => {
        let (extensionPointsOutputs, extensionPointsOutgoingEventHandlers) =
          extensionPoints
          ->Belt.Array.map((module(SpecificExtensionPoint: ExtensionPoint.T)) => {
            let extensionPoint = SpecificExtensionPoint.make(
              ~publishToAggregates,
              ~scheduler,
              ~queryEngine,
              ~opts=Some(opts),
            )
            (
              extensionPoint->Component.extractOutputs,
              extensionPoint
              ->Component.operations
              ->Pulumi.Output.apply(({outgoingEventHandler}) => outgoingEventHandler),
            )
          })
          ->Belt.Array.unzip

        let aggregateNames =
          extensionPointsOutputs
          ->Belt.Array.map(extensionPointOutputs =>
            extensionPointOutputs.aggregateNames->Belt.Set.String.fromArray
          )
          ->Belt.Array.reduce(Belt.Set.String.empty, Belt.Set.String.union)

        let fakePluginDefinition: ReventlessSpec.Plugin.pluginDefinition = {
          id: "Core@FAKE",
          name: "Core",
          version: "FAKE",
          extensionPoints: [],
          extensions: [],
          eventCollector: "NOT-SET",
        }

        let eventCollectorOutputs =
          extensionPointsOutgoingEventHandlers
          ->Pulumi.Output.all
          ->Pulumi.Output.apply(extensionPointsOutgoingEventHandlers => {
            module Callback = Core_Callback.Make({
              let pluginDefinition = fakePluginDefinition
              let outgoingExtensionPointEventHandlers = extensionPointsOutgoingEventHandlers
            })
            module PluginEventCollector = EventCollector_Builder.Make(EventCollectorChannel)

            PluginEventCollector.make(
              ~name=Core.componentType->ComponentType.toName,
              ~eventTopics=aggregatesOutputs->Aggregate.filterEventTopics(aggregateNames),
              ~eventsHandler=Callback.eventsHandler,
              ~policy1=Pulumi.Output.make(None),
              ~policy2=Pulumi.Output.make(None),
              ~opts=Some(opts),
            )->Component.extractOutputs
          })
        (extensionPointsOutputs, eventCollectorOutputs)
      })
      ->Pulumi.Output.unzip

    module Cloner = Cloner.Make(Config, ClonerRunner)
    let cloner = Cloner.make(~opts)

    self->Component.setOutputs({
      Core.version,
      eventCollector: eventCollectorOutputs->Pulumi.Output.flatMap(eventCollectorOutputs =>
        eventCollectorOutputs
      ),
      extensionPoints: extensionPointsOutputs->Pulumi.Output.apply(extensionPointsOutputs =>
        extensionPointsOutputs
        ->Belt.Array.map(ep => (ep.name, ep))
        ->Js.Dict.fromArray
      ),
      aggregates: aggregatesOutputs,
      readModels: readModelsOutputs,
      cloner: cloner->Component.extractOutputs,
    })
  }

  let make = (~version, ~extensionPoints, ~aggregates, ~readModels, ~scheduler): Core.component =>
    Component.make(
      ~componentType=Core.componentType->ComponentType.toString,
      ~name="Core",
      ~construct=construct(~version, ~extensionPoints, ~aggregates, ~readModels, ~scheduler, ...),
      ~opts=None,
    )
}
