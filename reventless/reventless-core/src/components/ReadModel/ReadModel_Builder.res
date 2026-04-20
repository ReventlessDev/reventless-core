module Make = (
  Spec: Reventless.ReadModel.Spec,
  Mappings: Reventless.Projection.Mappings with module Target := Spec,
  RuntimeEnvironment: Runtime.Environment,
  QueryDbStorage: QueryDb_Adapter.Storage,
  QueryDbResolvers: QueryDb_Adapter.Resolvers
    with type api = QueryDbStorage.api
    and type role = QueryDbStorage.role,
  EventCollectorChannel: EventCollector_Adapter.Channel
    with type runtimeParts = RuntimeEnvironment.parts,
  EventCollectorRuntimeBuilder: EventCollectorRuntime_Builder.T
    with module EventCollectorChannel = EventCollectorChannel,
): (
  ReadModel.T
    with module Spec = Spec
    and type api = QueryDbStorage.api
    and type role = QueryDbStorage.role
) => {
  module Spec = Spec
  module EventCollectorRuntimeBuilder = EventCollectorRuntimeBuilder

  let sourceNames =
    Mappings.mappings
    ->Array.map((module(Mapping: Mappings.Mapping)) => Mapping.sourceName)
    ->Belt.Set.String.fromArray
    ->Belt.Set.String.toArray

  type api = QueryDbStorage.api
  type role = QueryDbStorage.role
  type component = ReadModel.component
  type projectionOperations = QueryDb.operations<string, Spec.state> // TODO: should we really use this "mixed" type?

  let construct = (
    ~api: QueryDbStorage.api,
    ~apiRole: QueryDbStorage.role,
    ~allEventTopics,
    self,
    name,
  ) => {
    let opts = {Pulumi.ComponentResource.parent: self->Component.toPulumiResource}
    let name = name->ComponentType.name(ReadModel.componentType)

    module SpecificQueryDb = QueryDb_Builder.Make(Spec, QueryDbStorage, QueryDbResolvers)
    let queryDb = SpecificQueryDb.make(~api, ~apiRole, ~opts)

    let toProjectionOperations: SpecificQueryDb.operations => projectionOperations = ({
      load,
      loadStream,
      save,
      saveBatch,
      count,
      delete,
      deleteBatch,
    }) => {
      load: id => load(id->Spec.Id.makeFromString),
      loadStream: id => loadStream(id->Spec.Id.makeFromString),
      save: (id, state, saveMode, ttl) => save(id->Spec.Id.makeFromString, state, saveMode, ttl),
      saveBatch: batch =>
        saveBatch(batch->Array.map(((id, state, ttl)) => (id->Spec.Id.makeFromString, state, ttl))),
      count: (id, fieldName, inc) => count(id->Spec.Id.makeFromString, fieldName, inc),
      delete: (id, subId) => delete(id->Spec.Id.makeFromString, subId),
      deleteBatch: ids =>
        deleteBatch(ids->Array.map(((id, sort)) => (id->Spec.Id.makeFromString, sort))),
    }

    let sourceNames =
      Mappings.mappings
      ->Array.map((module(Mapping: Mappings.Mapping)) => Mapping.sourceName)
      ->Belt.Set.String.fromArray

    module SpecificEventCollector = EventCollector_Builder.Make(
      RuntimeEnvironment,
      EventCollectorChannel,
    )
    let eventCollector =
      queryDb
      ->Component.operations
      ->Pulumi.Output.apply(operations => {
        let eventTopics = allEventTopics->EventTopic.filter(sourceNames)
        let eventCollector = SpecificEventCollector.make(~name, ~eventTopics, ~opts)

        module Callback = ReadModel_Callback.Make(
          Spec,
          Mappings,
          {
            module ReadModelSpec = Spec
            let operations = operations->toProjectionOperations
          },
        )
        let handler = SpecificEventCollector.makeHandler(
          ~eventCollector,
          ~jsonEventsHandler=Callback.handleJsonEvents,
        )
        let resources = (queryDb->Component.outputs).resources

        eventCollector->EventCollectorRuntimeBuilder.forEventCollector(
          ~handler,
          ~eventTopics,
          ~resources,
        )

        eventCollector
      })

    self->Component.setOperations(
      eventCollector
      ->Pulumi.Output.flatMap(eventCollector => eventCollector->Component.operations)
      ->Pulumi.Output.apply(({enqueueEvent}) => enqueueEvent),
    )
    let rmOutputs: ReadModel.outputs = {
      name,
      queryDb: queryDb->Component.outputs,
      eventCollector: eventCollector->Component.wrappedOutputs,
      sourceNames: sourceNames->Belt.Set.String.toArray,
    }
    self->Component.setOutputs(rmOutputs)
  }

  let make = (
    ~api: QueryDbStorage.api,
    ~apiRole: QueryDbStorage.role,
    ~allEventTopics,
    ~opts=?,
  ): ReadModel.component =>
    Component.make(
      ~componentType=ReadModel.componentType->ComponentType.toString,
      ~name=Spec.name,
      ~construct=construct(~api, ~apiRole, ~allEventTopics, ...),
      ~opts,
    )

  let outputs = Component.outputs
  let operations = Component.operations
  let finish = () => EventCollectorRuntimeBuilder.finish()
}
