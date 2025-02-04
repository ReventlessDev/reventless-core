let componentType = ComponentType.Core

type outputs = {
  version: string,
  eventCollector: Pulumi.Output.t<EventCollector.outputs>,
  extensionPoints: Pulumi.Output.t<dict<ExtensionPoint.outputs>>,
  aggregates: dict<Aggregate.outputs>,
  readModels: dict<ReadModel.outputs>,
  cloner: Cloner.outputs,
}

type t
type component = Component.t<t, outputs>

type maker = (
  ~version: string,
  ~extensionPoints: array<module(ExtensionPoint.T)>,
  ~aggregates: array<module(Aggregate.T)>,
  ~readModels: array<module(ReadModel.T)>,
  ~scheduler: ReventlessSpec.Scheduler.t,
) => component

module type T = {
  let make: maker
}

module Make = (
  Config: Config.T,
  EventCollectorConnector: EventCollector.Adapter.Connector,
  QueryEngineAdapter: QueryDb.Adapter.QueryEngineAdapter,
  ClonerRunner: Cloner.Adapter.Runner with type api := Config.api,
) => {
  type constructed
  type construct = (component, string) => constructed

  @module("../components/Component") @new
  external make: (
    ~componentType: string,
    ~name: string,
    ~construct: construct,
    ~opts: option<Pulumi.ComponentResource.options>,
  ) => component = "default"

  @send
  external registerOutputs: (component, outputs) => constructed = "registerOutputs"
  @send external setOutputs: (component, outputs) => unit = "setOutputs"
  let setOutputs = (self, outputs) => {
    self->setOutputs(outputs)
    self->registerOutputs(outputs)
  }

  type readModel = {
    module_: module(ReadModel.T),
    readModel: ReadModel.component,
  }

  let construct = (
    ~version,
    ~extensionPoints: array<module(ExtensionPoint.T)>,
    ~aggregates: array<module(Aggregate.T)>,
    ~readModels: array<module(ReadModel.T)>,
    ~scheduler: ReventlessSpec.Scheduler.t,
    self,
    _,
  ) => {
    let opts = {Pulumi.ComponentResource.parent: self->Component.toPulumiResource}

    let addEventMapperFns = Js.Dict.empty()
    let publishToAggregates = Js.Dict.empty()

    let aggregatesWithoutEventMappers =
      aggregates
      ->Belt.Array.map((module(Aggregate: Aggregate.T)) => {
        let aggregate = Aggregate.make(~opts)
        addEventMapperFns->Js.Dict.set(Aggregate.Spec.name, aggregate->Aggregate.addEventMapper)
        publishToAggregates->Js.Dict.set(Aggregate.Spec.name, aggregate->Aggregate.publishJsons)
        aggregate->Component.extractOutputs
      })
      ->Belt.Array.map(aggregate => {(aggregate.name, aggregate)})
      ->Js.Dict.fromArray

    let allEventTopics = Aggregate.allEventTopics(aggregatesWithoutEventMappers)

    let readModels = readModels->Belt.Array.map((module(ReadModel: ReadModel.T)) => {
      let readModel = ReadModel.make(~allEventTopics, ~opts)
      (ReadModel.Spec.name, {module_: module(ReadModel), readModel})
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

    let outputs =
      publishToAggregates
      ->Pulumi.Output.allDict
      ->Pulumi.Output.apply(publishToAggregates => {
        let (extensionPointsOutputs, extensionPointsOutgoingEventHandlers) =
          extensionPoints
          ->Belt.Array.map((module(ExtensionPoint: ExtensionPoint.T)) => {
            let extensionPoint = ExtensionPoint.make(
              ~publishToAggregates,
              ~scheduler,
              ~queryEngine,
              ~opts=Some(opts),
            )
            (
              extensionPoint->Component.extractOutputs,
              extensionPoint->ExtensionPoint.outgoingEventHandler->Pulumi.Output.unwrap,
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

        module Runtime = Core_Runtime.Make({
          let pluginDefinition = fakePluginDefinition
          let outgoingExtensionPointEventHandlers = extensionPointsOutgoingEventHandlers
        })
        module PluginEventCollector = EventCollector.Make(EventCollectorConnector)

        let eventCollectorOutputs =
          PluginEventCollector.make(
            ~name=componentType->ComponentType.toName,
            ~eventTopics=aggregatesOutputs->Aggregate.filterEventTopics(aggregateNames),
            ~eventsHandler=Runtime.eventsHandler,
            ~policy1=Pulumi.Output.make(None),
            ~policy2=Pulumi.Output.make(None),
            ~opts=Some(opts),
          )->Component.extractOutputs

        (extensionPointsOutputs, eventCollectorOutputs)
      })

    module Cloner = Cloner.Make(Config, ClonerRunner)
    let cloner = Cloner.make(~opts)

    self->setOutputs({
      version,
      eventCollector: outputs->Pulumi.Output.apply(((_, eventCollectorOutputs)) =>
        eventCollectorOutputs
      ),
      extensionPoints: outputs->Pulumi.Output.apply(((extensionPointsOutputs, _)) =>
        extensionPointsOutputs
        ->Belt.Array.map(ep => (ep.name, ep))
        ->Js.Dict.fromArray
      ),
      aggregates: aggregatesOutputs,
      readModels: readModelsOutputs,
      cloner: cloner->Component.extractOutputs,
    })
  }

  let make: maker = (~version, ~extensionPoints, ~aggregates, ~readModels, ~scheduler) =>
    make(
      ~componentType=componentType->ComponentType.toString,
      ~name="Core",
      ~construct=construct(~version, ~extensionPoints, ~aggregates, ~readModels, ~scheduler, ...),
      ~opts=None,
    )
}
