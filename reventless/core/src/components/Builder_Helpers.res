// Shared builder helpers used by both Plugin_Builder and Platform_Admin.
// Extracted from Plugin_Helpers to eliminate duplication.

// Captured read model data — stores extracted values instead of module+component
// so that Builder_Helpers can work with abstract spec-level component types.
type readModel = {
  outputs: ReadModel.outputs,
  operations: Pulumi.Output.t<ReadModel.operations>,
  finish: unit => unit,
}

let addEventMapperFns = Dict.make()
let aggregateResources = Dict.make()
let publishToAggregates = Dict.make()
// Finish functions captured from aggregate modules during createAggregatesWithoutEventMappers.
let aggregateFinishFns = Dict.make()

let createAggregatesWithoutEventMappers = (
  type a,
  aggregates: array<module(ReventlessInfra.Aggregate.T with type api = a)>,
  ~api: a,
  ~componentRuntime: dict<ReventlessInfra.RuntimeHints.t>,
  opts,
) =>
  aggregates
  ->Array.map((module(SpecificAggregate: ReventlessInfra.Aggregate.T with type api = a)) => {
    let aggregate = SpecificAggregate.make(
      ~api,
      ~runtime=?componentRuntime->Dict.get(SpecificAggregate.Spec.name),
      ~opts,
    )
    let aggOutputs = SpecificAggregate.outputs(aggregate)
    addEventMapperFns->Dict.set(
      SpecificAggregate.Spec.name,
      aggOutputs.addEventMapper,
    )
    let resources =
      aggOutputs.commandTopic->Pulumi.Output.apply(commandTopic =>
        commandTopic.resources
      )
    aggregateResources->Dict.set(SpecificAggregate.Spec.name, resources)
    let publishJsons =
      SpecificAggregate.operations(aggregate)->Pulumi.Output.apply(({publishJsons}) => publishJsons)
    publishToAggregates->Dict.set(SpecificAggregate.Spec.name, publishJsons)
    // `finish` runs from an apply in `finishAggregates`, long after this
    // construct returns — wrap it now, while the plugin is still the ambient
    // one, so whatever it provisions is attributed to that plugin.
    aggregateFinishFns->Dict.set(
      SpecificAggregate.Spec.name,
      ResourceAttribution.deferred(SpecificAggregate.finish),
    )
    aggOutputs
  })
  ->Array.map(aggregate => {(aggregate.name, aggregate)})
  ->Dict.fromArray


let finishAggregates = (
  aggregatesOutputs: dict<Aggregate.outputs>,
) => {
  let allOutputs = aggregatesOutputs->Dict.valuesToArray

  // Wait for ALL commandTopicOutputs (not just those with event mappers)
  // to ensure forCommandTopic has registered specs before finish() runs.
  let allCommandTopicOutputs =
    allOutputs->Array.map(aggregateOutputs => aggregateOutputs.commandTopic)
  let eventMapperOutputs = allOutputs->Array.map(aggregateOutputs => aggregateOutputs.eventMapper)

  let _ =
    (eventMapperOutputs->Pulumi.Output.all, allCommandTopicOutputs->Pulumi.Output.all)
    ->Pulumi.Output.all2
    ->Pulumi.Output.apply(((eventMapperOutputs, _)) =>
      // Filtered after resolution, not before: the absent ones are now `None`
      // inside a resolved array rather than missing fields.
      //
      // `eventCollector` here is a plain record, not an Output: `Output.all` above
      // deeply unwrapped the contents of each element. That is fine because `all`
      // accepts resolved values, but nothing in this block may call
      // `EventMapper.toResolvedOutputs` — it expects unresolved fields and would
      // throw `m.apply is not a function`. Resolve at the depth where the record is
      // still unresolved instead, as `serializeEventMappersOutputs` does.
      eventMapperOutputs
      ->Array.keepSome
      ->Array.map(eventMapperOutput => eventMapperOutput.eventCollector)
      ->Pulumi.Output.all
      ->Pulumi.Output.apply(_ =>
        aggregateFinishFns->Dict.valuesToArray->Array.forEach(finishFn => finishFn())
      )
    )
}

let addEventMappers = (
  allEventTopics,
  queryEngine,
) => {
  let aggregatesOutputs =
    addEventMapperFns->Dict.mapValues(addEventMapperFn =>
      addEventMapperFn(allEventTopics, queryEngine)
    )
  finishAggregates(aggregatesOutputs)

  aggregatesOutputs
}

// Side-effect handlers registered by Task_Builder, with the Output that tells us the
// handler has reached its runtime builder. Registration happens inside an
// `allCommandTopics` apply, so `make` returning is not enough — a synchronous
// `finish()` would build the shared runtime before any handler had registered, or
// worse, from only the first one.
let taskSideEffectGates: array<Pulumi.Output.t<unit>> = []
let taskSideEffectFinishFns: array<unit => unit> = []

let registerTaskSideEffectHandler = (~gate, ~finish) => {
  let _ = taskSideEffectGates->Array.push(gate)
  // These arrays are module-level and shared by every plugin, so the context has
  // to travel with each entry: by the time `finishTasks` runs them there is no
  // one plugin that would be right for all of them.
  let _ = taskSideEffectFinishFns->Array.push(ResourceAttribution.deferred(finish))
}

// Provision side-effect handler runtimes once every task's handler is ready. Same
// shape as `finishAggregates`: collect the gates, wait on all of them, then run the
// finish functions. Adapters guard against repeat calls.
let finishTasks = () =>
  if taskSideEffectGates->Array.length > 0 {
    let _ =
      taskSideEffectGates
      ->Pulumi.Output.all
      ->Pulumi.Output.apply(_ =>
        taskSideEffectFinishFns->Array.forEach(finishFn => finishFn())
      )
  }

let readModelNamesForSourceName = Dict.make()
let publishToReadModels = Dict.make()

let finishReadModels = readModels => {
  let _ =
    readModels
    ->Array.map(((_, {operations})) => operations)
    ->Pulumi.Output.all
    ->Pulumi.Output.apply(_ =>
      readModels->Array.forEach(((_, {finish})) => {
        finish()
      })
    )
}

let extractReadModelsOutputs = readModels =>
  readModels
  ->Dict.fromArray
  ->Dict.toArray
  ->Array.map(((name, {outputs})) => (name, outputs))
  ->Dict.fromArray

let createReadModels = (
  type a,
  type r,
  readModels: array<module(ReventlessInfra.ReadModel.T with type api = a and type role = r)>,
  ~api: a,
  ~apiRole: r,
  ~componentRuntime: dict<ReventlessInfra.RuntimeHints.t>,
  allEventTopics,
  opts,
) => {
  let readModels = readModels->Array.map((module(SpecificReadModel: ReventlessInfra.ReadModel.T with type api = a and type role = r)) => {
    let readModel = SpecificReadModel.make(
      ~api,
      ~apiRole,
      ~allEventTopics,
      ~runtime=?componentRuntime->Dict.get(SpecificReadModel.Spec.name),
      ~opts,
    )
    let rmOutputs = SpecificReadModel.outputs(readModel)
    let rmOperations = SpecificReadModel.operations(readModel)
    rmOutputs.sourceNames->Array.forEach(sourceName =>
      switch readModelNamesForSourceName->Dict.get(sourceName) {
      | Some(readModelNames) =>
        readModelNamesForSourceName->Dict.set(
          sourceName,
          readModelNames->Array.concat([SpecificReadModel.Spec.name]),
        )
      | None => Dict.set(readModelNamesForSourceName, sourceName, [SpecificReadModel.Spec.name])
      }
    )
    publishToReadModels->Dict.set(
      SpecificReadModel.Spec.name,
      rmOperations->Pulumi.Output.apply(({enqueueEvent}) => enqueueEvent),
    )

    // Deferred to `finishReadModels`, which runs it from an apply — wrap it here
    // so the read model's runtime is attributed to the plugin building it.
    (
      SpecificReadModel.Spec.name,
      {
        outputs: rmOutputs,
        operations: rmOperations,
        finish: ResourceAttribution.deferred(SpecificReadModel.finish),
      },
    )
  })
  readModels->finishReadModels
  readModels->extractReadModelsOutputs
}

// Per-extension-point registry data the EventCollector entry point needs at
// runtime to publish outgoing events. Lives next to the existing
// `extensionPointsOutputs` / `extensionPointsHandlers` arrays — same indexing.
type extensionPointRegistryInfo = {
  specModule: string,
  mappingsModule: string,
}

let createExtensionPoints = (
  extensionPoints,
  ~aggregateResources,
  ~publishToAggregates,
  ~scheduler,
  ~queryEngine,
  ~resourceNaming,
  ~componentRuntime: dict<ReventlessInfra.RuntimeHints.t>,
  ~opts,
) => {
  let triples =
    extensionPoints
    ->Array.map((module(SpecificExtensionPoint: ReventlessInfra.ExtensionPoint.T)) => {
      let extensionPoint = SpecificExtensionPoint.make(
        ~aggregateResources,
        ~publishToAggregates,
        ~scheduler,
        ~queryEngine,
        ~resourceNaming,
        ~runtime=?componentRuntime->Dict.get(SpecificExtensionPoint.name),
        ~opts=Some(opts),
      )
      // operations() returns abstract type from ReventlessInfra.ExtensionPoint.T;
      // coerce to the concrete ExtensionPoint.operations (always identical at runtime).
      let ops: Pulumi.Output.t<ExtensionPoint.operations> =
        SpecificExtensionPoint.operations(extensionPoint)->Obj.magic
      let outputs = SpecificExtensionPoint.outputs(extensionPoint)
      let registryInfo: extensionPointRegistryInfo = {
        specModule: outputs.specModule,
        mappingsModule: outputs.mappingsModule,
      }
      (
        outputs,
        ops->Pulumi.Output.apply(({outgoingJsonEventsHandler}) => outgoingJsonEventsHandler),
        registryInfo,
      )
    })
  let outputs = triples->Array.map(((o, _, _)) => o)
  let handlers = triples->Array.map(((_, h, _)) => h)
  let registryInfos = triples->Array.map(((_, _, r)) => r)
  (outputs, handlers, registryInfos)
}

let createResolvers = allQueryDbs =>
  allQueryDbs
  ->QueryDb.allResolversMakers
  ->Array.map(resolverMaker => resolverMaker(allQueryDbs))
  ->Array.flat
