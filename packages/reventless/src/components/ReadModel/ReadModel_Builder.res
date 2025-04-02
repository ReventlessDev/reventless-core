module Make = (
  Config: Config.T,
  Spec: ReventlessSpec.ReadModel_Spec.T,
  Mappings: ReventlessSpec.Projection.Mappings with module Target := Spec,
  RuntimeBuilder: Runtime_Builder.T,
  QueryDbStorage: QueryDb_Adapter.Storage with type api = Config.api and type role = Config.role,
  QueryDbResolvers: QueryDb_Adapter.Resolvers
    with type api = Config.api
    and type role = Config.role,
  EventCollectorChannel: EventCollector_Adapter.Channel
    with type runtimeParts = RuntimeBuilder.parts,
): (ReadModel.T with module Spec = Spec) => {
  module Spec = Spec

  type projectionOperations = QueryDb.operations<string, Spec.state> // TODO: should we really use this "mixed" type?

  let construct = (~allEventTopics, self, name) => {
    let opts = {Pulumi.ComponentResource.parent: self->Component.toPulumiResource}
    let name = name->ComponentType.name(ReadModel.componentType)

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

    module SpecificEventCollector = EventCollector_Builder.Make(EventCollectorChannel)
    let eventCollector =
      queryDb
      ->Component.operations
      ->Pulumi.Output.apply(operations => {
        let eventCollector = SpecificEventCollector.make(~name, ~opts)
        let opts = {Pulumi.ComponentResource.parent: eventCollector->Component.toPulumiResource}

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
          ~eventsHandler=Callback.eventsHandler,
        )
        let runtime = eventCollector->RuntimeBuilder.forReadModelEventCollector(~handler)

        let eventTopics = allEventTopics->EventTopic.filter(sourceNames)
        let resources = (queryDb->Component.outputs).resources

        SpecificEventCollector.connect(
          ~name,
          ~eventTopics,
          ~eventCollector,
          ~runtime,
          ~resources,
          ~opts,
        )
        eventCollector
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
      ~opts
    )
}
