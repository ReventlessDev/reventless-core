let componentType = ComponentType.ReadModel

module Make = (
  Config: Config.T,
  Spec: ReventlessSpec.ReadModel.Spec.T,
  Mappings: ReventlessSpec.Projection.Mappings with module Target := Spec,
  QueryDbStorage: QueryDb.Adapter.Storage with type api = Config.api and type role = Config.role,
  QueryDbResolvers: QueryDb.Adapter.Resolvers
    with type api = Config.api
    and type role = Config.role,
  EventCollectorConnector: EventCollector.Adapter.Connector,
): (ReventlessSpec.ReadModel.T with module Spec = Spec) => {
  module Spec = Spec
  type t

  type constructed
  type construct = (ReventlessSpec.ReadModel.component, string) => constructed

  @module("./Component") @new
  external make: (
    ~componentType: string,
    ~name: string,
    ~construct: construct,
    ~opts: option<Pulumi.ComponentResource.Options.t>,
  ) => ReventlessSpec.ReadModel.component = "default"

  @obj
  external makeOutputs: (
    ~name: string,
    ~queryDb: ReventlessSpec.QueryDb.outputs,
    ~eventCollector: ReventlessSpec.EventCollector.outputs,
  ) => ReventlessSpec.ReadModel.outputs = ""
  @send
  external registerOutputs: (
    ReventlessSpec.ReadModel.component,
    ReventlessSpec.ReadModel.outputs,
  ) => constructed = "registerOutputs"
  @send
  external setOutputs: (
    ReventlessSpec.ReadModel.component,
    ReventlessSpec.ReadModel.outputs,
  ) => unit = "setOutputs"
  let setOutputs = (self, outputs) => {
    self->setOutputs(outputs)
    self->registerOutputs(outputs)
  }

  let construct = (~allEventTopics, self, name) => {
    let opts = Pulumi.ComponentResource.Options.make(~parent=self->Component.toPulumiResource, ())

    module QueryDb = QueryDb.Make(Config, Spec, QueryDbStorage, QueryDbResolvers)

    let queryDb = QueryDb.make(~opts, ())

    let load = (. id) => QueryDb.load(queryDb)(. id->Spec.Id.makeFromString)
    let save = (. id, state, saveMode, opt) =>
      QueryDb.save(queryDb)(. id->Spec.Id.makeFromString, state, saveMode, opt)
    let saveBatch = (. states) =>
      QueryDb.saveBatch(queryDb)(.
        states->Belt.Array.map(((id, state, ttl)) => (id->Spec.Id.makeFromString, state, ttl)),
      )
    let delete = (. id, sort) => QueryDb.delete(queryDb)(. id->Spec.Id.makeFromString, sort)
    let deleteBatch = (. ids) =>
      QueryDb.deleteBatch(queryDb)(.
        ids->Belt.Array.map(((id, sort)) => (id->Spec.Id.makeFromString, sort)),
      )

    let primitives = {
      Projection.load,
      save,
      saveBatch,
      delete,
      deleteBatch,
    }

    module EventProjector = ProjectionMapper.Make(Spec, Mappings)

    let eventsHandler: (. array<Js.Json.t>) => Js.Promise.t<unit> = (. jsons) => {
      let eventCount = jsons->Belt.Array.length
      jsons
      ->Belt.Array.mapWithIndex((idx, json) => {
        let idx = idx + 1
        let sourceName =
          json
          ->ReventlessSpec.Message.context_decode
          ->Belt.Result.map(context => context.meta.service)
          ->Belt.Result.getWithDefault("")
        Js.log2(
          `ReadModel: handling event ${idx->Belt.Int.toString}/${eventCount->Belt.Int.toString} from ${sourceName}:`,
          json,
        )
        json->EventProjector.map(~sourceName=Some(sourceName))
      })
      ->Belt.Array.concatMany
      ->Projection.handleActions(primitives, Spec.subIdConfig)
    }

    module Set = Belt.Set.String
    let aggregateNames =
      Mappings.mappings
      ->Belt.Array.map((module(Mapping: Mappings.Mapping)) => Mapping.sourceName)
      ->Set.fromArray

    module EventCollector = EventCollector.Make(EventCollectorConnector)
    let eventCollector = EventCollector.make(
      ~name=name->ComponentType.name(componentType),
      ~eventTopics=allEventTopics->Util.EventTopic.filterEventTopics(aggregateNames),
      ~eventsHandler,
      ~policy1=Pulumi.Output.make(None),
      ~policy2=Pulumi.Output.make(None),
      ~opts=Some(opts),
      (),
    )

    self->setOutputs(
      makeOutputs(
        ~name,
        ~queryDb=queryDb->Component.extractOutputs,
        ~eventCollector=eventCollector->Component.extractOutputs,
      ),
    )
  }

  let make = (~allEventTopics, ~opts=?, _) =>
    make(
      ~componentType=componentType->ComponentType.toString,
      ~name=Spec.name,
      ~construct=construct(~allEventTopics),
      ~opts,
    )
}
