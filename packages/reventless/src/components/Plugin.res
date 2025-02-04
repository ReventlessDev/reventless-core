// TODO: refactor to smaller code parts for a better overview
open ReventlessSpec.Adapter

let componentType = ComponentType.Plugin

type outputs = {
  id: Pulumi.Output.t<string>,
  version: Pulumi.Output.t<string>,
  heartbeatInterval: Pulumi.Output.t<int>,
  eventCollector: Pulumi.Output.t<EventCollector.outputs>,
  extensionPoints: Pulumi.Output.t<Js.Dict.t<ExtensionPoint.outputs>>,
  extensions: Pulumi.Output.t<Js.Dict.t<Extension.outputs>>,
  aggregates: Pulumi.Output.t<Js.Dict.t<Aggregate.outputs>>,
  readModels: Pulumi.Output.t<Js.Dict.t<ReadModel.outputs>>,
  tasks: Pulumi.Output.t<Js.Dict.t<Task.outputs>>,
  resolvers: Pulumi.Output.t<array<resource>>,
  heartbeat: Pulumi.Output.t<Heartbeat.outputs>,
}

type t
type component = Component.t<t, outputs>

module type T = {
  let make: (
    ~name: string,
    ~version: string,
    ~heartbeatInterval: int,
    ~extensionPoints: array<module(ExtensionPoint.T)>,
    ~extensions: array<module(Extension.T)>,
    ~aggregates: array<module(Aggregate.T)>,
    ~readModels: array<module(ReadModel.T)>,
    ~taskMakers: array<Task.maker>,
    ~scheduler: ReventlessSpec.Scheduler.t,
    ~opts: Pulumi.ComponentResource.options=?,
  ) => component
}

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
  resolvers: array<resource>,
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
    Js.log("Util_QueryDbRuntime.getLocalStorageResources: Couldn't find Plugin $pluginName")
    []->Pulumi.Output.make
  }

let getStorageResources = (allQueryDbs, pluginName, queryDbName) =>
  switch pluginName {
  | None =>
    Util_QueryDbRuntime.getLocalStorageResources(allQueryDbs, queryDbName)->Pulumi.Output.make
  | Some(pluginName) => getRemoteStorageResources(pluginName, queryDbName)
  }

type withAggregateNames = {aggregateNames: array<string>}

let makeId = (name, version) => `${name}@${version}`

module Make = (
  EventCollectorConnector: EventCollector.Adapter.Connector,
  QueryEngineAdapter: QueryDb.Adapter.QueryEngineAdapter,
  CorePluginExtensionPointRemoteConnector: CommandTopic.Adapter.RemoteConnector,
): T => {
  type constructed
  type construct = (component, string) => constructed

  @module("./Component") @new
  external make: (
    ~componentType: string,
    ~name: string,
    ~construct: construct,
    ~opts: option<Pulumi.ComponentResource.options>,
  ) => component = "default"

  @send
  external registerOutputs: (component, outputs) => constructed = "registerOutputs"
  @send external setOutputs: (component, outputs) => unit = "setOutputs"
  let setOutputs = (self, outputs) => {
    self->setOutputs(outputs)
    self->registerOutputs(outputs)
  }

  type readModel = {
    module_: module(ReadModel.T),
    readModel: ReadModel.component,
  }

  type eventHandlers = {
    outgoing?: Plugin_Runtime.eventHandler,
    incoming?: Plugin_Runtime.eventHandler,
  }
  let incomingEventHandler = eventHandlers => eventHandlers.incoming
  let outgoingEventHandler = eventHandlers => eventHandlers.outgoing

  let construct = (
    ~version: string,
    ~heartbeatInterval: int,
    ~extensionPoints: array<module(ExtensionPoint.T)>,
    ~extensions: array<module(Extension.T)>,
    ~aggregates: array<module(Aggregate.T)>,
    ~readModels: array<module(ReadModel.T)>,
    ~taskMakers: array<Task.maker>,
    ~scheduler: ReventlessSpec.Scheduler.t,
    self,
    name,
  ) => {
    let id = makeId(name, version)

    let opts = {Pulumi.ComponentResource.parent: self->Component.toPulumiResource}

    let addEventMapperFns = Js.Dict.empty()
    let publishToAggregates = Js.Dict.empty()

    let aggregatesWithoutEventMappers =
      aggregates
      ->Belt.Array.map((module(Aggregate: Aggregate.T)) => {
        let aggregate = Aggregate.make(~opts)
        addEventMapperFns->Js.Dict.set(Aggregate.Spec.name, aggregate->Aggregate.addEventMapper)
        publishToAggregates->Js.Dict.set(Aggregate.Spec.name, aggregate->Aggregate.publishJsons)
        aggregate->Component.extractOutputs
      })
      ->Belt.Array.map(aggregate => {(aggregate.name, aggregate)})
      ->Js.Dict.fromArray

    let allEventTopics = Aggregate.allEventTopics(aggregatesWithoutEventMappers)

    let readModelNamesForSourceName = Js.Dict.empty()
    let publishToReadModels = Js.Dict.empty()

    let readModels = readModels->Belt.Array.map((module(ReadModel: ReadModel.T)) => {
      let readModel = ReadModel.make(~allEventTopics, ~opts)
      ReadModel.sourceNames->Belt.Array.forEach(sourceName =>
        switch readModelNamesForSourceName->Js.Dict.get(sourceName) {
        | Some(readModelNames) =>
          Js.Dict.set(
            readModelNamesForSourceName,
            sourceName,
            readModelNames->Belt.Array.concat([ReadModel.Spec.name]),
          )
        | None => Js.Dict.set(readModelNamesForSourceName, sourceName, [ReadModel.Spec.name])
        }
      )
      publishToReadModels->Js.Dict.set(ReadModel.Spec.name, readModel->ReadModel.enqueueEvent)

      (ReadModel.Spec.name, {module_: module(ReadModel), readModel})
    })
    let readModelsOutputs =
      readModels
      ->Js.Dict.fromArray
      ->Js.Dict.entries
      ->Belt.Array.map(((name, {readModel})) => (name, readModel->Component.extractOutputs))
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
      )
      ->Pulumi.Output.all3
      ->Pulumi.Output.apply(((coreExtensionPoints, publishToAggregates, publishToReadModels)) => {
        let extensionPointsHandlers =
          extensionPoints->Belt.Array.map((module(ExtensionPoint: ExtensionPoint.T)) => {
            let extensionPoint = ExtensionPoint.make(
              ~publishToAggregates,
              ~scheduler,
              ~queryEngine,
              ~opts=Some(opts),
            )
            (
              extensionPoint->Component.extractOutputs,
              {outgoing: extensionPoint->ExtensionPoint.outgoingEventHandler->Pulumi.Output.unwrap},
            )
          })
        let (extensionPointsOutputs, _) = extensionPointsHandlers->Belt.Array.unzip

        let coreExtensionPoints = switch coreExtensionPoints {
        | Some(coreExtensionPoints) => coreExtensionPoints
        | None =>
          Js.Exn.raiseError(
            "No Core Stack configured or no Core ExtensionPoints! (Please set 'core:stack: user/project/stack' in you Pulumi.*.config!",
          )
        }
        let corePluginExtensionPoint: ExtensionPoint.outputs = {
          let extensionPointUnwrapped: ExtensionPoint.unwrappedOutputs =
            coreExtensionPoints->Pulumi.StackReference.get(
              ReventlessSpec.PluginExtensionPointSpec.name,
            )
          {
            name: extensionPointUnwrapped.name,
            aggregateNames: extensionPointUnwrapped.aggregateNames,
            commandTopic: {
              resources: extensionPointUnwrapped.commandTopic.resources->Belt.Array.map(
                AdapterDeploytime.unwrappedToResource,
              ),
            },
            eventTopic: {
              resources: extensionPointUnwrapped.eventTopic.resources->Belt.Array.map(
                AdapterDeploytime.unwrappedToResource,
              ),
            },
          }
        }

        let corePluginExtensionPointCommandTopicRemoteConnector = CorePluginExtensionPointRemoteConnector.make(
          corePluginExtensionPoint.commandTopic.resources,
        )
        let publishToCorePluginExtensionPoint = corePluginExtensionPointCommandTopicRemoteConnector.remotePublish

        let extensionsHandlers = extensions->Belt.Array.map((module(Extension: Extension.T)) => {
          let extension = Extension.make(
            ~publishToCorePluginExtensionPoint,
            ~publishToAggregates,
            ~readModelNamesForSourceName,
            ~publishToReadModels,
            ~queryEngine,
            ~opts=Some(opts),
          )
          (
            extension->Component.extractOutputs,
            {
              outgoing: extension->Extension.outgoingEventHandler,
              incoming: extension->Extension.incomingEventHandler,
            },
          )
        })
        let extensionsOutputs =
          extensionsHandlers->Belt.Array.map(((extensionOutputs, _)) => extensionOutputs)

        let extensionPointsDefinitions =
          extensionPointsOutputs
          ->Belt.Array.map(extensionPointOutputs =>
            (
              (extensionPointOutputs.commandTopic.resources->Array.getUnsafe(0)).id, // FIXME
              (extensionPointOutputs.eventTopic.resources->Array.getUnsafe(0)).id,
            )
            ->Pulumi.Output.all2
            ->Pulumi.Output.apply(
              ((commandTopicConnectorId, eventTopicPublisherId)) => {
                ReventlessSpec.Plugin.name: extensionPointOutputs.name,
                commandTopic: commandTopicConnectorId,
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

        module ConnectPluginExtension = PluginConnectExtension.Make({
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
        let connectPluginExtensionOutputs = connectPluginExtension->Component.extractOutputs
        let connectPluginExtensionIncomingEventHandler =
          connectPluginExtension->ConnectPluginExtension.incomingEventHandler

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
            )->Component.extractOutputs
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
            resources: corePluginExtensionPoint.eventTopic.resources->Belt.Array.map(
              AdapterDeploytime.stackRefResourceToResource,
            ),
          },
        )

        let serviceNameToEventHandlers = (handlers, getServiceNames, getEventHandler) => {
          let dict = Js.Dict.empty()
          handlers->Belt.Array.forEach(((outputs, eventHandlers)) => {
            eventHandlers
            ->getEventHandler
            ->Belt.Option.forEach(
              eventHandler =>
                outputs
                ->getServiceNames
                ->Belt.Array.forEach(
                  serviceName =>
                    switch dict->Js.Dict.get(serviceName) {
                    | Some(mappedExtensionPoints) =>
                      Js.Dict.set(
                        dict,
                        serviceName,
                        mappedExtensionPoints->Belt.Array.concat([eventHandler]),
                      )
                    | None => Js.Dict.set(dict, serviceName, [eventHandler])
                    },
                ),
            )
          })
          dict
        }

        let eventCollectorOutputs = pluginDefinition->Pulumi.Output.apply(pluginDefinition => {
          module Runtime = Plugin_Runtime.Make({
            let pluginDefinition = pluginDefinition
            let incomingConnectExtensionEventHandlers =
              [
                (
                  connectPluginExtensionOutputs,
                  {incoming: connectPluginExtensionIncomingEventHandler},
                ),
              ]->serviceNameToEventHandlers(
                outputs => [outputs.extensionPointName],
                incomingEventHandler,
              )
            let outgoingExtensionPointEventHandlers =
              extensionPointsHandlers->serviceNameToEventHandlers(
                outputs => outputs.aggregateNames,
                outgoingEventHandler,
              )
            let outgoingExtensionEventHandlers =
              extensionsHandlers->serviceNameToEventHandlers(
                outputs => outputs.aggregateNames,
                outgoingEventHandler,
              )
            let incomingExtensionEventHandlers =
              extensionsHandlers->serviceNameToEventHandlers(
                outputs => [outputs.extensionPointName],
                incomingEventHandler,
              )
          })
          module PluginEventCollector = EventCollector.Make(EventCollectorConnector)

          let eventCollector = PluginEventCollector.make(
            ~name=name->ComponentType.name(componentType),
            ~eventTopics,
            ~eventsHandler=Runtime.eventsHandler,
            ~policy1=Pulumi.Output.make(None),
            ~policy2=Pulumi.Output.make(None),
            ~opts=Some(opts),
          )
          let eventCollectorOutputs = eventCollector->Component.extractOutputs

          let _ =
            (eventCollectorOutputs.resources->Array.getUnsafe(0)).urn->Pulumi.Output.apply(
              urn => Runtime.setEventCollector(urn),
            )
          eventCollectorOutputs
        })
        let heartbeat = Heartbeat.make(
          ~id,
          ~name=name ++ componentType->ComponentType.toName,
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
          heartbeat: heartbeat->Component.extractOutputs,
        }
      })
    }
    self->setOutputs({
      id: pureOutputs->Pulumi.Output.apply(outputs => outputs.id),
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
    make(
      ~componentType=componentType->ComponentType.toString,
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
