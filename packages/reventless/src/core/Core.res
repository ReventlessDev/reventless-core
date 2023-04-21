let componentType = ComponentType.Core

type outputs = {
  "version": string,
  "eventCollector": EventCollector.outputs,
  "extensionPoints": Js.Dict.t<ExtensionPoint.outputs>,
  "aggregates": Pulumi.Output.t<Js.Dict.t<Aggregate.outputs>>,
  "readModels": Pulumi.Output.t<Js.Dict.t<ReadModel.outputs>>,
  "cloner": Cloner.outputs,
}

type t
type component = Component.t<t, outputs>

type maker = (
  ~version: string,
  ~extensionPoints: array<module(ExtensionPoint.T)>,
  ~aggregates: array<module(Aggregate.T)>,
  ~readModels: array<module(ReadModel.T)>,
  ~scheduler: Scheduler.t,
) => component

module type T = {
  let make: maker
}

let toDict = els => els->Belt.Array.map(el => (el["name"], el))->Js.Dict.fromArray

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
    ~opts: option<Pulumi.ComponentResource.Options.t>,
  ) => component = "default"

  @obj
  external makeOutputs: (
    ~version: string,
    ~eventCollector: EventCollector.outputs,
    ~extensionPoints: Js.Dict.t<ExtensionPoint.outputs>,
    ~aggregates: Js.Dict.t<Aggregate.outputs>,
    ~readModels: Js.Dict.t<ReadModel.outputs>,
    ~cloner: Cloner.outputs,
  ) => outputs = ""

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
    ~scheduler: Scheduler.t,
    self,
    _,
  ) => {
    let opts = Pulumi.ComponentResource.Options.make(~parent=self->Component.toPulumiResource, ())

    let addEventMapperFns = Js.Dict.empty()
    let publishToAggregates = Js.Dict.empty()

    let aggregatesWithoutEventMappers =
      aggregates
      ->Belt.Array.map((module(Aggregate: Aggregate.T)) => {
        let aggregate = Aggregate.make(~opts, ())
        addEventMapperFns->Js.Dict.set(Aggregate.Spec.name, aggregate->Aggregate.addEventMapper)
        publishToAggregates->Js.Dict.set(Aggregate.Spec.name, aggregate->Aggregate.publishJsons)
        aggregate->Component.extractOutputs
      })
      ->toDict

    let allEventTopics = Util.Aggregate.allEventTopics(aggregatesWithoutEventMappers)

    let readModels = readModels->Belt.Array.map((module(ReadModel: ReadModel.T)) => {
      let readModel = ReadModel.make(~allEventTopics, ~opts, ())
      (ReadModel.Spec.name, {module_: module(ReadModel), readModel})
    })
    let readModelsOutputs =
      readModels
      ->Js.Dict.fromArray
      ->Js.Dict.entries
      ->Belt.Array.map(((name, {readModel})) => (name, readModel->Component.extractOutputs))
      ->Js.Dict.fromArray

    let allQueryDbs = readModelsOutputs->Util.ReadModel.allQueryDbs
    let queryEngine = QueryEngineAdapter.make(allQueryDbs)

    let aggregatesOutputs = Js.Dict.map(
      (. addEventMapperFn) => addEventMapperFn(allEventTopics, queryEngine),
      addEventMapperFns,
    )

    let extensionPoints =
      extensionPoints->Belt.Array.map((module(ExtensionPoint: ExtensionPoint.T)) =>
        ExtensionPoint.make(~publishToAggregates, ~scheduler, ~queryEngine, ~opts=Some(opts), ())
      )
    let extensionPointsOutputs = extensionPoints->Component.extractMultipleOutputs

    let aggregateNames =
      extensionPointsOutputs
      ->Belt.Array.map(extensionPoint =>
        extensionPoint["aggregateNames"]->Belt.Set.String.fromArray
      )
      ->Belt.Array.reduce(Belt.Set.String.empty, Belt.Set.String.union)

    let fakePluginDefinition: PluginSpec.pluginDefinition = {
      id: "Core@FAKE",
      name: "Core",
      version: "FAKE",
      extensionPoints: [],
      extensions: [],
      eventCollector: "NOT-SET",
    }

    let eventsHandler = (. events'Json) => {
      let count = events'Json->Belt.Array.size
      events'Json
      ->Belt.Array.mapWithIndex((idx, event'Json) => {
        let idx = idx + 1
        event'Json->Message.logEvent'Json(
          `Core eventHandler: outgoing event ${idx->Belt.Int.toString}/${count->Belt.Int.toString}:`,
        )
        extensionPointsOutputs
        ->Belt.Array.map(extensionPoint => {
          let handle = extensionPoint["outgoingEventHandler"]
          handle(. event'Json, fakePluginDefinition)
        })
        ->Js.Promise.all
        ->Js.Promise.then_(_ => Js.Promise.resolve(), _)
      })
      ->Js.Promise.all
      ->Js.Promise.then_(_ => Js.Promise.resolve(), _)
    }

    module EventCollector = EventCollector.Make(EventCollectorConnector)

    let eventCollector = EventCollector.make(
      ~name=componentType->ComponentType.toName,
      ~eventTopics=aggregatesOutputs->Util.Aggregate.filterEventTopics(aggregateNames),
      ~eventsHandler,
      ~policy1=Pulumi.Output.make(None),
      ~policy2=Pulumi.Output.make(None),
      ~opts=Some(opts),
      (),
    )

    module Cloner = Cloner.Make(Config, ClonerRunner)
    let cloner = Cloner.make(~opts, ())

    makeOutputs(
      ~version,
      ~eventCollector=eventCollector->Component.extractOutputs,
      ~extensionPoints=extensionPointsOutputs->toDict,
      ~aggregates=aggregatesOutputs,
      ~readModels=readModelsOutputs,
      ~cloner=cloner->Component.extractOutputs,
    )->setOutputs(self, _)
  }

  let make: maker = (~version, ~extensionPoints, ~aggregates, ~readModels, ~scheduler) =>
    make(
      ~componentType=componentType->ComponentType.toString,
      ~name="Core",
      ~construct=construct(~version, ~extensionPoints, ~aggregates, ~readModels, ~scheduler),
      ~opts=None,
    )
}
