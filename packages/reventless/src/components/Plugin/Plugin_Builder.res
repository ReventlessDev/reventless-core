// TODO: find better naming
type pureOutputs = {
  id: string,
  version: string,
  heartbeatInterval: int,
  eventCollector: Pulumi.Output.t<EventCollector.outputs>,
  extensionPoints: Js.Dict.t<ExtensionPoint.outputs>,
  extensions: Js.Dict.t<Extension.outputs>,
  aggregates: Js.Dict.t<Aggregate.outputs>,
  readModels: Js.Dict.t<ReadModel.outputs>,
  tasks: Js.Dict.t<Task.outputs>,
  resolvers: array<ReventlessSpec.Adapter.resource>,
  heartbeat: Heartbeat.outputs,
}

let getRemoteStorageResources = (pluginName, queryDbName) =>
  switch Util_StackRefs.get(pluginName)->Belt.Option.map(stackRef => {
    stackRef
    ->Pulumi.StackReference.requireOutput("plugin"->Pulumi.Input.make)
    ->Pulumi.Output.apply((plugin: pureOutputs) =>
      plugin.readModels
      ->Js.Dict.get(queryDbName)
      ->Belt.Option.map((readModel: ReadModel.outputs) => readModel.queryDb.resources)
      ->Belt.Option.getWithDefault([])
    )
  }) {
  | Some(resources) => resources
  | None =>
    Js.log("Plugin_Builder.getRemoteStorageResources: Couldn't find Plugin $pluginName")
    []->Pulumi.Output.make
  }

let getStorageResources = (allQueryDbs, pluginName, queryDbName) =>
  switch pluginName {
  | None =>
    Util_QueryDbRuntime.getLocalStorageResources(allQueryDbs, queryDbName)->Pulumi.Output.make
  | Some(pluginName) => getRemoteStorageResources(pluginName, queryDbName)
  }

let makeId = (name, version) => `${name}@${version}`

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
  let dict = Js.Dict.empty()
  Belt.Array.zip(outputs, handlers)->Belt.Array.forEach(((outputs, eventHandlers)) => {
    eventHandlers
    ->getEventHandler
    ->Belt.Option.forEach(eventHandler =>
      outputs
      ->getServiceNames
      ->Belt.Array.forEach(
        serviceName =>
          switch dict->Js.Dict.get(serviceName) {
          | Some(eventHandlers) =>
            Js.Dict.set(dict, serviceName, eventHandlers->Belt.Array.concat([eventHandler]))
          | None => Js.Dict.set(dict, serviceName, [eventHandler])
          },
      )
    )
  })
  dict
}

module Make = (
  EventCollectorChannel: EventCollector_Adapter.Channel,
  QueryEngineAdapter: QueryDb_Adapter.QueryEngineAdapter,
  CorePluginExtensionPointRemoteChannel: CommandTopic_Adapter.RemoteChannel,
  HeartbeatRunner: Heartbeat_Adapter.Runner,
): Plugin.T => {
  type readModel = {
    module_: module(ReadModel.T),
    readModel: ReadModel.component,
  }

  let construct = (
    ~version: string,
    ~heartbeatInterval: int,
    ~extensionPoints: array<module(ExtensionPoint.T)>,
    ~extensions: array<module(Extension.T)>,
    ~aggregates: array<module(Aggregate.T)>,
    ~readModels: array<module(ReadModel.T)>,
    ~taskMakers: array<Task.maker>,
    ~scheduler: Pulumi.Output.t<Scheduler.operations>,
    self,
    name,
  ) => {
    let id = makeId(name, version)

    let opts = {Pulumi.ComponentResource.parent: self->Component.toPulumiResource}

    let addEventMapperFns = Js.Dict.empty()
    let publishToAggregates = Js.Dict.empty()

    let aggregatesWithoutEventMappers =
      aggregates
      ->Belt.Array.map((module(SpecificAggregate: Aggregate.T)) => {
        let aggregate = SpecificAggregate.make(~opts)
        addEventMapperFns->Js.Dict.set(
          SpecificAggregate.Spec.name,
          (aggregate->Component.outputs).addEventMapper,
        )
        publishToAggregates->Js.Dict.set(
          SpecificAggregate.Spec.name,
          aggregate->Component.operations->Pulumi.Output.apply(({publishJsons}) => publishJsons),
        )
        aggregate->Component.outputs
      })
      ->Belt.Array.map(aggregate => {(aggregate.name, aggregate)})
      ->Js.Dict.fromArray

    let allEventTopics = Aggregate.allEventTopics(aggregatesWithoutEventMappers)

    let readModelNamesForSourceName = Js.Dict.empty()
    let publishToReadModels = Js.Dict.empty()

    let readModels = readModels->Belt.Array.map((module(SpecificReadModel: ReadModel.T)) => {
      let readModel = SpecificReadModel.make(~allEventTopics, ~opts)
      (readModel->Component.outputs).sourceNames->Belt.Array.forEach(sourceName =>
        switch readModelNamesForSourceName->Js.Dict.get(sourceName) {
        | Some(readModelNames) =>
          readModelNamesForSourceName->Js.Dict.set(
            sourceName,
            readModelNames->Belt.Array.concat([SpecificReadModel.Spec.name]),
          )
        | None =>
          Js.Dict.set(readModelNamesForSourceName, sourceName, [SpecificReadModel.Spec.name])
        }
      )

      publishToReadModels->Js.Dict.set(
        SpecificReadModel.Spec.name,
        readModel
        ->Component.operations
        ->Pulumi.Output.apply(({enqueueEvent}) => enqueueEvent),
      )

      (SpecificReadModel.Spec.name, {module_: module(SpecificReadModel), readModel})
    })
    let readModelsOutputs =
      readModels
      ->Js.Dict.fromArray
      ->Js.Dict.entries
      ->Belt.Array.map(((name, {readModel})) => (name, readModel->Component.outputs))
      ->Js.Dict.fromArray

    let allQueryDbs = readModelsOutputs->ReadModel.allQueryDbs
    let queryEngine = QueryEngineAdapter.make(allQueryDbs)

    let aggregatesOutputs = Js.Dict.map(
      addEventMapperFn => addEventMapperFn(allEventTopics, queryEngine),
      addEventMapperFns,
    )

    let pureOutputs = {
      let coreExtensionPoints =
        Interstack.coreStackReference->Belt.Option.mapWithDefault(
          Pulumi.Output.make(None),
          coreStack => coreStack->Pulumi.StackReference.getOutput("extensionPoints"),
        )

      (
        coreExtensionPoints,
        publishToAggregates->Pulumi.Output.allDict,
        publishToReadModels->Pulumi.Output.allDict,
        scheduler,
      )
      ->Pulumi.Output.all4
      ->Pulumi.Output.apply(((
        coreExtensionPoints,
        publishToAggregates,
        publishToReadModels,
        scheduler,
      )) => {
        let (extensionPointsOutputs, extensionPointsHandlers) =
          extensionPoints
          ->Belt.Array.map((module(SpecificExtensionPoint: ExtensionPoint.T)) => {
            let extensionPoint = SpecificExtensionPoint.make(
              ~publishToAggregates,
              ~scheduler,
              ~queryEngine,
              ~opts=Some(opts),
            )
            (
              extensionPoint->Component.outputs,
              extensionPoint
              ->Component.operations
              ->Pulumi.Output.apply(({outgoingEventHandler}) => {outgoing: outgoingEventHandler}),
            )
          })
          ->Belt.Array.unzip

        let coreExtensionPoints = switch coreExtensionPoints {
        | Some(coreExtensionPoints) => coreExtensionPoints
        | None =>
          Js.Exn.raiseError(
            "No Core Stack configured or no Core ExtensionPoints! (Please set 'core:stack: user/project/stack' in you Pulumi.*.config!",
          )
        }
        let corePluginExtensionPointUnwrapped: ExtensionPoint.unwrappedOutputs =
          coreExtensionPoints->Pulumi.StackReference.get(
            ReventlessSpec.PluginExtensionPointSpec.name,
          )

        let corePluginExtensionPointCommandTopicRemoteChannel = CorePluginExtensionPointRemoteChannel.make(
          corePluginExtensionPointUnwrapped.commandTopic.resources,
        )
        let publishToCorePluginExtensionPoint = corePluginExtensionPointCommandTopicRemoteChannel.remotePublish

        let (extensionsOutputs, extensionsHandlers) =
          extensions
          ->Belt.Array.map((module(SpecificExtension: Extension.T)) => {
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
              ->Pulumi.Output.apply(
                ({outgoingEventHandler, incomingEventHandler}) => {
                  incoming: incomingEventHandler,
                  outgoing: outgoingEventHandler,
                },
              ),
            )
          })
          ->Belt.Array.unzip

        let extensionPointsDefinitions =
          extensionPointsOutputs
          ->Belt.Array.map(extensionPointOutputs =>
            (
              extensionPointOutputs.commandTopic->Pulumi.Output.flatMap(
                ({resources}) => (resources->Array.getUnsafe(0)).id, // FIXME
              ),
              extensionPointOutputs.eventTopic->Pulumi.Output.flatMap(
                ({resources}) => (resources->Array.getUnsafe(0)).id, // FIXME
              ),
            )
            ->Pulumi.Output.all2
            ->Pulumi.Output.apply(
              ((commandTopicChannelId, eventTopicPublisherId)) => {
                ReventlessSpec.Plugin.name: extensionPointOutputs.name,
                commandTopic: commandTopicChannelId,
                eventTopic: eventTopicPublisherId,
              },
            )
          )
          ->Pulumi.Output.all

        let extensionsDefinitions = extensionsOutputs->Belt.Array.map(extensionOutputs => {
          ReventlessSpec.Plugin.name: extensionOutputs.name,
          extensionPointName: extensionOutputs.extensionPointName,
        })

        let pluginDefinition =
          extensionPointsDefinitions->Pulumi.Output.apply(extensionPointsDefinitions => {
            ReventlessSpec.Plugin.id,
            name,
            version,
            extensionPoints: extensionPointsDefinitions,
            extensions: extensionsDefinitions,
            eventCollector: "",
          })

        let (connectPluginExtensionOutputs, connectPluginExtensionIncomingEventHandler) =
          extensionPointsOutputs
          ->Belt.Array.map(ExtensionPoint.toUnwrappedOutputs)
          ->Pulumi.Output.all
          ->Pulumi.Output.apply(extensionPointsOutputs => {
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
        let queryBucketName = taskName =>
          ResourceQueryRuntime.bucketNameOfTaskExn(tasksOutputs.contents, taskName)

        tasksOutputs :=
          taskMakers->Belt.Array.map(taskMaker =>
            taskMaker(
              ~queryBucketName,
              ~scheduler,
              ~publishToAggregates,
              ~queryEngine,
              ~allAggregates=aggregatesOutputs,
              ~opts=Some(opts),
            )->Component.outputs
          )

        let allQueryDbs = readModelsOutputs->ReadModel.allQueryDbs
        let resolvers =
          allQueryDbs
          ->QueryDb.allResolversMakers
          ->Belt.Array.map(resolverMaker => resolverMaker(allQueryDbs))
          ->Belt.Array.concatMany

        module Set = Belt.Set.String

        let collectAggregateNames = ex =>
          ex
          ->Set.fromArray
          ->Set.remove(ReventlessSpec.ExtensionMapping.NoAggregate.name)

        let extensionPointAggregateNames =
          extensionPointsOutputs
          ->Belt.Array.flatMap(ex => ex.aggregateNames)
          ->collectAggregateNames

        let extensionAggregateNames =
          extensionsOutputs
          ->Belt.Array.flatMap(ex => ex.aggregateNames)
          ->collectAggregateNames

        let eventTopics =
          aggregatesOutputs->Aggregate.filterEventTopics(
            extensionPointAggregateNames->Set.union(extensionAggregateNames),
          )
        eventTopics->Js.Dict.set(
          ReventlessSpec.PluginExtensionPointSpec.name,
          {
            resources: corePluginExtensionPointUnwrapped.eventTopic.resources->Belt.Array.map(
              AdapterDeploytime.unwrappedToResource,
            ),
          },
        )

        let eventCollectorOutputs =
          (
            pluginDefinition,
            connectPluginExtensionIncomingEventHandler->Pulumi.Output.unwrap,
            extensionsHandlers->Pulumi.Output.all,
            extensionPointsHandlers->Pulumi.Output.all,
            connectPluginExtensionOutputs,
          )
          ->Pulumi.Output.all5
          ->Pulumi.Output.apply(((
            pluginDefinition,
            connectPluginExtensionIncomingEventHandler,
            extensionsHandlers,
            extensionPointsHandlers,
            connectPluginExtensionOutputs,
          )) => {
            module Callback = Plugin_Callback.Make({
              let pluginDefinition = pluginDefinition
              let outgoingExtensionPointEventHandlers = serviceNameToEventHandlers(
                extensionPointsOutputs,
                outputs => outputs.aggregateNames,
                extensionPointsHandlers,
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
            module PluginEventCollector = EventCollector_Builder.Make(EventCollectorChannel)

            let eventCollector = PluginEventCollector.make(
              ~name=name->ComponentType.name(Plugin.componentType),
              ~eventTopics,
              ~eventsHandler=Callback.eventsHandler,
              ~policy1=Pulumi.Output.make(None),
              ~policy2=Pulumi.Output.make(None),
              ~opts=Some(opts),
            )
            let eventCollectorOutputs = eventCollector->Component.outputs

            let _ =
              (eventCollectorOutputs.resources->Array.getUnsafe(0)).urn->Pulumi.Output.apply(
                urn => pluginDefinition.eventCollector = urn,
              )
            eventCollectorOutputs
          })

        module SpecificHeartbeat = Heartbeat_Builder.Make(HeartbeatRunner)
        let heartbeat = SpecificHeartbeat.make(
          ~id,
          ~name=name ++ Plugin.componentType->ComponentType.toName,
          ~timeout=heartbeatInterval,
          ~publishToCorePluginExtensionPoint,
          ~opts,
        )

        {
          id,
          version,
          heartbeatInterval,
          eventCollector: eventCollectorOutputs,
          extensionPoints: extensionPointsOutputs
          ->Belt.Array.map(el => (el.name, el))
          ->Js.Dict.fromArray,
          extensions: extensionsOutputs
          ->Belt.Array.map(el => (el.name, el))
          ->Js.Dict.fromArray,
          aggregates: aggregatesOutputs,
          readModels: readModelsOutputs,
          tasks: tasksOutputs.contents
          ->Belt.Array.map(el => (el.name, el))
          ->Js.Dict.fromArray,
          resolvers,
          heartbeat: heartbeat->Component.outputs,
        }
      })
    }
    self->Component.setOutputs({
      Plugin.id: pureOutputs->Pulumi.Output.apply(outputs => outputs.id),
      version: pureOutputs->Pulumi.Output.apply(outputs => outputs.version),
      heartbeatInterval: pureOutputs->Pulumi.Output.apply(outputs => outputs.heartbeatInterval),
      eventCollector: pureOutputs->Pulumi.Output.flatMap(outputs => outputs.eventCollector),
      extensionPoints: pureOutputs->Pulumi.Output.apply(outputs => outputs.extensionPoints),
      extensions: pureOutputs->Pulumi.Output.apply(outputs => outputs.extensions),
      aggregates: pureOutputs->Pulumi.Output.apply(outputs => outputs.aggregates),
      readModels: pureOutputs->Pulumi.Output.apply(outputs => outputs.readModels),
      tasks: pureOutputs->Pulumi.Output.apply(outputs => outputs.tasks),
      resolvers: pureOutputs->Pulumi.Output.apply(outputs => outputs.resolvers),
      heartbeat: pureOutputs->Pulumi.Output.apply(outputs => outputs.heartbeat),
    })
  }

  let make = (
    ~name,
    ~version,
    ~heartbeatInterval,
    ~extensionPoints,
    ~extensions,
    ~aggregates,
    ~readModels,
    ~taskMakers,
    ~scheduler,
    ~opts=?,
  ) =>
    Component.make(
      ~componentType=Plugin.componentType->ComponentType.toString,
      ~name,
      ~construct=construct(
        ~version,
        ~heartbeatInterval,
        ~extensionPoints,
        ~extensions,
        ~aggregates,
        ~readModels,
        ~taskMakers,
        ~scheduler,
        ...
      ),
      ~opts,
    )
}
