module Make = (
  Config: Config.T,
  Spec: ReventlessSpec.ReadModel_Spec.T,
  Mappings: ReventlessSpec.Projection.Mappings with module Target := Spec,
  QueryDbStorage: QueryDb_Adapter.Storage with type api = Config.api and type role = Config.role,
  QueryDbResolvers: QueryDb_Adapter.Resolvers
    with type api = Config.api
    and type role = Config.role,
  EventCollectorChannel: EventCollector_Adapter.Channel,
): (ReadModel.T with module Spec = Spec) => {
  module Spec = Spec

  type projectionOperations = QueryDb.operations<string, Spec.state> // TODO: should we really use this "mixed" type?

  let construct = (~allEventTopics, self, name) => {
    let opts = {Pulumi.ComponentResource.parent: self->Component.toPulumiResource}

    module SpecificQueryDb = QueryDb_Builder.Make(Config, Spec, QueryDbStorage, QueryDbResolvers)
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

    module SpecificEventCollector = EventCollector_Builder.Make(EventCollectorChannel)
    let eventCollector =
      queryDb
      ->Component.operations
      ->Pulumi.Output.apply(operations => {
        module Callback = ReadModel_Callback.Make(
          Spec,
          Mappings,
          {
            module ReadModelSpec = Spec
            let operations = operations->toProjectionOperations
          },
        )
        SpecificEventCollector.make(
          ~name=name->ComponentType.name(ReadModel.componentType),
          ~eventTopics=allEventTopics->Util.EventTopic.filterEventTopics(sourceNames),
          ~eventsHandler=Callback.eventsHandler,
          ~memorySize=2048,
          ~policy1=Pulumi.Output.make(None),
          ~policy2=Pulumi.Output.make(None),
          ~opts=Some(opts),
        )
      })

    self->Component.setOperations(
      eventCollector
      ->Pulumi.Output.flatMap(eventCollector => eventCollector->Component.operations)
      ->Pulumi.Output.apply(({enqueueEvent}) => enqueueEvent),
    )
    self->Component.setOutputs({
      ReadModel.name,
      queryDb: queryDb->Component.outputs,
      eventCollector: eventCollector->Component.wrappedOutputs,
      sourceNames: sourceNames->Belt.Set.String.toArray,
    })
  }

  let make = (~allEventTopics, ~opts=?): ReadModel.component =>
    Component.make(
      ~componentType=ReadModel.componentType->ComponentType.toString,
      ~name=Spec.name,
      ~construct=construct(~allEventTopics, ...),
      ~opts,
    )
}
