let componentType = ComponentType.ReadModel

let allQueryDbs = allReadModels =>
  Js.Dict.map((readModel: ReventlessSpec.ReadModel.outputs) => readModel.queryDb, allReadModels)

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
    ~opts: option<Pulumi.ComponentResource.options>,
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

  @set
  external setEnqueueEvent: (
    ReventlessSpec.ReadModel.component,
    ReventlessSpec.EventCollector.enqueueEvent,
  ) => unit = "enqueueEvent"
  @get
  external enqueueEvent: ReventlessSpec.ReadModel.component => ReventlessSpec.EventCollector.enqueueEvent =
    "enqueueEvent"

  let sourceNames = Mappings.mappings->Belt.Array.map((module(Mapping)) => Mapping.sourceName)

  let construct = (~allEventTopics, self, name) => {
    let opts = {Pulumi.ComponentResource.parent: self->Component.toPulumiResource}

    module QueryDb = QueryDb.Make(Config, Spec, QueryDbStorage, QueryDbResolvers)

    let queryDb = QueryDb.make(~opts)

    let load = id => QueryDb.load(queryDb)(id->Spec.Id.makeFromString)
    let save = (id, state, saveMode, opt) =>
      QueryDb.save(queryDb)(id->Spec.Id.makeFromString, state, saveMode, opt)
    let saveBatch = states =>
      QueryDb.saveBatch(queryDb)(
        states->Belt.Array.map(((id, state, ttl)) => (id->Spec.Id.makeFromString, state, ttl)),
      )
    let delete = (id, sort) => QueryDb.delete(queryDb)(id->Spec.Id.makeFromString, sort)
    let deleteBatch = ids =>
      QueryDb.deleteBatch(queryDb)(
        ids->Belt.Array.map(((id, sort)) => (id->Spec.Id.makeFromString, sort)),
      )

    let primitives = {
      Projection.load,
      save,
      saveBatch,
      delete,
      deleteBatch,
    }

    let sourceNames =
      Mappings.mappings
      ->Belt.Array.map((module(Mapping: Mappings.Mapping)) => Mapping.sourceName)
      ->Belt.Set.String.fromArray

    module Runtime = ReadModel_Runtime.Make(Spec, Mappings)
    module EventCollector = EventCollector.Make(EventCollectorConnector)
    let eventCollector = EventCollector.make(
      ~name=name->ComponentType.name(componentType),
      ~eventTopics=allEventTopics->Util.EventTopic.filterEventTopics(sourceNames),
      ~eventsHandler=Runtime.eventsHandler(primitives, ...),
      ~memorySize=2048,
      ~policy1=Pulumi.Output.make(None),
      ~policy2=Pulumi.Output.make(None),
      ~opts=Some(opts),
    )

    self->setEnqueueEvent(eventCollector->EventCollector.enqueueEvent)
    self->setOutputs(
      makeOutputs(
        ~name,
        ~queryDb=queryDb->Component.extractOutputs,
        ~eventCollector=eventCollector->Component.extractOutputs,
      ),
    )
  }

  let make = (~allEventTopics, ~opts=?) =>
    make(
      ~componentType=componentType->ComponentType.toString,
      ~name=Spec.name,
      ~construct=construct(~allEventTopics, ...),
      ~opts,
    )
}
