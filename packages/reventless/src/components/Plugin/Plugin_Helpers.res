// TODO: find better naming
type pureOutputs = {
  id: string,
  version: string,
  heartbeatInterval: int,
  eventCollector: EventCollector.outputs,
  extensionPoints: dict<ExtensionPoint.outputs>,
  extensions: dict<Extension.outputs>,
  aggregates: dict<Aggregate.outputs>,
  readModels: dict<ReadModel.outputs>,
  tasks: dict<Task.outputs>,
  resolvers: array<ReventlessSpec.Adapter.resource>,
  heartbeat: Heartbeat.outputs,
}

let getRemoteStorageResources = (pluginName, queryDbName) =>
  switch Util_StackRefs.get(pluginName)->Option.map(stackRef => {
    stackRef
    ->Pulumi.StackReference.requireOutput("plugin"->Pulumi.Input.make)
    ->Pulumi.Output.apply((plugin: pureOutputs) =>
      plugin.readModels
      ->Dict.get(queryDbName)
      ->Option.map((readModel: ReadModel.outputs) => readModel.queryDb.resources)
      ->Option.getOr([])
    )
  }) {
  | Some(resources) => resources
  | None =>
    Console.log("Plugin_Builder.getRemoteStorageResources: Couldn't find Plugin $pluginName")
    []->Pulumi.Output.make
  }

let getStorageResources = (allQueryDbs, pluginName, queryDbName) =>
  switch pluginName {
  | None => Util_QueryDb.getLocalStorageResources(allQueryDbs, queryDbName)->Pulumi.Output.make
  | Some(pluginName) => getRemoteStorageResources(pluginName, queryDbName)
  }

type eventHandler = Plugin_Callback.eventHandler
type eventHandlers = {
  outgoing?: eventHandler,
  incoming?: eventHandler,
}
let getIncomingEventHandler = eventHandlers => eventHandlers.incoming
let getOutgoingEventHandler = eventHandlers => eventHandlers.outgoing

let serviceNameToEventHandlers: (
  array<'o>,
  'o => array<string>,
  array<eventHandlers>,
  eventHandlers => option<eventHandler>,
) => dict<array<eventHandler>> = (outputs, getServiceNames, handlers, getEventHandler) => {
  let dict = Dict.make()
  Belt.Array.zip(outputs, handlers)->Array.forEach(((outputs, eventHandlers)) => {
    eventHandlers
    ->getEventHandler
    ->Option.forEach(eventHandler =>
      outputs
      ->getServiceNames
      ->Array.forEach(
        serviceName =>
          switch dict->Dict.get(serviceName) {
          | Some(eventHandlers) =>
            Dict.set(dict, serviceName, eventHandlers->Array.concat([eventHandler]))
          | None => Dict.set(dict, serviceName, [eventHandler])
          },
      )
    )
  })
  dict
}

type readModel = {
  module_: module(ReadModel.T),
  readModel: ReadModel.component,
}

let addEventMapperFns = Dict.make()
let aggregateResources = Dict.make()
let publishToAggregates = Dict.make()

let createAggregatesWithoutEventMappers = (aggregates, opts) =>
  aggregates
  ->Array.map((module(SpecificAggregate: Aggregate.T)) => {
    let aggregate = SpecificAggregate.make(~opts)
    addEventMapperFns->Dict.set(
      SpecificAggregate.Spec.name,
      (aggregate->Component.outputs).addEventMapper,
    )
    let resources =
      (aggregate->Component.outputs).commandTopic->Pulumi.Output.apply(commandTopic =>
        commandTopic.resources
      )
    aggregateResources->Dict.set(SpecificAggregate.Spec.name, resources)
    let publishJsons =
      aggregate->Component.operations->Pulumi.Output.apply(({publishJsons}) => publishJsons)
    publishToAggregates->Dict.set(SpecificAggregate.Spec.name, publishJsons)
    aggregate->Component.outputs
  })
  ->Array.map(aggregate => {(aggregate.name, aggregate)})
  ->Dict.fromArray

let finishAggregates = (aggregates, aggregatesOutputs: dict<Aggregate.outputs>) => {
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
        aggregates->Array.forEach(
          (module(SpecificAggregate: Aggregate.T)) => {
            Console.log("Plugin_Builder: AggregateRuntimeBuilder.finish")
            SpecificAggregate.AggregateRuntimeBuilder.finish()
          },
        )
      )
    )
}

let addEventMappers = (aggregates, allEventTopics, queryEngine) => {
  let aggregatesOutputs =
    addEventMapperFns->Dict.mapValues(addEventMapperFn =>
      addEventMapperFn(allEventTopics, queryEngine)
    )
  aggregates->finishAggregates(aggregatesOutputs)

  aggregatesOutputs
}

let readModelNamesForSourceName = Dict.make()
let publishToReadModels = Dict.make()

let finishReadModels = readModels => {
  let _ =
    readModels
    ->Array.map(((_, {readModel})) => readModel->Component.operations)
    ->Pulumi.Output.all
    ->Pulumi.Output.apply(_ =>
      readModels->Array.forEach(((_, {module_: module(SpecificReadModel: ReadModel.T)})) => {
        SpecificReadModel.EventCollectorRuntimeBuilder.finish()
      })
    )
}

let extractReadModelsOutputs = readModels =>
  readModels
  ->Dict.fromArray
  ->Dict.toArray
  ->Array.map(((name, {readModel})) => (name, readModel->Component.outputs))
  ->Dict.fromArray

let createReadModels = (readModels, allEventTopics, opts) => {
  let readModels = readModels->Array.map((module(SpecificReadModel: ReadModel.T)) => {
    let readModel = SpecificReadModel.make(~allEventTopics, ~opts)
    (readModel->Component.outputs).sourceNames->Array.forEach(sourceName =>
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
      readModel
      ->Component.operations
      ->Pulumi.Output.apply(({enqueueEvent}) => enqueueEvent),
    )

    (SpecificReadModel.Spec.name, {module_: module(SpecificReadModel), readModel})
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
  ~opts,
) =>
  extensionPoints
  ->Array.map((module(SpecificExtensionPoint: ExtensionPoint.T)) => {
    let extensionPoint = SpecificExtensionPoint.make(
      ~aggregateResources,
      ~publishToAggregates,
      ~scheduler,
      ~queryEngine,
      ~opts=Some(opts),
    )
    (
      extensionPoint->Component.outputs,
      extensionPoint
      ->Component.operations
      ->Pulumi.Output.apply(({outgoingEventHandler}) => outgoingEventHandler),
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
  ->Array.map((module(SpecificExtension: Extension.T)) => {
    let extension = SpecificExtension.make(
      ~publishToCorePluginExtensionPoint,
      ~publishToAggregates,
      ~readModelNamesForSourceName,
      ~publishToReadModels,
      ~queryEngine,
      ~opts=Some(opts),
    )
    (
      extension->Component.outputs,
      extension
      ->Component.operations
      ->Pulumi.Output.apply(({outgoingEventHandler, incomingEventHandler}) => {
        incoming: incomingEventHandler,
        outgoing: outgoingEventHandler,
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
      ReventlessSpec.Plugin.name: extensionPointOutputs.name,
      commandTopic: commandTopicChannelId,
      eventTopic: eventTopicPublisherId,
    })
  )
  ->Pulumi.Output.all

let extractExtensionDefinitions = (extensionsOutputs: array<Extension.outputs>) =>
  extensionsOutputs->Array.map(extensionOutputs => {
    ReventlessSpec.Plugin.name: extensionOutputs.name,
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
  ~opts,
) =>
  (
    extensionPointsOutputs
    ->Array.map(ExtensionPoint.toUnwrappedOutputs)
    ->Pulumi.Output.all,
    pluginDefinition,
  )
  ->Pulumi.Output.all2
  ->Pulumi.Output.apply(((extensionPointsOutputs, pluginDefinition)) => {
    module ConnectPluginExtension = PluginConnectExtension_Builder.Make({
      let pluginDefinition = pluginDefinition
      let extensionPointsOutputs = extensionPointsOutputs
      let extensionsOutputs = extensionsOutputs
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
      ->Pulumi.Output.apply(({incomingEventHandler}) => incomingEventHandler)

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
  ~opts,
) => {
  tasksOutputs :=
    tasks->Array.map((module(SpecificTask: Task.T)) =>
      SpecificTask.make(
        ~queryBucketName=(~taskName, ~bucketName="Bucket") =>
          ResourceQueryRuntime.bucketNameOfTaskExn(tasksOutputs.contents, ~taskName, ~bucketName),
        ~scheduler,
        ~publishToAggregates,
        ~queryEngine,
        ~allAggregates=aggregatesOutputs,
        ~opts=Some(opts),
      )->Component.outputs
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
    ~corePluginExtensionPointUnwrapped: ExtensionPoint.unwrappedOutputs,
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
          corePluginExtensionPointUnwrapped.commandTopic.resources->Adapter.unwrappedToResources,
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
        let outgoingExtensionPointEventHandlers = serviceNameToEventHandlers(
          extensionPointsOutputs,
          outputs => outputs.aggregateNames,
          extensionPointsHandlers->Array.map(extensionPointsHandler => {
            outgoing: extensionPointsHandler,
          }),
          getOutgoingEventHandler,
        )
        let incomingConnectExtensionEventHandlers = serviceNameToEventHandlers(
          [connectPluginExtensionOutputs],
          outputs => [outputs.extensionPointName],
          [{incoming: connectPluginExtensionIncomingEventHandler}],
          getIncomingEventHandler,
        )
        let outgoingExtensionEventHandlers = serviceNameToEventHandlers(
          extensionsOutputs,
          outputs => outputs.aggregateNames,
          extensionsHandlers,
          getOutgoingEventHandler,
        )
        let incomingExtensionEventHandlers = serviceNameToEventHandlers(
          extensionsOutputs,
          outputs => [outputs.extensionPointName],
          extensionsHandlers,
          getIncomingEventHandler,
        )
      })
      let handler = PluginEventCollector.makeHandler(
        ~eventCollector,
        ~eventsHandler=Callback.handleJsonEvents,
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
