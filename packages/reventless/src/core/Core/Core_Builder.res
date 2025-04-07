module Make = (
  Config: Config.T,
  EventCollectorChannel: EventCollector_Adapter.Channel,
  QueryEngineAdapter: QueryDb_Adapter.QueryEngineAdapter,
  ClonerRunner: Cloner.Adapter.Runner with type api := Config.api,
  CoreRuntimeBuilder: PluginRuntime_Builder.T
    with module EventCollectorChannel = EventCollectorChannel,
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
    ~scheduler: Pulumi.Output.t<Scheduler.operations>,
    self,
    _,
  ) => {
    let opts = {Pulumi.ComponentResource.parent: self->Component.toPulumiResource}
    let name = Core.componentType->ComponentType.toName

    let addEventMapperFns = Js.Dict.empty()
    let aggregateResources = Js.Dict.empty()
    let publishToAggregates = Js.Dict.empty()

    let aggregatesWithoutEventMappers =
      aggregates
      ->Array.map((module(SpecificAggregate: Aggregate.T)) => {
        let aggregate = SpecificAggregate.make(~opts)
        addEventMapperFns->Js.Dict.set(
          SpecificAggregate.Spec.name,
          (aggregate->Component.outputs).addEventMapper,
        )
        let resources =
          (aggregate->Component.outputs).commandTopic->Pulumi.Output.apply(commandTopic =>
            commandTopic.resources
          )
        aggregateResources->Js.Dict.set(SpecificAggregate.Spec.name, resources)
        let publishJsons =
          aggregate->Component.operations->Pulumi.Output.apply(({publishJsons}) => publishJsons)
        publishToAggregates->Js.Dict.set(SpecificAggregate.Spec.name, publishJsons)
        aggregate->Component.outputs
      })
      ->Array.map(aggregate => {(aggregate.name, aggregate)})
      ->Js.Dict.fromArray

    let allEventTopics = Aggregate.allEventTopics(aggregatesWithoutEventMappers)

    let readModels = readModels->Array.map((module(SpecificReadModel: ReadModel.T)) => {
      let readModel = SpecificReadModel.make(~allEventTopics, ~opts)
      (SpecificReadModel.Spec.name, {module_: module(SpecificReadModel), readModel})
    })
    let readModelsOutputs =
      readModels
      ->Js.Dict.fromArray
      ->Js.Dict.entries
      ->Array.map(((name, {readModel})) => (name, readModel->Component.outputs))
      ->Js.Dict.fromArray

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
        let aggregatesOutputs = Js.Dict.map(
          addEventMapperFn => addEventMapperFn(allEventTopics, queryEngine),
          addEventMapperFns,
        )

        let (extensionPointsOutputs, extensionPointsOutgoingEventHandlers) =
          extensionPoints
          ->Array.map((module(SpecificExtensionPoint: ExtensionPoint.T)) => {
            let extensionPoint = SpecificExtensionPoint.make(
              ~aggregateResources,
              ~publishToAggregates,
              ~scheduler,
              ~queryEngine,
              ~opts=Some(opts),
            )
            (
              extensionPoint->Component.outputs,
              extensionPoint
              ->Component.operations
              ->Pulumi.Output.apply(({outgoingEventHandler}) => outgoingEventHandler),
            )
          })
          ->Belt.Array.unzip

        let aggregateNames =
          extensionPointsOutputs
          ->Array.map(extensionPointOutputs =>
            extensionPointOutputs.aggregateNames->Belt.Set.String.fromArray
          )
          ->Array.reduce(Belt.Set.String.empty, (acc, names) => acc->Belt.Set.String.union(names))

        let eventTopics = aggregatesOutputs->Aggregate.filterEventTopics(aggregateNames)
        let resources =
          extensionPointsOutputs
          ->Array.map(extensionPoint => extensionPoint.eventTopic)
          ->Pulumi.Output.all
          ->Pulumi.Output.apply(eventTopics =>
            eventTopics
            ->Array.map(eventTopic => eventTopic.resources)
            ->Array.flat
          )

        let fakePluginDefinition: ReventlessSpec.Plugin.pluginDefinition = {
          id: "Core@FAKE",
          name: "Core",
          version: "FAKE",
          extensionPoints: [],
          extensions: [],
          eventCollector: "NOT-SET",
        }

        let eventCollectorOutputs =
          (extensionPointsOutgoingEventHandlers->Pulumi.Output.all, resources)
          ->Pulumi.Output.all2
          ->Pulumi.Output.apply(((extensionPointsOutgoingEventHandlers, resources)) => {
            module CoreEventCollector = EventCollector_Builder.Make(EventCollectorChannel)
            let eventCollector = CoreEventCollector.make(~name, ~opts)
            let eventCollectorOutputs = eventCollector->Component.outputs
            let opts = {Pulumi.ComponentResource.parent: eventCollector->Component.toPulumiResource}

            module Callback = Core_Callback.Make({
              let pluginDefinition = fakePluginDefinition
              let outgoingExtensionPointEventHandlers = extensionPointsOutgoingEventHandlers
            })
            let handler = CoreEventCollector.makeHandler(
              ~eventCollector,
              ~eventsHandler=Callback.eventsHandler,
            )
            let runtime = eventCollector->CoreRuntimeBuilder.forPluginEventCollector(~handler)

            CoreEventCollector.connect(
              ~name,
              ~eventTopics,
              ~eventCollector,
              ~runtime,
              ~resources,
              ~opts,
            )
            eventCollectorOutputs
          })
        (aggregatesOutputs, extensionPointsOutputs, eventCollectorOutputs)
      })
      ->Pulumi.Output.unzip3

    module Cloner = Cloner.Make(Config, ClonerRunner)
    let cloner = Cloner.make(~opts)

    self->Component.setOutputs({
      Core.version,
      eventCollector: eventCollectorOutputs->Pulumi.Output.flatMap(eventCollectorOutputs =>
        eventCollectorOutputs
      ),
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
