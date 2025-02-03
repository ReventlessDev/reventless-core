let componentType = ComponentType.ReadModel

type outputs = {
  name: string,
  queryDb: QueryDb.outputs,
  eventCollector: Pulumi.Output.t<EventCollector.outputs>,
}

let allQueryDbs = allReadModels =>
  Js.Dict.map((readModel: outputs) => readModel.queryDb, allReadModels)

type t
type component = Component.t<t, outputs>

module type T = {
  module Spec: ReventlessSpec.ReadModel_Spec.T

  let make: (
    ~allEventTopics: EventTopic.allOutputs,
    ~opts: Pulumi.ComponentResource.options=?,
  ) => component

  let enqueueEvent: component => Pulumi.Output.t<ReventlessSpec.EventCollector.enqueueEvent>

  let sourceNames: array<string>
}

module Make = (
  Config: Config.T,
  Spec: ReventlessSpec.ReadModel_Spec.T,
  Mappings: ReventlessSpec.Projection.Mappings with module Target := Spec,
  QueryDbStorage: QueryDb.Adapter.Storage with type api = Config.api and type role = Config.role,
  QueryDbResolvers: QueryDb.Adapter.Resolvers
    with type api = Config.api
    and type role = Config.role,
  EventCollectorConnector: EventCollector.Adapter.Connector,
): (T with module Spec = Spec) => {
  module Spec = Spec

  type constructed
  type construct = (component, string) => constructed

  @module("./Component") @new
  external make: (
    ~componentType: string,
    ~name: string,
    ~construct: construct,
    ~opts: option<Pulumi.ComponentResource.options>,
  ) => component = "default"

  @send
  external registerOutputs: (component, outputs) => constructed = "registerOutputs"
  @send
  external setOutputs: (component, outputs) => unit = "setOutputs"
  let setOutputs = (self, outputs) => {
    self->setOutputs(outputs)
    self->registerOutputs(outputs)
  }

  @set
  external setEnqueueEvent: (
    component,
    Pulumi.Output.t<ReventlessSpec.EventCollector.enqueueEvent>,
  ) => unit = "enqueueEvent"
  @get
  external enqueueEvent: component => Pulumi.Output.t<ReventlessSpec.EventCollector.enqueueEvent> =
    "enqueueEvent"

  let sourceNames = Mappings.mappings->Belt.Array.map((module(Mapping)) => Mapping.sourceName)

  type projectionPrimitives = QueryDb.primitives<string, Spec.state> // TODO: should we really use this "mixed" type?

  let construct = (~allEventTopics, self, name) => {
    let opts = {Pulumi.ComponentResource.parent: self->Component.toPulumiResource}

    module QueryDb = QueryDb.Make(Config, Spec, QueryDbStorage, QueryDbResolvers)

    let queryDb = QueryDb.make(~opts)

    let toProjectionPrimitives: QueryDb.primitives => projectionPrimitives = ({
      load,
      save,
      saveBatch,
      count,
      delete,
      deleteBatch,
    }) => {
      load: id => load(id->Spec.Id.makeFromString),
      save: (id, state, saveMode, ttl) => save(id->Spec.Id.makeFromString, state, saveMode, ttl),
      saveBatch: batch =>
        saveBatch(
          batch->Belt.Array.map(((id, state, ttl)) => (id->Spec.Id.makeFromString, state, ttl)),
        ),
      count: (id, fieldName, inc) => count(id->Spec.Id.makeFromString, fieldName, inc),
      delete: (id, subId) => delete(id->Spec.Id.makeFromString, subId),
      deleteBatch: ids =>
        deleteBatch(ids->Belt.Array.map(((id, sort)) => (id->Spec.Id.makeFromString, sort))),
    }

    let sourceNames =
      Mappings.mappings
      ->Belt.Array.map((module(Mapping: Mappings.Mapping)) => Mapping.sourceName)
      ->Belt.Set.String.fromArray

    module Runtime = ReadModel_Runtime.Make(Spec, Mappings)
    module EventCollector = EventCollector.Make(EventCollectorConnector)
    let eventCollector =
      queryDb
      ->QueryDb.primitives
      ->Pulumi.Output.apply(primitives =>
        EventCollector.make(
          ~name=name->ComponentType.name(componentType),
          ~eventTopics=allEventTopics->Util.EventTopic.filterEventTopics(sourceNames),
          ~eventsHandler=Runtime.eventsHandler(primitives->toProjectionPrimitives, ...),
          ~memorySize=2048,
          ~policy1=Pulumi.Output.make(None),
          ~policy2=Pulumi.Output.make(None),
          ~opts=Some(opts),
        )
      )

    self->setEnqueueEvent(
      eventCollector->Pulumi.Output.apply(eventCollector =>
        eventCollector->EventCollector.enqueueEvent
      ),
    )
    self->setOutputs({
      name,
      queryDb: queryDb->Component.extractOutputs,
      eventCollector: eventCollector->Component.extractWrappedOutputs,
    })
  }

  let make = (~allEventTopics, ~opts=?) =>
    make(
      ~componentType=componentType->ComponentType.toString,
      ~name=Spec.name,
      ~construct=construct(~allEventTopics, ...),
      ~opts,
    )
}
