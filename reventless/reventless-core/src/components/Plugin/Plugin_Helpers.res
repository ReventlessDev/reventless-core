// Local-only intermediate type used by Plugin_Builder during construction.
// All fields use Pulumi.Output.t-wrapped component output types because they
// originate from freshly-built local components (not deserialized stack exports).
// Cross-stack consumers use ReventlessInterop.Plugin.resolvedOutputs instead.
type builderOutputs = {
  id: string,
  version: string,
  heartbeatInterval: int,
  eventCollector: EventCollector.outputs,
  extensionPoints: dict<ExtensionPoint.outputs>,
  extensions: dict<Extension.outputs>,
  aggregates: dict<Aggregate.outputs>,
  stateChangeSlices: dict<StateChangeSlice.outputs>,
  stateViewSlices: dict<StateViewSlice.outputs>,
  readModels: dict<ReadModel.outputs>,
  tasks: dict<Task.outputs>,
  resolvers: array<ReventlessInfra.Adapter.resource>,
  heartbeat: Heartbeat.outputs,
  dcbEventLog: option<DcbEventLog.outputs>,
}

let getRemoteStorageResources = (pluginName, queryDbName) =>
  switch Util_StackRefs.get(pluginName)->Option.map(stackRef => {
    // Read both _interopMeta (for field-manifest validation) and "plugin" (the export).
    // Both are annotated as option<JSON.t> so Pulumi's untyped output unifies with sury's JSON.t.
    let metaOutput: Pulumi.Output.t<option<JSON.t>> =
      stackRef->Pulumi.StackReference.getOutput("_interopMeta")
    let pluginOutput: Pulumi.Output.t<option<JSON.t>> =
      stackRef->Pulumi.StackReference.getOutput("plugin")

    metaOutput->Pulumi.Output.flatMap(metaOpt =>
      pluginOutput->Pulumi.Output.apply(pluginOpt =>
        switch (metaOpt, pluginOpt) {
        | (Some(rawMeta), Some(rawPlugin)) =>
          switch ReventlessInterop.Query.parseMeta(rawMeta) {
          | Ok(meta) =>
            switch ReventlessInterop.Compat.validateAndProject(
              ~stackName=pluginName,
              ~meta,
              ~outputName="plugin",
              ~rawJson=rawPlugin,
              ~requiredFields=["readModels"],
              ~fromJson=json =>
                try Ok(json->S.parseOrThrow(ReventlessInterop.Plugin.resolvedOutputsSchema))
                catch {
                | exn =>
                  let msg =
                    exn
                    ->JsExn.fromException
                    ->Option.flatMap(JsExn.message)
                    ->Option.getOr("parse error")
                  Error(msg)
                },
            ) {
            | Ok(plugin) =>
              plugin.readModels
              ->Option.flatMap(readModels => readModels->Dict.get(queryDbName))
              ->Option.map(readModel =>
                readModel.queryDb.resources->Adapter.fromInteropResources
              )
              ->Option.getOr([])
            | Error(err) =>
              Console.log2(
                `Plugin_Builder.getRemoteStorageResources: compat error for ${pluginName}:`,
                err,
              )
              []
            }
          | Error(msg) =>
            Console.log2(
              `Plugin_Builder.getRemoteStorageResources: failed to parse _interopMeta for ${pluginName}:`,
              msg,
            )
            []
          }
        | _ => []
        }
      )
    )
  }) {
  | Some(resources) => resources
  | None =>
    Console.log(`Plugin_Builder.getRemoteStorageResources: Couldn't find Plugin ${pluginName}`)
    []->Pulumi.Output.make
  }

let getStorageResources = (allQueryDbs, pluginName, queryDbName) =>
  switch pluginName {
  | None => Util_QueryDb.getLocalStorageResources(allQueryDbs, queryDbName)->Pulumi.Output.make
  | Some(pluginName) => getRemoteStorageResources(pluginName, queryDbName)
  }

type jsonEventsHandler = Plugin_Callback.jsonEventsHandler
type jsonEventsHandlers = {
  outgoing?: jsonEventsHandler,
  incoming?: jsonEventsHandler,
}
let getIncomingJsonEventsHandler = jsonEventsHandlers => jsonEventsHandlers.incoming
let getOutgoingJsonEventsHandler = jsonEventsHandlers => jsonEventsHandlers.outgoing

let serviceNameToJsonEventsHandlers: (
  array<'o>,
  'o => array<string>,
  array<jsonEventsHandlers>,
  jsonEventsHandlers => option<jsonEventsHandler>,
) => dict<array<jsonEventsHandler>> = (outputs, getServiceNames, handlers, getEventHandler) => {
  let dict = Dict.make()
  Belt.Array.zip(outputs, handlers)->Array.forEach(((outputs, jsonEventsHandlers)) => {
    jsonEventsHandlers
    ->getEventHandler
    ->Option.forEach(jsonEventsHandler =>
      outputs
      ->getServiceNames
      ->Array.forEach(
        serviceName =>
          switch dict->Dict.get(serviceName) {
          | Some(jsonEventsHandlers) =>
            Dict.set(dict, serviceName, jsonEventsHandlers->Array.concat([jsonEventsHandler]))
          | None => Dict.set(dict, serviceName, [jsonEventsHandler])
          },
      )
    )
  })
  dict
}

// Captured read model data — stores extracted values instead of module+component
// so that Plugin_Helpers can work with abstract spec-level component types.
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
  let (eventMapperOutputs, commandTopicOutputs) =
    aggregatesOutputs
    ->Dict.valuesToArray
    ->Array.map(aggregateOutputs =>
      aggregateOutputs.eventMapper->Option.map(eventMapper => (
        eventMapper,
        aggregateOutputs.commandTopic,
      ))
    )
    ->Array.keepSome
    ->Belt.Array.unzip
  let _ =
    (eventMapperOutputs->Pulumi.Output.all, commandTopicOutputs->Pulumi.Output.all)
    ->Pulumi.Output.all2
    ->Pulumi.Output.apply(((eventMapperOutputs, _)) =>
      eventMapperOutputs
      ->Array.map(eventMapperOutput => eventMapperOutput.eventCollector)
      ->Pulumi.Output.all
      ->Pulumi.Output.apply(_ =>
        aggregateFinishFns->Dict.valuesToArray->Array.forEach(finishFn => {
          Console.log("Plugin_Builder: AggregateRuntimeBuilder.finish")
          finishFn()
        })
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
    // Obj.magic is safe here: all ReventlessInfra.ExtensionPoint.T implementations in reventless
    // return ExtensionPoint.component<ExtensionPoint.operations> at runtime.
    let concreteEP: ExtensionPoint.component<ExtensionPoint.operations> = Obj.magic(extensionPoint)
    (
      SpecificExtensionPoint.outputs(extensionPoint),
      concreteEP
      ->Component.operations
      ->Pulumi.Output.apply(({outgoingJsonEventsHandler}) => outgoingJsonEventsHandler),
    )
  })
  ->Belt.Array.unzip

let createExtensions = (
  extensions,
  ~publishToCorePluginExtensionPoint,
  ~publishToAggregates,
  ~publishToReadModels,
  ~queryEngine,
  ~opts,
) =>
  extensions
  ->Array.map((module(SpecificExtension: ReventlessInfra.Extension.T)) => {
    let extension = SpecificExtension.make(
      ~publishToCorePluginExtensionPoint,
      ~publishToAggregates,
      ~readModelNamesForSourceName,
      ~publishToReadModels,
      ~queryEngine,
      ~opts=Some(opts),
    )
    // Obj.magic is safe here: all ReventlessInfra.Extension.T implementations in reventless
    // return Extension.component at runtime.
    let concreteExt: Extension.component = Obj.magic(extension)
    (
      SpecificExtension.outputs(extension),
      concreteExt
      ->Component.operations
      ->Pulumi.Output.apply(({outgoingJsonEventsHandler, incomingJsonEventsHandler}) => {
        incoming: incomingJsonEventsHandler,
        outgoing: outgoingJsonEventsHandler,
      }),
    )
  })
  ->Belt.Array.unzip

let extractExtensionPointDefinitions = (extensionPointsOutputs: array<ExtensionPoint.outputs>) =>
  extensionPointsOutputs
  ->Array.map(extensionPointOutputs =>
    (
      extensionPointOutputs.commandTopic->Pulumi.Output.flatMap(({resources}) =>
        (resources->Array.getUnsafe(0)).id
      ), // FIXME
      extensionPointOutputs.eventTopic->Pulumi.Output.flatMap(({resources}) =>
        (resources->Array.getUnsafe(0)).id
      ), // FIXME
    )
    ->Pulumi.Output.all2
    ->Pulumi.Output.apply(((commandTopicChannelId, eventTopicPublisherId)) => {
      Reventless.Plugin.name: extensionPointOutputs.name,
      commandTopic: commandTopicChannelId,
      eventTopic: eventTopicPublisherId,
    })
  )
  ->Pulumi.Output.all

let extractExtensionDefinitions = (extensionsOutputs: array<Extension.outputs>) =>
  extensionsOutputs->Array.map(extensionOutputs => {
    Reventless.Plugin.name: extensionOutputs.name,
    extensionPointName: extensionOutputs.extensionPointName,
  })

let createConnectPluginExtension = (
  ~pluginDefinition,
  ~extensionPointsOutputs,
  ~extensionsOutputs,
  ~publishToCorePluginExtensionPoint,
  ~publishToAggregates,
  ~readModelNamesForSourceName,
  ~publishToReadModels,
  ~queryEngine,
  ~runtimeOps,
  ~resourceNaming,
  ~opts,
) =>
  (
    extensionPointsOutputs
    ->Array.map(ExtensionPoint.toResolvedOutputs)
    ->Pulumi.Output.all,
    pluginDefinition,
  )
  ->Pulumi.Output.all2
  ->Pulumi.Output.apply(((extensionPointsOutputs, pluginDefinition)) => {
    module ConnectPluginExtension = PluginConnectExtension_Builder.Make({
      let pluginDefinition = pluginDefinition
      let extensionPointsOutputs = extensionPointsOutputs
      let extensionsOutputs = extensionsOutputs
      let runtimeOps = runtimeOps
      let resourceNaming = resourceNaming
    })
    let connectPluginExtension = ConnectPluginExtension.make(
      ~publishToCorePluginExtensionPoint,
      ~publishToAggregates,
      ~readModelNamesForSourceName,
      ~publishToReadModels,
      ~queryEngine,
      ~opts=Some(opts),
    )
    let connectPluginExtensionOutputs = connectPluginExtension->Component.outputs
    let connectPluginExtensionIncomingEventHandler =
      connectPluginExtension
      ->Component.operations
      ->Pulumi.Output.apply(({incomingJsonEventsHandler}) => incomingJsonEventsHandler)

    (connectPluginExtensionOutputs, connectPluginExtensionIncomingEventHandler)
  })
  ->Pulumi.Output.unzip

let tasksOutputs = ref([])

let createTasks = (
  tasks,
  ~aggregatesOutputs,
  ~scheduler,
  ~publishToAggregates,
  ~queryEngine,
  ~resourceNaming,
  ~opts,
) => {
  tasksOutputs :=
    tasks->Array.map((module(SpecificTask: ReventlessInfra.Task.T)) =>
      SpecificTask.outputs(SpecificTask.make(
        ~queryBucketName=(~taskName, ~bucketName="Bucket") =>
          ResourceQueryRuntime.bucketNameOfTaskExn(tasksOutputs.contents, ~taskName, ~bucketName),
        ~scheduler,
        ~publishToAggregates,
        ~queryEngine,
        ~resourceNaming,
        ~allAggregates=aggregatesOutputs,
        ~opts=Some(opts),
      ))
    )
  tasksOutputs.contents
}

let createResolvers = allQueryDbs =>
  allQueryDbs
  ->QueryDb.allResolversMakers
  ->Array.map(resolverMaker => resolverMaker(allQueryDbs))
  ->Array.flat

module MakeEventCollectorHelper = (
  RuntimeEnvironment: Runtime.Environment,
  EventCollectorChannel: EventCollector_Adapter.Channel
    with type runtimeParts = RuntimeEnvironment.parts,
  PluginRuntimeBuilder: PluginRuntime_Builder.T
    with module EventCollectorChannel = EventCollectorChannel,
) => {
  module PluginEventCollector = EventCollector_Builder.Make(
    RuntimeEnvironment,
    EventCollectorChannel,
  )
  let make = (~name, ~eventTopics, ~opts) => {
    let eventCollector = PluginEventCollector.make(~name, ~eventTopics, ~opts)
    let eventCollectorOutputs = eventCollector->Component.outputs
    let eventCollectorUrn = (eventCollectorOutputs.resources->Array.getUnsafe(0)).urn //FIXME

    (eventCollector, eventCollectorOutputs, eventCollectorUrn)
  }

  let connect = (
    ~eventCollector: EventCollector.component,
    ~eventTopics: EventTopic.allOutputs,
    ~extensionPointsOutputs: array<ExtensionPoint.outputs>,
    ~extensionsOutputs: array<Extension.outputs>,
    ~corePluginExtensionPointUnwrapped: ReventlessInterop.ExtensionPoint.resolvedOutputs,
    ~pluginDefinition,
    ~connectPluginExtensionIncomingEventHandler,
    ~extensionsHandlers,
    ~extensionPointsHandlers,
    ~connectPluginExtensionOutputs: Pulumi.Output.t<Extension.outputs>,
  ) => {
    let resources =
      extensionPointsOutputs
      ->Array.map(extensionPoint => extensionPoint.eventTopic)
      ->Pulumi.Output.all
      ->Pulumi.Output.apply(eventTopics =>
        eventTopics
        ->Array.map(eventTopic => eventTopic.resources)
        ->Array.flat
        ->Array.concat(
          corePluginExtensionPointUnwrapped.commandTopic.resources->Adapter.fromInteropResources,
        )
      )

    (
      pluginDefinition,
      connectPluginExtensionIncomingEventHandler->Pulumi.Output.unwrap,
      extensionsHandlers->Pulumi.Output.all,
      extensionPointsHandlers->Pulumi.Output.all,
      connectPluginExtensionOutputs,
      resources,
    )
    ->Pulumi.Output.all6
    ->Pulumi.Output.apply(((
      pluginDefinition,
      connectPluginExtensionIncomingEventHandler,
      extensionsHandlers,
      extensionPointsHandlers,
      connectPluginExtensionOutputs,
      resources,
    )) => {
      module Callback = Plugin_Callback.Make({
        let pluginDefinition = pluginDefinition
        let outgoingExtensionPointEventHandlers = serviceNameToJsonEventsHandlers(
          extensionPointsOutputs,
          outputs => outputs.aggregateNames,
          extensionPointsHandlers->Array.map(extensionPointsHandler => {
            outgoing: extensionPointsHandler,
          }),
          getOutgoingJsonEventsHandler,
        )
        let incomingConnectExtensionEventHandlers = serviceNameToJsonEventsHandlers(
          [connectPluginExtensionOutputs],
          outputs => [outputs.extensionPointName],
          [{incoming: connectPluginExtensionIncomingEventHandler}],
          getIncomingJsonEventsHandler,
        )
        let outgoingExtensionEventHandlers = serviceNameToJsonEventsHandlers(
          extensionsOutputs,
          outputs => outputs.aggregateNames,
          extensionsHandlers,
          getOutgoingJsonEventsHandler,
        )
        let incomingExtensionEventHandlers = serviceNameToJsonEventsHandlers(
          extensionsOutputs,
          outputs => [outputs.extensionPointName],
          extensionsHandlers,
          getIncomingJsonEventsHandler,
        )
      })
      let handler = PluginEventCollector.makeHandler(
        ~eventCollector,
        ~jsonEventsHandler=Callback.handleJsonEvents,
      )
      eventCollector->PluginRuntimeBuilder.forPluginEventCollector(
        ~handler,
        ~eventTopics,
        ~resources,
      )

      let _ =
        (
          (eventCollector->Component.outputs).resources->Array.getUnsafe(0)
        ).urn->Pulumi.Output.apply(urn => pluginDefinition.eventCollector = urn)
    })
  }

  // Simplified connect for platforms without a Core stack reference (e.g. in-memory).
  // Skips ConnectPluginExtension wiring and Core PluginExtensionPoint resources.
  let connectWithoutCore = (
    ~eventCollector: EventCollector.component,
    ~eventTopics: EventTopic.allOutputs,
    ~extensionPointsOutputs: array<ExtensionPoint.outputs>,
    ~extensionsOutputs: array<Extension.outputs>,
    ~pluginDefinition,
    ~extensionsHandlers,
    ~extensionPointsHandlers,
  ) => {
    let resources =
      extensionPointsOutputs
      ->Array.map(extensionPoint => extensionPoint.eventTopic)
      ->Pulumi.Output.all
      ->Pulumi.Output.apply(eventTopics =>
        eventTopics
        ->Array.map(eventTopic => eventTopic.resources)
        ->Array.flat
      )

    (
      pluginDefinition,
      extensionsHandlers->Pulumi.Output.all,
      extensionPointsHandlers->Pulumi.Output.all,
      resources,
    )
    ->Pulumi.Output.all4
    ->Pulumi.Output.apply(((
      pluginDefinition,
      extensionsHandlers,
      extensionPointsHandlers,
      resources,
    )) => {
      module Callback = Plugin_Callback.Make({
        let pluginDefinition = pluginDefinition
        let outgoingExtensionPointEventHandlers = serviceNameToJsonEventsHandlers(
          extensionPointsOutputs,
          outputs => outputs.aggregateNames,
          extensionPointsHandlers->Array.map(extensionPointsHandler => {
            outgoing: extensionPointsHandler,
          }),
          getOutgoingJsonEventsHandler,
        )
        let incomingConnectExtensionEventHandlers = Dict.make()
        let outgoingExtensionEventHandlers = serviceNameToJsonEventsHandlers(
          extensionsOutputs,
          outputs => outputs.aggregateNames,
          extensionsHandlers,
          getOutgoingJsonEventsHandler,
        )
        let incomingExtensionEventHandlers = serviceNameToJsonEventsHandlers(
          extensionsOutputs,
          outputs => [outputs.extensionPointName],
          extensionsHandlers,
          getIncomingJsonEventsHandler,
        )
      })
      let handler = PluginEventCollector.makeHandler(
        ~eventCollector,
        ~jsonEventsHandler=Callback.handleJsonEvents,
      )
      eventCollector->PluginRuntimeBuilder.forPluginEventCollector(
        ~handler,
        ~eventTopics,
        ~resources,
      )

      let _ =
        (
          (eventCollector->Component.outputs).resources->Array.getUnsafe(0)
        ).urn->Pulumi.Output.apply(urn => pluginDefinition.eventCollector = urn)
    })
  }
}

// ---------------------------------------------------------------------------
// Interop metadata — computed from builderOutputs at deploy time and stored so
// that the plugin's entry-point module can export it as `_interopMeta`.
// ---------------------------------------------------------------------------

// Module-level ref; follows the same mutable-state pattern as `tasksOutputs`
// above.  Set by Plugin_Builder during construct(); read by user entry-point
// code via `getInteropMeta()`.
let interopMetaOutput: ref<option<Pulumi.Output.t<ReventlessInterop.ExportMeta.t>>> = ref(None)

// Derive a field-name union across all tasks (field names present in at least
// one task's serialized resolvedOutputs).  Optional fields only appear in the
// union when they are Some in the source Task.outputs record.
let taskFieldUnion = (tasks: dict<Task.outputs>): array<string> => {
  module SSet = Belt.Set.String
  tasks
  ->Dict.valuesToArray
  ->Array.reduce(SSet.empty, (acc, taskOutput) => {
    // Convert Task.outputs → Task.resolvedOutputs using placeholders for nested
    // Pulumi.Output.t values — we only need presence, not actual string content.
    // ReScript optional fields must be set to the inner type (not option<_>) in
    // record literals, so we use a switch to conditionally include them.
    let resolved: ReventlessInterop.Task.resolvedOutputs =
      switch (taskOutput.bucketNames, taskOutput.sideEffectSources) {
      | (None, None) => {name: taskOutput.name}
      | (Some(_), None) => {name: taskOutput.name, bucketNames: Dict.make()}
      | (None, Some(src)) => {name: taskOutput.name, sideEffectSources: src}
      | (Some(_), Some(src)) => {
          name: taskOutput.name,
          bucketNames: Dict.make(),
          sideEffectSources: src,
        }
      }
    ReventlessInterop.ExportMeta.fieldNamesOf(resolved, ReventlessInterop.Task.resolvedOutputsSchema)
    ->Array.reduce(acc, SSet.add)
  })
  ->SSet.toArray
}

// Build an ExportMeta.t from builderOutputs.  Called inside a Pulumi.Output.apply
// so all top-level Output.t wrappers in builderOutputs are already resolved.
// Nested Output.t values (e.g. inside Task.bucketNames dict values) are still
// pending — we use placeholder detection (Some vs None) rather than unwrapping.
let toInteropMeta = (outputs: builderOutputs): ReventlessInterop.ExportMeta.t => {
  // Include optional fields only when the corresponding dict is non-empty,
  // so old publishers with empty dicts produce a conservative manifest.
  // ReScript optional fields cannot be set via option<_> in record literals.
  let hasReadModels = outputs.readModels->Dict.toArray->Array.length > 0
  let hasExtensionPoints = outputs.extensionPoints->Dict.toArray->Array.length > 0
  let pluginResolved: ReventlessInterop.Plugin.resolvedOutputs =
    switch (hasReadModels, hasExtensionPoints) {
    | (false, false) => {id: outputs.id, version: outputs.version}
    | (true, false) => {id: outputs.id, version: outputs.version, readModels: Dict.make()}
    | (false, true) => {id: outputs.id, version: outputs.version, extensionPoints: Dict.make()}
    | (true, true) => {
        id: outputs.id,
        version: outputs.version,
        readModels: Dict.make(),
        extensionPoints: Dict.make(),
      }
    }

  // EventMapper field manifest uses minimum required fields (counter presence
  // cannot be checked without resolving inner Output.t — improved in later phase).
  let eventMapperMinimal: ReventlessInterop.EventMapper.resolvedOutputs = {
    name: "",
    eventCollector: {name: "", resources: []},
  }

  {
    version: ReventlessInterop.ExportMeta.version,
    fields: Dict.fromArray([
      ("tasks", taskFieldUnion(outputs.tasks)),
      (
        "eventMappers",
        ReventlessInterop.ExportMeta.fieldNamesOf(
          eventMapperMinimal,
          ReventlessInterop.EventMapper.resolvedOutputsSchema,
        ),
      ),
      (
        "plugin",
        ReventlessInterop.ExportMeta.fieldNamesOf(
          pluginResolved,
          ReventlessInterop.Plugin.resolvedOutputsSchema,
        ),
      ),
    ]),
  }
}

// Returns the computed interop meta Output.  Call this from the plugin's entry-
// point module and export the result as `let _interopMeta = getInteropMeta()`.
let getInteropMeta = () =>
  interopMetaOutput.contents->Option.getOrThrow(
    ~message="getInteropMeta() called before Plugin_Builder.construct()",
  )
