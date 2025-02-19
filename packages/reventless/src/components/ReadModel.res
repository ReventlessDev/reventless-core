let componentType = ComponentType.ReadModel

type t
type outputs = {
  name: string,
  queryDb: QueryDb.outputs,
  eventCollector: Pulumi.Output.t<EventCollector.outputs>,
  sourceNames: array<string>,
}
type operations = {enqueueEvent: EventCollector.enqueueEvent}
type component = Component.t<t, outputs, operations>

let allQueryDbs = allReadModels =>
  Js.Dict.map((readModel: outputs) => readModel.queryDb, allReadModels)

module type T = {
  module Spec: ReventlessSpec.ReadModel_Spec.T

  let make: (
    ~allEventTopics: EventTopic.allOutputs,
    ~opts: Pulumi.ComponentResource.options=?,
  ) => component
}

module Make = (
  Config: Config.T,
  Spec: ReventlessSpec.ReadModel_Spec.T,
  Mappings: ReventlessSpec.Projection.Mappings with module Target := Spec,
  QueryDbStorage: QueryDb.Adapter.Storage with type api = Config.api and type role = Config.role,
  QueryDbResolvers: QueryDb.Adapter.Resolvers
    with type api = Config.api
    and type role = Config.role,
  EventCollectorChannel: EventCollector_Adapter.Channel,
): (T with module Spec = Spec) => {
  module Spec = Spec

  let sourceNames = Mappings.mappings->Belt.Array.map((module(Mapping)) => Mapping.sourceName)

  type projectionOperations = QueryDb.operations<string, Spec.state> // TODO: should we really use this "mixed" type?

  let construct = (~allEventTopics, self, name) => {
    let opts = {Pulumi.ComponentResource.parent: self->Component.toPulumiResource}

    module SpecificQueryDb = QueryDb.Make(Config, Spec, QueryDbStorage, QueryDbResolvers)
    let queryDb = SpecificQueryDb.make(~opts)

    let toProjectionOperations: SpecificQueryDb.operations => projectionOperations = ({
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
    module SpecificEventCollector = EventCollector_Builder.Make(EventCollectorChannel)
    let eventCollector =
      queryDb
      ->Component.operations
      ->Pulumi.Output.apply(operations =>
        SpecificEventCollector.make(
          ~name=name->ComponentType.name(componentType),
          ~eventTopics=allEventTopics->Util.EventTopic.filterEventTopics(sourceNames),
          ~eventsHandler=Runtime.eventsHandler(operations->toProjectionOperations, ...),
          ~memorySize=2048,
          ~policy1=Pulumi.Output.make(None),
          ~policy2=Pulumi.Output.make(None),
          ~opts=Some(opts),
        )
      )

    self->Component.setOperations(
      eventCollector
      ->Pulumi.Output.flatMap(eventCollector => eventCollector->Component.operations)
      ->Pulumi.Output.apply(({enqueueEvent}) => enqueueEvent),
    )
    self->Component.setOutputs({
      name,
      queryDb: queryDb->Component.extractOutputs,
      eventCollector: eventCollector->Component.extractWrappedOutputs,
      sourceNames: sourceNames->Belt.Set.String.toArray,
    })
  }

  let make = (~allEventTopics, ~opts=?): component =>
    Component.make(
      ~componentType=componentType->ComponentType.toString,
      ~name=Spec.name,
      ~construct=construct(~allEventTopics, ...),
      ~opts,
    )
}
