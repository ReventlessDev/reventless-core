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

  // Bare event-variant names consumed across every mapping's source event schema — the
  // union the reflected graph turns into Event→ReadModel "projects" edges (see
  // Plugin_Structure / DomainGraph). A DCB-log-sourced mapping declares a narrow event type
  // (e.g. just `OrderPlaced`), so this captures cross-source events `sourceNames` can't name.
  let consumedEventNames =
    Mappings.mappings
    ->Array.flatMap((module(Mapping: Mappings.Mapping)) =>
      Reventless.DcbTag.extractVariantNames(Mapping.sourceEventSchema->S.castToUnknown)
    )
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
    ~runtime,
    self,
    name,
  ) => {
    let opts = {Pulumi.ComponentResource.parent: self->Component.toPulumiResource}
    let name = name->ComponentType.name(ReadModel.componentType)
    // Per-component runtime hint raises the event-collector memory floor and
    // overrides the timeout; absent hint keeps the builder defaults.
    let memorySize = ReventlessInfra.RuntimeHints.resolveMemory(runtime, ~default=1024)
    let timeout = ReventlessInfra.RuntimeHints.resolveTimeout(runtime, ~default=30)

    module SpecificQueryDb = QueryDb_Builder.Make(Spec, QueryDbStorage, QueryDbResolvers)
    let queryDb = SpecificQueryDb.make(
      ~api,
      ~apiRole,
      ~owner={kind: ComponentType.ReadModel, name: Spec.name},
      ~opts,
    )

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

    // Fail-fast: every Mapping.sourceName must resolve to a topic in allEventTopics,
    // otherwise EventTopic.filter silently drops it and the projection runs on no events.
    // Catches both Aggregate-name typos and DCB-source-name typos (e.g. "FooDcb" instead
    // of "FooDcbEventLog"). See Plan 03 / Phase 2.
    sourceNames
    ->Belt.Set.String.toArray
    ->Array.forEach(sourceName =>
      if !(allEventTopics->Dict.has(sourceName)) {
        let availableNames =
          allEventTopics->Dict.keysToArray->Array.toSorted(String.compare)->Array.join(", ")
        JsError.throwWithMessage(
          `ReadModel "${Spec.name}" has a Mapping with sourceName "${sourceName}", ` ++
          `but no EventTopic with that key exists in allEventTopics. ` ++
          `Available source names: [${availableNames}]. ` ++
          `Check Mapping.Make's first arg matches an Aggregate Spec.name or a DCB ` ++
          `source name (typically "<pluginName>DcbEventLog").`,
        )
      }
    )

    module SpecificEventCollector = EventCollector_Builder.Make(
      RuntimeEnvironment,
      EventCollectorChannel,
    )
    let eventCollector =
      queryDb
      ->Component.operations
      ->Pulumi.Output.apply(operations => {
        let eventTopics = allEventTopics->EventTopic.filter(sourceNames)
        let eventCollector = SpecificEventCollector.make(
          ~name,
          ~eventTopics,
          ~owner={kind: ComponentType.ReadModel, name: Spec.name},
          ~opts,
        )

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
          ~memorySize,
          ~timeout,
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
    ~runtime=?,
    ~opts=?,
  ): ReadModel.component =>
    Component.make(
      ~componentType=ReadModel.componentType->ComponentType.toString,
      ~name=Spec.name,
      ~construct=construct(~api, ~apiRole, ~allEventTopics, ~runtime, ...),
      ~opts,
    )

  let outputs = Component.outputs
  let operations = Component.operations
  let finish = () => EventCollectorRuntimeBuilder.finish()
}
