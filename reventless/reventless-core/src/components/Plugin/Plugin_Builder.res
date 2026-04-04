open Plugin_Helpers

module PluginExtensionPointSpec = ReventlessInfra.PluginExtensionPointSpec

// (No type aliases needed — adminExtensionPoints is accessed as a ref field
//  on Spec.hooks, so no optional-parameter parsing issues arise.)

module type Spec = {
  let runtimeOps: PluginRuntimeOperations.operations
  let resourceNaming: ReventlessInfra.ResourceNaming.operations
  let environment: string
  let hooks: Plugin_Helpers.platformHooks
}

module Make = (
  Spec: Spec,
  ApiSpec: {
    type api
    type role
  },
  FragmentProvider: ReventlessInfra.Api_Adapter.Provider,
  RuntimeEnvironment: Runtime.Environment,
  EventCollectorChannel: EventCollector_Adapter.Channel
    with type runtimeParts = RuntimeEnvironment.parts,
  QueryEngineAdapter: QueryDb_Adapter.QueryEngineAdapter,
  PluginExtensionPointRemoteChannel: CommandTopic_Adapter.RemoteChannel,
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
    ~readModels: array<
      module(ReventlessInfra.ReadModel.T with type api = api and type role = role),
    >,
    ~tasks: array<module(ReventlessInfra.Task.T)>,
    ~stateChangeSlices: array<module(ReventlessInfra.StateChangeSlice.T)>,
    ~stateViewSlices: array<module(ReventlessInfra.StateViewSlice.T)>,
    ~automationSlices: array<module(ReventlessInfra.AutomationSlice.T)>,
    ~outboundTranslationSlices: array<module(ReventlessInfra.OutboundTranslationSlice.T)>,
    ~inboundTranslationSlices: array<module(ReventlessInfra.InboundTranslationSlice.T)>,
    self,
    name,
  ) => {
    // Read platform context from hooks refs (populated by makePlatform/deployPlugin).
    let scheduler = switch Spec.hooks.scheduler.contents {
    | Some(s) => s
    | None =>
      JsError.throwWithMessage(
        "Plugin_Builder: scheduler not set — call makePlatform/deployPlugin first",
      )
    }
    let api: api = switch Spec.hooks.api.contents {
    | Some(a) => Obj.magic(a)
    | None =>
      JsError.throwWithMessage(
        "Plugin_Builder: api not set — call makePlatform/deployPlugin first",
      )
    }
    let apiRole: role = switch Spec.hooks.apiRole.contents {
    | Some(r) => Obj.magic(r)
    | None =>
      JsError.throwWithMessage(
        "Plugin_Builder: apiRole not set — call makePlatform/deployPlugin first",
      )
    }

    let id = Plugin.makeId(name, version)
    let opts = {Pulumi.ComponentResource.parent: self->Component.toPulumiResource}
    let childName = name->ComponentType.name(Plugin.componentType)

    // Construct DCB components and derive DCB-specific API schema entries
    module DcbBuilder = Dcb_Builder.Make(
      DcbEventLogStorage,
      DcbEventTopicPublisher,
      DcbCommandTopicChannel,
      PluginRuntimeBuilder,
      Spec,
    )
    let dcbResult = DcbBuilder.construct(
      ~name,
      ~childName,
      ~stateChangeSlices,
      ~stateViewSlices,
      ~automationSlices,
      ~outboundTranslationSlices,
      ~inboundTranslationSlices,
      ~opts,
    )

    // Derive GraphQL schema fragment for this plugin
    let mutationEntriesFromAggregates =
      aggregates->Array.flatMap((module(M: ReventlessInfra.Aggregate.T with type api = api)) => {
        let commandSchema = M.Spec.commandSchema->S.castToUnknown
        let constructorNames = Reventless.DcbTag.extractEventTypes(M.Spec.commandSchema)
        let fieldNames =
          constructorNames->Array.map(cname =>
            Api_Naming.aggregateMutationField(~plugin=name, ~aggregate=M.Spec.name, ~command=cname)
          )
        // Register plugin-prefixed field names for CommandGenerator_Builder.
        Plugin_Helpers.aggregateMutationFieldsRegistry.contents->Dict.set(M.Spec.name, fieldNames)
        // Register aggregate mutation SDL + resolver stubs synchronously via hook
        // (before Output.apply chains fire).
        Spec.hooks.mutationResolverHook->Option.forEach(registerResolver =>
          registerResolver(~kind=Aggregate, ~fields=fieldNames, ~commandSchema)
        )
        [{ReventlessInfra.Api.fieldNames, commandSchema}]
      })

    let mutationEntries = Array.concat(mutationEntriesFromAggregates, dcbResult.mutationEntries)

    let queryEntriesFromReadModels =
      readModels->Array.map((
        module(R: ReventlessInfra.ReadModel.T with type api = api and type role = role),
      ) => {
        let qn = Api_Naming.queryFieldNamesForReadModel(~plugin=name, ~name=R.Spec.name)
        {
          ReventlessInfra.Api.singleFieldName: qn.singleFieldName,
          listFieldName: qn.listFieldName,
          returnTypeName: qn.returnTypeName,
          stateSchema: R.Spec.stateSchema->S.castToUnknown,
          authorization: None,
        }
      })

    let queryEntries = Array.concat(queryEntriesFromReadModels, dcbResult.queryEntries)

    let eventLogEntriesFromAggregates =
      aggregates->Array.map((module(M: ReventlessInfra.Aggregate.T with type api = api)) => {
        ReventlessInfra.Api.busKey: M.Spec.name ++ "Aggr" ++ "EventLog",
        displayName: M.Spec.name,
        eventSchema: M.Spec.eventSchema->S.castToUnknown,
      })

    let eventLogEntries = Array.concat(eventLogEntriesFromAggregates, dcbResult.eventLogEntries)

    // Populate query field names registry so resolvers align with fragment SDL.
    // Keyed by the Spec.name that each component uses for its QueryDb.
    // (StateViewSlice registry is populated earlier, inside the DCB builder,
    // before StateViewSlice.make calls — see above.)
    readModels->Array.forEach((
      module(R: ReventlessInfra.ReadModel.T with type api = api and type role = role),
    ) => {
      let qn = Api_Naming.queryFieldNamesForReadModel(~plugin=name, ~name=R.Spec.name)
      Plugin_Helpers.queryFieldNamesRegistry.contents->Dict.set(R.Spec.name, qn)
    })

    let apiSchemaFragment = FragmentProvider.generateFragment(~mutationEntries, ~queryEntries)

    // Register type definitions via platform hook (e.g. GraphQL in-memory)
    Spec.hooks.schemaTypeRegistrationHook->Option.forEach(registerTypes => {
      let parts = GraphQL_Stitcher.decode(apiSchemaFragment)
      registerTypes(parts.types)
    })

    // Register MCP tools and resources via platform hook (e.g. MCP in-memory)
    Spec.hooks.mcpSchemaRegistrationHook->Option.forEach(registerMcp =>
      registerMcp({
        pluginName: name,
        mutationEntries,
        queryEntries,
        eventLogEntries,
      })
    )

    let aggregatesWithoutEventMappers = aggregates->createAggregatesWithoutEventMappers(~api, opts)
    let allEventTopics = Aggregate.allEventTopics(aggregatesWithoutEventMappers)
    // Merge DCB EventTopic into allEventTopics so ReadModels can subscribe to DCB events.
    // Uses the same key as the eventLogEntries busKey (name ++ "DcbEventLog").
    switch dcbResult.dcbEventLogOutputs {
    | Some(dcbOutputs) => allEventTopics->Dict.set(name ++ "DcbEventLog", dcbOutputs.eventTopic)
    | None => ()
    }

    let readModelsOutputs = readModels->createReadModels(~api, ~apiRole, allEventTopics, opts)
    let allQueryDbs = readModelsOutputs->ReadModel.allQueryDbs
    // Merge DCB StateViewSlice, InboundTranslation, and AutomationSlice QueryDbs into
    // allQueryDbs so createResolvers builds AppSync resolvers for them too.
    dcbResult.stateViewSlicesOutputs
    ->Dict.toArray
    ->Array.forEach(((k, v)) => allQueryDbs->Dict.set(k, v.queryDb))
    dcbResult.inboundTranslationSlicesOutputs
    ->Dict.toArray
    ->Array.forEach(((k, v)) => allQueryDbs->Dict.set(k, v.queryDb))
    let queryEngine = QueryEngineAdapter.make(allQueryDbs)

    {
      // Fire onPluginBuiltHook synchronously with a plain-data summary.
      // ExtensionPoint/Extension names are not accessible from their T module type,
      // so only aggregates, read models, and DCB slice names are included.

      let extractTypes = schema => Reventless.DcbTag.extractEventTypes(schema)
      // Build per-component schema data and register it for the deployed hook.
      let aggregateComponents = aggregates->Array.map((
        module(M: ReventlessInfra.Aggregate.T with type api = api),
      ) => {
        let schema: Plugin_Helpers.pluginDeployedSchema = {
          commandTypes: extractTypes(M.Spec.commandSchema),
          eventTypes: extractTypes(M.Spec.eventSchema),
          errorTypes: extractTypes(M.Spec.errorSchema),
        }
        Plugin_Helpers.componentSchemaRegistry.contents->Dict.set(M.Spec.name, schema)
        ({name: M.Spec.name, kind: "Aggregate", schema}: Plugin_Helpers.pluginBuiltComponent)
      })

      let readModelComponents = readModels->Array.map((
        module(R: ReventlessInfra.ReadModel.T with type api = api and type role = role),
      ) => {
        let qn = Api_Naming.queryFieldNamesForReadModel(~plugin=name, ~name=R.Spec.name)
        let schema: Plugin_Helpers.pluginDeployedSchema = {
          queryFields: [qn.singleFieldName, qn.listFieldName],
        }
        Plugin_Helpers.componentSchemaRegistry.contents->Dict.set(R.Spec.name, schema)
        ({name: R.Spec.name, kind: "ReadModel", schema}: Plugin_Helpers.pluginBuiltComponent)
      })

      let mapNames = (d: dict<_>, kind: string) =>
        d
        ->Dict.keysToArray
        ->Array.map(name => {
          let schema: Plugin_Helpers.pluginDeployedSchema = {}
          ({Plugin_Helpers.name, kind, schema}: Plugin_Helpers.pluginBuiltComponent)
        })

      let components = Array.flat([
        aggregateComponents,
        readModelComponents,
        mapNames(dcbResult.stateChangeSlicesOutputs, "StateChangeSlice"),
        mapNames(dcbResult.stateViewSlicesOutputs, "StateViewSlice"),
        mapNames(dcbResult.automationSlicesOutputs, "AutomationSlice"),
        mapNames(dcbResult.outboundTranslationSlicesOutputs, "OutboundTranslationSlice"),
        mapNames(dcbResult.inboundTranslationSlicesOutputs, "InboundTranslationSlice"),
      ])

      switch Plugin_Helpers.onPluginBuiltHook.contents {
      | Some(hook) => hook({name, version, components})
      | None => ()
      }
    }

    let builderOutputs = {
      // Resolve admin extension point data — from Interstack (AWS cross-stack reference).
      let interstackAdminExtensionPoints =
        Interstack.coreStackReference->Option.mapOr(Pulumi.Output.make(None), coreStack =>
          coreStack->Pulumi.StackReference.getOutput("extensionPoints")
        )

      // Derive local admin extension point resolved data (passed from makePlatform).
      let localAdminResolvedEP =
        Spec.hooks.adminExtensionPoints.contents->Pulumi.Output.flatMap(eps =>
          switch eps->Dict.get(PluginExtensionPointSpec.name) {
          | Some(ep) => ep->ExtensionPoint.toResolvedOutputs->Pulumi.Output.apply(r => Some(r))
          | None => Pulumi.Output.make(None)
          }
        )

      // Push schema fragment to the API before resolvers are created (AWS only).
      // The returned Output chains into the dependency tuple so Pulumi waits
      // for the schema update to complete before creating resolver resources.
      let schemaPushed = switch Spec.hooks.preResolversSchemaHook {
      | Some(pushSchema) => pushSchema(~name, apiSchemaFragment)
      | None => Pulumi.Output.make()
      }

      (
        (interstackAdminExtensionPoints, localAdminResolvedEP, schemaPushed)->Pulumi.Output.all3,
        aggregateResources->Pulumi.Output.allDict,
        publishToAggregates->Pulumi.Output.allDict,
        publishToReadModels->Pulumi.Output.allDict,
        scheduler,
        queryEngine,
      )
      ->Pulumi.Output.all6
      ->Pulumi.Output.apply(((
        (interstackAdminExtensionPoints, localAdminResolvedEP, _),
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

        // Resolve admin connection — from Interstack (AWS), local admin (in-memory), or None
        let coreSetup = switch interstackAdminExtensionPoints {
        | Some(interstackAdminExtensionPoints) => {
            let pluginExtensionPointUnwrapped: ReventlessInterop.ExtensionPoint.resolvedOutputs = (
              interstackAdminExtensionPoints
              ->Pulumi.StackReference.get(PluginExtensionPointSpec.name)
              ->Obj.magic: JSON.t
            )->S.parseOrThrow(ReventlessInterop.ExtensionPoint.resolvedOutputsSchema)
            let pluginExtensionPointCommandTopicRemoteChannel = PluginExtensionPointRemoteChannel.make(
              pluginExtensionPointUnwrapped.commandTopic.resources->Array.map(
                Adapter.fromInteropResolved,
              ),
            )
            Some((pluginExtensionPointUnwrapped, pluginExtensionPointCommandTopicRemoteChannel))
          }
        | None =>
          // Fallback: use local admin extension point data (e.g. in-memory platform)
          switch localAdminResolvedEP {
          | Some(resolvedEP) =>
            let remoteChannel = PluginExtensionPointRemoteChannel.make(
              resolvedEP.commandTopic.resources->Array.map(Adapter.fromInteropResolved),
            )
            Some((resolvedEP, remoteChannel))
          | None => None
          }
        }

        let publishToPluginExtensionPoint: ReventlessInfra.CommandTopic.publishJsons = switch coreSetup {
        | Some((_, remoteChannel)) => remoteChannel.remotePublish
        | None => async _ => ()
        }

        let (extensionsOutputs, extensionsHandlers) =
          extensions->createExtensions(
            ~publishToPluginExtensionPoint,
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
          ->Set.remove(ReventlessInfra.ExtensionMapping.NoDelegate.name)

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
        switch coreSetup {
        | Some((pluginExtensionPointUnwrapped, _)) =>
          eventTopics->Dict.set(
            PluginExtensionPointSpec.name,
            {
              resources: pluginExtensionPointUnwrapped.eventTopic.resources->Array.map(
                AdapterDeploytime.fromInteropResource,
              ),
            },
          )
        | None => ()
        }

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
            apiSchemaFragment: Some(apiSchemaFragment),
          })

        switch coreSetup {
        | Some((pluginExtensionPointUnwrapped, _)) => {
            let (
              connectPluginExtensionOutputs,
              connectPluginExtensionIncomingEventHandler,
            ) = createConnectPluginExtension(
              ~pluginDefinition,
              ~extensionPointsOutputs,
              ~extensionsOutputs,
              ~publishToPluginExtensionPoint,
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
              ~pluginExtensionPointUnwrapped,
              ~pluginDefinition,
              ~connectPluginExtensionIncomingEventHandler,
              ~extensionsHandlers,
              ~extensionPointsHandlers,
              ~connectPluginExtensionOutputs,
            )
          }
        | None =>
          // No admin connection — connect EventCollector without ConnectPluginExtension
          let _ = EventCollectorHelper.connect(
            ~eventCollector,
            ~eventTopics,
            ~extensionPointsOutputs,
            ~extensionsOutputs,
            ~pluginDefinition,
            ~extensionsHandlers,
            ~extensionPointsHandlers,
          )
        }

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
          ~publishToPluginExtensionPoint,
        )
        switch coreSetup {
        | Some((_, pluginExtensionPointCommandTopicRemoteChannel)) =>
          // Notify platform hook that the EP channel is available (AWS extracts SQS URL for bundled heartbeat)
          Spec.hooks.onHeartbeatEpChannelAvailable->Option.forEach(hook =>
            hook(pluginExtensionPointCommandTopicRemoteChannel->Obj.magic)
          )
          heartbeat->PluginRuntimeBuilder.forPluginHeartbeat(
            ~handler,
            ~connect=SpecificHeartbeat.connect(
              heartbeat,
              ~remoteChannel=pluginExtensionPointCommandTopicRemoteChannel,
              ~timeout=heartbeatInterval,
              ...
            ),
          )
        | None =>
          heartbeat->PluginRuntimeBuilder.forPluginHeartbeat(~handler, ~connect=(~runtime as _) =>
            ()
          )
        }

        // Connect DCB command topic to its Lambda runtime (if DCB is configured)
        dcbResult.dcbRuntimeSetup->Option.forEach(dcbRuntimeSetup => dcbRuntimeSetup())

        {
          id,
          version,
          heartbeatInterval,
          eventCollector: eventCollectorOutputs,
          extensionPoints: extensionPointsOutputs->Array.map(el => (el.name, el))->Dict.fromArray,
          extensions: extensionsOutputs->Array.map(el => (el.name, el))->Dict.fromArray,
          aggregates: aggregatesOutputs,
          stateChangeSlices: dcbResult.stateChangeSlicesOutputs,
          stateViewSlices: dcbResult.stateViewSlicesOutputs,
          automationSlices: dcbResult.automationSlicesOutputs,
          outboundTranslationSlices: dcbResult.outboundTranslationSlicesOutputs,
          inboundTranslationSlices: dcbResult.inboundTranslationSlicesOutputs,
          readModels: readModelsOutputs,
          tasks: tasksOutputs->Array.map(el => (el.name, el))->Dict.fromArray,
          resolvers,
          heartbeat: heartbeat->Component.outputs,
          dcbEventLog: dcbResult.dcbEventLogOutputs,
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
      automationSlices: builderOutputs->Pulumi.Output.apply(outputs => outputs.automationSlices),
      outboundTranslationSlices: builderOutputs->Pulumi.Output.apply(outputs =>
        outputs.outboundTranslationSlices
      ),
      inboundTranslationSlices: builderOutputs->Pulumi.Output.apply(outputs =>
        outputs.inboundTranslationSlices
      ),
      readModels: builderOutputs->Pulumi.Output.apply(outputs => outputs.readModels),
      tasks: builderOutputs->Pulumi.Output.apply(outputs => outputs.tasks),
      resolvers: builderOutputs->Pulumi.Output.apply(outputs => outputs.resolvers),
      heartbeat: builderOutputs->Pulumi.Output.apply(outputs => outputs.heartbeat),
      dcbEventLog: builderOutputs->Pulumi.Output.apply(outputs => outputs.dcbEventLog),
      apiSchemaFragment: Pulumi.Output.make(Some(apiSchemaFragment)),
    }
    let _ = self->Component.setOutputs(pluginOutputs)

    // Compute and store the _interopMeta stack export value.  User entry-point
    // code retrieves it via Plugin_Helpers.getInteropMeta() and exports it
    // alongside "tasks", "plugin", and "eventMappers".
    // Assign directly — do NOT wrap in Some().  Pulumi.Output.t is a JS Proxy;
    // wrapping a Proxy in Caml_option.some() triggers the BS_PRIVATE sentinel bug.
    interopMetaOutput :=
      builderOutputs->Pulumi.Output.apply(outputs =>
        outputs
        ->toInteropMeta
        ->S.reverseConvertToJsonOrThrow(ReventlessInterop.ExportMeta.schema)
      )
  }

  let make = (
    ~name,
    ~heartbeatInterval,
    ~extensionPoints=[],
    ~extensions=[],
    ~aggregates: array<module(ReventlessInfra.Aggregate.T with type api = api)>=[],
    ~readModels: array<
      module(ReventlessInfra.ReadModel.T with type api = api and type role = role),
    >=[],
    ~tasks=[],
    ~stateChangeSlices=[],
    ~stateViewSlices=[],
    ~automationSlices=[],
    ~outboundTranslationSlices=[],
    ~inboundTranslationSlices=[],
    ~opts=?,
  ) => {
    let version = Reventless.PackageVersion.fromCaller()
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
        ~stateChangeSlices,
        ~stateViewSlices,
        ~automationSlices,
        ~outboundTranslationSlices,
        ~inboundTranslationSlices,
        ...
      ),
      ~opts,
    )
  }
}
