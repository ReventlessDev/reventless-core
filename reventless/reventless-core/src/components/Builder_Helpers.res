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
  opts,
) =>
  aggregates
  ->Array.map((module(SpecificAggregate: ReventlessInfra.Aggregate.T with type api = a)) => {
    let aggregate = SpecificAggregate.make(~api, ~opts)
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
    aggregateFinishFns->Dict.set(SpecificAggregate.Spec.name, SpecificAggregate.finish)
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
  let eventMapperOutputs =
    allOutputs
    ->Array.map(aggregateOutputs => aggregateOutputs.eventMapper)
    ->Array.keepSome

  let _ =
    (eventMapperOutputs->Pulumi.Output.all, allCommandTopicOutputs->Pulumi.Output.all)
    ->Pulumi.Output.all2
    ->Pulumi.Output.apply(((eventMapperOutputs, _)) =>
      eventMapperOutputs
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
  allEventTopics,
  opts,
) => {
  let readModels = readModels->Array.map((module(SpecificReadModel: ReventlessInfra.ReadModel.T with type api = a and type role = r)) => {
    let readModel = SpecificReadModel.make(~api, ~apiRole, ~allEventTopics, ~opts)
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

    (SpecificReadModel.Spec.name, {outputs: rmOutputs, operations: rmOperations, finish: SpecificReadModel.finish})
  })
  readModels->finishReadModels
  readModels->extractReadModelsOutputs
}

let createExtensionPoints = (
  extensionPoints,
  ~aggregateResources,
  ~publishToAggregates,
  ~scheduler,
  ~queryEngine,
  ~resourceNaming,
  ~opts,
) =>
  extensionPoints
  ->Array.map((module(SpecificExtensionPoint: ReventlessInfra.ExtensionPoint.T)) => {
    let extensionPoint = SpecificExtensionPoint.make(
      ~aggregateResources,
      ~publishToAggregates,
      ~scheduler,
      ~queryEngine,
      ~resourceNaming,
      ~opts=Some(opts),
    )
    // operations() returns abstract type from ReventlessInfra.ExtensionPoint.T;
    // coerce to the concrete ExtensionPoint.operations (always identical at runtime).
    let ops: Pulumi.Output.t<ExtensionPoint.operations> =
      SpecificExtensionPoint.operations(extensionPoint)->Obj.magic
    (
      SpecificExtensionPoint.outputs(extensionPoint),
      ops->Pulumi.Output.apply(({outgoingJsonEventsHandler}) => outgoingJsonEventsHandler),
    )
  })
  ->Array.unzip

let createResolvers = allQueryDbs =>
  allQueryDbs
  ->QueryDb.allResolversMakers
  ->Array.map(resolverMaker => resolverMaker(allQueryDbs))
  ->Array.flat
