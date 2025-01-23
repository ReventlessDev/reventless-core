// TODO: refactor to smaller code parts for a better overview
open ReventlessSpec.Adapter

let componentType = ComponentType.Plugin

type outputs = {
  id: Pulumi.Output.t<string>,
  version: Pulumi.Output.t<string>,
  heartbeatInterval: Pulumi.Output.t<int>,
  eventCollector: Pulumi.Output.t<ReventlessSpec.EventCollector.outputs>,
  extensionPoints: Pulumi.Output.t<Js.Dict.t<ReventlessSpec.ExtensionPoint.outputs>>,
  extensions: Pulumi.Output.t<Js.Dict.t<Extension.outputs>>,
  aggregates: Pulumi.Output.t<Js.Dict.t<Aggregate.outputs>>,
  readModels: Pulumi.Output.t<Js.Dict.t<ReventlessSpec.ReadModel.outputs>>,
  tasks: Pulumi.Output.t<Js.Dict.t<Task.outputs>>,
  resolvers: Pulumi.Output.t<array<resource>>,
  heartbeat: Pulumi.Output.t<Heartbeat.outputs>,
}

type t
type component = ReventlessSpec.Component.t<t, outputs>

module type T = {
  let make: (
    ~name: string,
    ~version: string,
    ~heartbeatInterval: int,
    ~extensionPoints: array<module(ReventlessSpec.ExtensionPoint.T)>,
    ~extensions: array<module(Extension.T)>,
    ~aggregates: array<module(Aggregate.T)>,
    ~readModels: array<module(ReventlessSpec.ReadModel.T)>,
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
  eventCollector: ReventlessSpec.EventCollector.outputs,
  extensionPoints: Js.Dict.t<ReventlessSpec.ExtensionPoint.outputs>,
  extensions: Js.Dict.t<Extension.outputs>,
  aggregates: Js.Dict.t<Aggregate.outputs>,
  readModels: Js.Dict.t<ReventlessSpec.ReadModel.outputs>,
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
      ->Belt.Option.map(
        (readModel: ReventlessSpec.ReadModel.outputs) => readModel.queryDb.resources,
      )
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
    module_: module(ReventlessSpec.ReadModel.T),
    readModel: ReventlessSpec.ReadModel.component,
  }

  let construct = (
    ~version: string,
    ~heartbeatInterval: int,
    ~extensionPoints: array<module(ReventlessSpec.ExtensionPoint.T)>,
    ~extensions: array<module(Extension.T)>,
    ~aggregates: array<module(Aggregate.T)>,
    ~readModels: array<module(ReventlessSpec.ReadModel.T)>,
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

    let readModels = readModels->Belt.Array.map((module(ReadModel: ReventlessSpec.ReadModel.T)) => {
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

    let extensionPoints =
      extensionPoints->Belt.Array.map((module(ExtensionPoint: ReventlessSpec.ExtensionPoint.T)) =>
        ExtensionPoint.make(~publishToAggregates, ~scheduler, ~queryEngine, ~opts=Some(opts))
      )
    let extensionPointsOutputs = extensionPoints->Component.extractMultipleOutputs

    let pureOutputs = {
      let coreExtensionPoints =
        Interstack.coreStackReference->Belt.Option.mapWithDefault(
          Pulumi.Output.make(None),
          coreStack => coreStack->Pulumi.StackReference.getOutput("extensionPoints"),
        )

      coreExtensionPoints->Pulumi.Output.apply(coreExtensionPoints => {
        let coreExtensionPoints = switch coreExtensionPoints {
        | Some(coreExtensionPoints) => coreExtensionPoints
        | None =>
          Js.Exn.raiseError(
            "No Core Stack configured or no Core ExtensionPoints! (Please set 'core:stack: user/project/stack' in you Pulumi.*.config!",
          )
        }
        let corePluginExtensionPoint: ReventlessSpec.ExtensionPoint.outputs = {
          let extensionPointUnwrapped: ExtensionPoint.unwrappedOutputs =
            coreExtensionPoints->Pulumi.StackReference.get(
              ReventlessSpec.PluginExtensionPointSpec.name,
            )
          {
            name: extensionPointUnwrapped.name,
            aggregateNames: extensionPointUnwrapped.aggregateNames,
            outgoingEventHandler: extensionPointUnwrapped.outgoingEventHandler,
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

        let extensions =
          extensions->Belt.Array.map((module(Extension: Extension.T)) =>
            Extension.make(
              ~publishToCorePluginExtensionPoint,
              ~publishToAggregates,
              ~readModelNamesForSourceName,
              ~publishToReadModels,
              ~queryEngine,
              ~opts=Some(opts),
            )
          )
        let extensionsOutputs = extensions->Component.extractMultipleOutputs

        let (eventCollectorUrn, setEventCollectorUrn) = Util.Pulumi.Output.Async.make()

        let extensionPointsConfig =
          extensionPointsOutputs
          ->Belt.Array.map(extensionPoint =>
            (
              (extensionPoint.commandTopic.resources->Array.getUnsafe(0)).id, // FIXME
              (extensionPoint.eventTopic.resources->Array.getUnsafe(0)).id,
            )
            ->Pulumi.Output.all2
            ->Pulumi.Output.apply(
              ((commandTopicConnectorId, eventTopicPublisherId)) => {
                ReventlessSpec.Plugin.name: extensionPoint.name,
                commandTopic: commandTopicConnectorId,
                eventTopic: eventTopicPublisherId,
              },
            )
          )
          ->Pulumi.Output.all

        let extensionsConfig = extensionsOutputs->Belt.Array.map(extension => {
          ReventlessSpec.Plugin.name: extension.name,
          extensionPointName: extension.extensionPointName,
        })

        let pluginDefinition =
          (extensionPointsConfig, eventCollectorUrn)
          ->Pulumi.Output.all2
          ->Pulumi.Output.apply(((extensionPointsConfig, eventCollectorUrn)) => {
            ReventlessSpec.Plugin.id,
            name,
            version,
            extensionPoints: extensionPointsConfig,
            extensions: extensionsConfig,
            eventCollector: eventCollectorUrn,
          })

        module PluginConnectExtensionSpec = {
          let pluginDefinition = pluginDefinition
          let extensionPointsOutputs = extensionPointsOutputs
          let extensionsOutputs = extensionsOutputs
        }
        module ConnectPluginExtension = PluginConnectExtension.Make(PluginConnectExtensionSpec)
        let connectPluginExtension = ConnectPluginExtension.make(
          ~publishToCorePluginExtensionPoint,
          ~publishToAggregates,
          ~readModelNamesForSourceName,
          ~publishToReadModels,
          ~queryEngine,
          ~opts=Some(opts),
        )

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

        module RuntimeSpec = {
          let pluginDefinition = pluginDefinition
          let connectPluginExtension = connectPluginExtension
          let extensionPointsOutputs = extensionPointsOutputs
          let extensionsOutputs = extensionsOutputs
        }
        module Runtime = Plugin_Runtime.Make(RuntimeSpec)

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
        setEventCollectorUrn((eventCollectorOutputs.resources->Array.getUnsafe(0)).urn) //FIXME

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
      eventCollector: pureOutputs->Pulumi.Output.apply(outputs => outputs.eventCollector),
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
