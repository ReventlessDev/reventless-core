open Plugin_Helpers

module type Spec = {
  let runtimeOps: ReventlessSpec.PluginRuntimeOperations.operations
  let resourceNaming: ReventlessSpec.ResourceNaming.operations
  let environment: string
}

module Make = (
  Spec: Spec,
  RuntimeEnvironment: Runtime.Environment,
  EventCollectorChannel: EventCollector_Adapter.Channel
    with type runtimeParts = RuntimeEnvironment.parts,
  QueryEngineAdapter: QueryDb_Adapter.QueryEngineAdapter,
  CorePluginExtensionPointRemoteChannel: CommandTopic_Adapter.RemoteChannel,
  HeartbeatRunner: Heartbeat_Adapter.Runner with type runtimeParts = RuntimeEnvironment.parts,
  PluginRuntimeBuilder: PluginRuntime_Builder.T
    with module EventCollectorChannel = EventCollectorChannel
    and type runtimeParts = RuntimeEnvironment.parts,
  DcbEventLogStorage: DcbEventLog_Adapter.Storage,
  DcbEventTopicPublisher: EventTopic_Adapter.Publisher,
  DcbCommandTopicChannel: CommandTopic_Adapter.Channel,
): Plugin.T => {
  let construct = (
    ~version: string,
    ~heartbeatInterval: int,
    ~extensionPoints: array<module(ExtensionPoint.T)>,
    ~extensions: array<module(Extension.T)>,
    ~aggregates: array<module(Aggregate.T)>,
    ~readModels: array<module(ReadModel.T)>,
    ~tasks: array<module(Task.T)>,
    ~scheduler: Pulumi.Output.t<Scheduler.operations>,
    ~dcbSpec: option<module(Plugin.DcbSpec)>,
    self,
    name,
  ) => {
    let id = Plugin.makeId(name, version)
    let opts = {Pulumi.ComponentResource.parent: self->Component.toPulumiResource}
    let childName = name->ComponentType.name(Plugin.componentType)

    // Create DcbEventLog and StateChangeSlices if DcbSpec provided
    // Also captures handler and connect function for runtime setup
    let (dcbEventLogOutputs, stateChangeSlicesOutputs, dcbRuntimeOpt) = switch dcbSpec {
    | Some(module(DcbSpec)) => {
        module DcbEventLogSpec = {
          @schema
          type event = DcbSpec.event
        }

        module DcbEventLog = DcbEventLog_Builder.Make(
          DcbEventLogSpec,
          DcbEventLogStorage,
          DcbEventTopicPublisher,
        )
        let dcbEventLog = DcbEventLog.make(~name=name, ~opts)

        // Create shared CommandTopic for all StateChangeSlices
        module DcbCommandTopicSpec = {
          module Id = ReventlessSpec.Id.String
          // Accept any command - filtering happens via schema-based registration
          @schema
          type command = JSON.t
        }
        module DcbCommandTopic = CommandTopic_Builder.Make(
          DcbCommandTopicSpec,
          DcbCommandTopicChannel,
        )
        let dcbCommandTopic = DcbCommandTopic.make(
          ~name=`${childName}-dcb-command-topic`,
          ~opts,
        )

        let publishJsons =
          dcbCommandTopic
          ->Component.operations
          ->Pulumi.Output.apply(ops => ops.publishJsons)

        let handlerOutputs =
          DcbSpec.stateChangeSlices
          ->Array.map((
            module(StateChangeSlice: StateChangeSlice.T with type dcbEvent = DcbSpec.event),
          ) => {
            let ch = StateChangeSlice.make(~dcbEventLog, ~publishJsons, ~opts)
            (StateChangeSlice.Spec.name, ch->Component.outputs)
          })
          ->Dict.fromArray

        // Filtering handler for the shared DCB command topic Lambda
        let dcbHandler = DcbCommandTopic.makeFilteringHandler(dcbCommandTopic)
        // Resources the Lambda needs access to (DcbEventLog resources from all slices)
        let dcbResources =
          handlerOutputs->Dict.valuesToArray->Array.flatMap(outputs => outputs.resources)
        let dcbConnectFn = (~runtime) =>
          DcbCommandTopic.connect(~runtime, ~resources=dcbResources, dcbCommandTopic)

        // Capture the forDcbCommandTopic call in a closure while DcbCommandTopic is in scope
        let dcbRuntimeSetup = () =>
          dcbCommandTopic->PluginRuntimeBuilder.forDcbCommandTopic(
            ~handler=dcbHandler,
            ~connect=dcbConnectFn,
          )

        (Some(dcbEventLog->Component.outputs), handlerOutputs, Some(dcbRuntimeSetup))
      }
    | None => (None, Dict.make(), None)
    }

    let aggregatesWithoutEventMappers = aggregates->createAggregatesWithoutEventMappers(opts)
    let allEventTopics = Aggregate.allEventTopics(aggregatesWithoutEventMappers)

    let readModelsOutputs = readModels->createReadModels(allEventTopics, opts)
    let allQueryDbs = readModelsOutputs->ReadModel.allQueryDbs
    let queryEngine = QueryEngineAdapter.make(allQueryDbs)

    let pureOutputs = {
      let coreExtensionPoints =
        Interstack.coreStackReference->Option.mapOr(Pulumi.Output.make(None), coreStack =>
          coreStack->Pulumi.StackReference.getOutput("extensionPoints")
        )

      (
        coreExtensionPoints,
        aggregateResources->Pulumi.Output.allDict,
        publishToAggregates->Pulumi.Output.allDict,
        publishToReadModels->Pulumi.Output.allDict,
        scheduler,
        queryEngine,
      )
      ->Pulumi.Output.all6
      ->Pulumi.Output.apply(((
        coreExtensionPoints,
        aggregateResources,
        publishToAggregates,
        publishToReadModels,
        scheduler,
        queryEngine,
      )) => {
        let aggregatesOutputs = aggregates->addEventMappers(allEventTopics, queryEngine)

        let (extensionPointsOutputs, extensionPointsHandlers) =
          extensionPoints->createExtensionPoints(
            ~aggregateResources,
            ~publishToAggregates,
            ~scheduler,
            ~queryEngine,
            ~resourceNaming=Spec.resourceNaming,
            ~opts,
          )

        let coreExtensionPoints = switch coreExtensionPoints {
        | Some(coreExtensionPoints) => coreExtensionPoints
        | None =>
          JsError.throwWithMessage(
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
          extensions->createExtensions(
            ~publishToCorePluginExtensionPoint,
            ~publishToAggregates,
            ~publishToReadModels,
            ~queryEngine,
            ~opts,
          )

        let extensionPointsDefinitions = extensionPointsOutputs->extractExtensionPointDefinitions
        let extensionsDefinitions = extensionsOutputs->extractExtensionDefinitions

        module Set = Belt.Set.String

        let collectAggregateNames = ex =>
          ex
          ->Set.fromArray
          ->Set.remove(ReventlessSpec.ExtensionMapping.NoAggregate.name)

        let extensionPointAggregateNames =
          extensionPointsOutputs
          ->Array.flatMap(ex => ex.aggregateNames)
          ->collectAggregateNames

        let extensionAggregateNames =
          extensionsOutputs
          ->Array.flatMap(ex => ex.aggregateNames)
          ->collectAggregateNames

        let eventTopics =
          aggregatesOutputs->Aggregate.filterEventTopics(
            extensionPointAggregateNames->Set.union(extensionAggregateNames),
          )
        eventTopics->Dict.set(
          ReventlessSpec.PluginExtensionPointSpec.name,
          {
            resources: corePluginExtensionPointUnwrapped.eventTopic.resources->Array.map(
              AdapterDeploytime.unwrappedToResource,
            ),
          },
        )

        let childName = name->ComponentType.name(Plugin.componentType)

        module EventCollectorHelper = MakeEventCollectorHelper(
          RuntimeEnvironment,
          EventCollectorChannel,
          PluginRuntimeBuilder,
        )
        let (eventCollector, eventCollectorOutputs, eventCollectorUrn) = EventCollectorHelper.make(
          ~name=childName,
          ~eventTopics,
          ~opts,
        )

        let pluginDefinition =
          (extensionPointsDefinitions, eventCollectorUrn)
          ->Pulumi.Output.all2
          ->Pulumi.Output.apply(((extensionPointsDefinitions, eventCollectorUrn)) => {
            ReventlessSpec.Plugin.id,
            name,
            version,
            extensionPoints: extensionPointsDefinitions,
            extensions: extensionsDefinitions,
            eventCollector: eventCollectorUrn,
          })

        let (
          connectPluginExtensionOutputs,
          connectPluginExtensionIncomingEventHandler,
        ) = createConnectPluginExtension(
          ~pluginDefinition,
          ~extensionPointsOutputs,
          ~extensionsOutputs,
          ~publishToCorePluginExtensionPoint,
          ~publishToAggregates,
          ~readModelNamesForSourceName,
          ~publishToReadModels,
          ~queryEngine,
          ~runtimeOps=Spec.runtimeOps,
          ~resourceNaming=Spec.resourceNaming,
          ~opts,
        )
        let _ = EventCollectorHelper.connect(
          ~eventCollector,
          ~eventTopics,
          ~extensionPointsOutputs,
          ~extensionsOutputs,
          ~corePluginExtensionPointUnwrapped,
          ~pluginDefinition,
          ~connectPluginExtensionIncomingEventHandler,
          ~extensionsHandlers,
          ~extensionPointsHandlers,
          ~connectPluginExtensionOutputs,
        )

        let tasksOutputs = createTasks(
          tasks,
          ~aggregatesOutputs,
          ~scheduler,
          ~publishToAggregates,
          ~queryEngine,
          ~resourceNaming=Spec.resourceNaming,
          ~opts,
        )

        let resolvers = allQueryDbs->createResolvers

        module SpecificHeartbeat = Heartbeat_Builder.Make(HeartbeatRunner)
        let heartbeat = SpecificHeartbeat.make(~name=childName, ~opts)
        let handler = SpecificHeartbeat.makeHandler(
          ~id,
          ~timeout=heartbeatInterval,
          ~publishToCorePluginExtensionPoint,
        )
        heartbeat->PluginRuntimeBuilder.forPluginHeartbeat(
          ~handler,
          ~connect=SpecificHeartbeat.connect(
            heartbeat,
            ~remoteChannel=corePluginExtensionPointCommandTopicRemoteChannel,
            ~timeout=heartbeatInterval,
            ...
          ),
        )

        // Connect DCB command topic to its Lambda runtime (if DCB is configured)
        dcbRuntimeOpt->Option.forEach(dcbRuntimeSetup => dcbRuntimeSetup())

        {
          id,
          version,
          heartbeatInterval,
          eventCollector: eventCollectorOutputs,
          extensionPoints: extensionPointsOutputs->Array.map(el => (el.name, el))->Dict.fromArray,
          extensions: extensionsOutputs->Array.map(el => (el.name, el))->Dict.fromArray,
          aggregates: aggregatesOutputs,
          stateChangeSlices: stateChangeSlicesOutputs,
          readModels: readModelsOutputs,
          tasks: tasksOutputs->Array.map(el => (el.name, el))->Dict.fromArray,
          resolvers,
          heartbeat: heartbeat->Component.outputs,
          dcbEventLog: dcbEventLogOutputs,
        }
      })
    }

    self->Component.setOutputs({
      Plugin.id: pureOutputs->Pulumi.Output.apply(outputs => outputs.id),
      version: pureOutputs->Pulumi.Output.apply(outputs => outputs.version),
      heartbeatInterval: pureOutputs->Pulumi.Output.apply(outputs => outputs.heartbeatInterval),
      eventCollector: pureOutputs->Pulumi.Output.apply(outputs => outputs.eventCollector),
      extensionPoints: pureOutputs->Pulumi.Output.apply(outputs => outputs.extensionPoints),
      extensions: pureOutputs->Pulumi.Output.apply(outputs => outputs.extensions),
      aggregates: pureOutputs->Pulumi.Output.apply(outputs => outputs.aggregates),
      stateChangeSlices: pureOutputs->Pulumi.Output.apply(outputs => outputs.stateChangeSlices),
      readModels: pureOutputs->Pulumi.Output.apply(outputs => outputs.readModels),
      tasks: pureOutputs->Pulumi.Output.apply(outputs => outputs.tasks),
      resolvers: pureOutputs->Pulumi.Output.apply(outputs => outputs.resolvers),
      heartbeat: pureOutputs->Pulumi.Output.apply(outputs => outputs.heartbeat),
      dcbEventLog: pureOutputs->Pulumi.Output.apply(outputs => outputs.dcbEventLog),
    })
  }

  let make = (
    ~name,
    ~version,
    ~heartbeatInterval,
    ~extensionPoints=[],
    ~extensions=[],
    ~aggregates=[],
    ~readModels=[],
    ~tasks=[],
    ~scheduler,
    ~dcbSpec=?,
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
        ~tasks,
        ~scheduler,
        ~dcbSpec,
        ...
      ),
      ~opts,
    )
}
