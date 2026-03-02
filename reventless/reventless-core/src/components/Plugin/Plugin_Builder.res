open Plugin_Helpers

module PluginExtensionPointSpec = ReventlessInfra.PluginExtensionPointSpec

module type Spec = {
  let runtimeOps: PluginRuntimeOperations.operations
  let resourceNaming: ReventlessInfra.ResourceNaming.operations
  let environment: string
}

module Make = (
  Spec: Spec,
  ApiSpec: {
    type api
    type role
  },
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
): (Plugin.T with type api = ApiSpec.api and type role = ApiSpec.role) => {
  type api = ApiSpec.api
  type role = ApiSpec.role

  let construct = (
    ~version: string,
    ~heartbeatInterval: int,
    ~extensionPoints: array<module(ReventlessInfra.ExtensionPoint.T)>,
    ~extensions: array<module(ReventlessInfra.Extension.T)>,
    ~aggregates: array<module(ReventlessInfra.Aggregate.T with type api = api)>,
    ~readModels: array<module(ReventlessInfra.ReadModel.T with type api = api and type role = role)>,
    ~tasks: array<module(ReventlessInfra.Task.T)>,
    ~scheduler: Pulumi.Output.t<Scheduler.operations>,
    ~dcbSpec: option<module(Plugin.DcbSpec)>,
    ~api: api,
    ~apiRole: role,
    self,
    name,
  ) => {
    let id = Plugin.makeId(name, version)
    let opts = {Pulumi.ComponentResource.parent: self->Component.toPulumiResource}
    let childName = name->ComponentType.name(Plugin.componentType)

    // Create DcbEventLog and StateChangeSlices if DcbSpec provided
    // Also captures handler and connect function for runtime setup
    let (
      dcbEventLogOutputs,
      stateChangeSlicesOutputs,
      stateViewSlicesOutputs,
      dcbRuntimeOpt,
    ) = switch dcbSpec {
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
        let dcbEventLog = DcbEventLog.make(~name, ~opts)

        // Create shared CommandTopic for all StateChangeSlices
        module DcbCommandTopicSpec = {
          module Id = Reventless.Id.String
          // Accept any command - filtering happens via schema-based registration
          @schema
          type command = JSON.t
        }
        module DcbCommandTopic = CommandTopic_Builder.Make(
          DcbCommandTopicSpec,
          DcbCommandTopicChannel,
        )
        let dcbCommandTopic = DcbCommandTopic.make(~name=`${childName}-dcb-command-topic`, ~opts)

        let publishJsons =
          dcbCommandTopic
          ->Component.operations
          ->Pulumi.Output.apply(ops => ops.publishJsons)

        let stateChangeSlicesOutputs =
          DcbSpec.stateChangeSlices
          ->Array.map((
            module(StateChangeSlice: StateChangeSlice.T with type dcbEvent = DcbSpec.event),
          ) => {
            let ch = StateChangeSlice.make(~dcbEventLog, ~publishJsons, ~opts)
            (StateChangeSlice.Spec.name, ch->Component.outputs)
          })
          ->Dict.fromArray

        // Create StateViewSlices - each gets its own QueryDb and subscribes to DcbEventLog events
        let stateViewSlicesOutputs =
          DcbSpec.stateViewSlices
          ->Array.map((
            module(StateViewSlice: StateViewSlice.T with type dcbEvent = DcbSpec.event),
          ) => {
            let sv = StateViewSlice.make(~dcbEventLog, ~opts)
            (StateViewSlice.Spec.name, sv->Component.outputs)
          })
          ->Dict.fromArray

        // Filtering handler for the shared DCB command topic Lambda
        let dcbHandler = DcbCommandTopic.makeFilteringHandler(dcbCommandTopic)
        // Resources the Lambda needs access to (DcbEventLog resources from all slices)
        let dcbResources =
          stateChangeSlicesOutputs->Dict.valuesToArray->Array.flatMap(outputs => outputs.resources)
        let dcbConnectFn = (~runtime) =>
          DcbCommandTopic.connect(~runtime, ~resources=dcbResources, dcbCommandTopic)

        // Capture the forDcbCommandTopic call in a closure while DcbCommandTopic is in scope
        let dcbRuntimeSetup = () =>
          dcbCommandTopic->PluginRuntimeBuilder.forDcbCommandTopic(
            ~handler=dcbHandler,
            ~connect=dcbConnectFn,
          )

        (
          Some(dcbEventLog->Component.outputs),
          stateChangeSlicesOutputs,
          stateViewSlicesOutputs,
          Some(dcbRuntimeSetup),
        )
      }
    | None => (None, Dict.make(), Dict.make(), None)
    }

    let aggregatesWithoutEventMappers = aggregates->createAggregatesWithoutEventMappers(~api, opts)
    let allEventTopics = Aggregate.allEventTopics(aggregatesWithoutEventMappers)

    let readModelsOutputs = readModels->createReadModels(~api, ~apiRole, allEventTopics, opts)
    let allQueryDbs = readModelsOutputs->ReadModel.allQueryDbs
    let queryEngine = QueryEngineAdapter.make(allQueryDbs)

    let builderOutputs = {
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
        let aggregatesOutputs = addEventMappers(allEventTopics, queryEngine)

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
        let corePluginExtensionPointUnwrapped: ReventlessInterop.ExtensionPoint.resolvedOutputs =
          (
            coreExtensionPoints->Pulumi.StackReference.get(
              PluginExtensionPointSpec.name,
            )->Obj.magic: JSON.t
          )->S.parseOrThrow(ReventlessInterop.ExtensionPoint.resolvedOutputsSchema)
        let corePluginExtensionPointCommandTopicRemoteChannel = CorePluginExtensionPointRemoteChannel.make(
          corePluginExtensionPointUnwrapped.commandTopic.resources->Array.map(
            Adapter.fromInteropResolved,
          ),
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
          ->Set.remove(ReventlessInfra.ExtensionMapping.NoAggregate.name)

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
          PluginExtensionPointSpec.name,
          {
            resources: corePluginExtensionPointUnwrapped.eventTopic.resources->Array.map(
              AdapterDeploytime.fromInteropResource,
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
            Reventless.Plugin.id,
            name,
            version,
            extensionPoints: extensionPointsDefinitions,
            extensions: extensionsDefinitions,
            eventCollector: eventCollectorUrn,
            extensionProtocols: [],
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
          stateViewSlices: stateViewSlicesOutputs,
          readModels: readModelsOutputs,
          tasks: tasksOutputs->Array.map(el => (el.name, el))->Dict.fromArray,
          resolvers,
          heartbeat: heartbeat->Component.outputs,
          dcbEventLog: dcbEventLogOutputs,
        }
      })
    }

    let pluginOutputs: Plugin.outputs = {
      id: builderOutputs->Pulumi.Output.apply(outputs => outputs.id),
      version: builderOutputs->Pulumi.Output.apply(outputs => outputs.version),
      heartbeatInterval: builderOutputs->Pulumi.Output.apply(outputs => outputs.heartbeatInterval),
      eventCollector: builderOutputs->Pulumi.Output.apply(outputs => outputs.eventCollector),
      extensionPoints: builderOutputs->Pulumi.Output.apply(outputs => outputs.extensionPoints),
      extensions: builderOutputs->Pulumi.Output.apply(outputs => outputs.extensions),
      aggregates: builderOutputs->Pulumi.Output.apply(outputs => outputs.aggregates),
      stateChangeSlices: builderOutputs->Pulumi.Output.apply(outputs => outputs.stateChangeSlices),
      stateViewSlices: builderOutputs->Pulumi.Output.apply(outputs => outputs.stateViewSlices),
      readModels: builderOutputs->Pulumi.Output.apply(outputs => outputs.readModels),
      tasks: builderOutputs->Pulumi.Output.apply(outputs => outputs.tasks),
      resolvers: builderOutputs->Pulumi.Output.apply(outputs => outputs.resolvers),
      heartbeat: builderOutputs->Pulumi.Output.apply(outputs => outputs.heartbeat),
      dcbEventLog: builderOutputs->Pulumi.Output.apply(outputs => outputs.dcbEventLog),
    }
    let _ = self->Component.setOutputs(pluginOutputs)

    // Compute and store the _interopMeta stack export value.  User entry-point
    // code retrieves it via Plugin_Helpers.getInteropMeta() and exports it
    // alongside "tasks", "plugin", and "eventMappers".
    interopMetaOutput := Some(builderOutputs->Pulumi.Output.apply(toInteropMeta))
  }

  let make = (
    ~name,
    ~version,
    ~heartbeatInterval,
    ~extensionPoints=[],
    ~extensions=[],
    ~aggregates: array<module(ReventlessInfra.Aggregate.T with type api = api)>=[],
    ~readModels: array<module(ReventlessInfra.ReadModel.T with type api = api and type role = role)>=[],
    ~tasks=[],
    ~api: api,
    ~apiRole: role,
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
        ~api,
        ~apiRole,
        ...
      ),
      ~opts,
    )
}
