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
  FragmentProvider: ReventlessInfra.Api_Adapter.Provider,
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

    // Naming helpers for GraphQL query/type derivation
    let pluralize = (n: string) => n->String.endsWith("s") ? n : n ++ "s"
    let stripViewSuffix = (n: string) =>
      n->String.endsWith("View") ? n->String.slice(~start=0, ~end=n->String.length - 4) : n
    let singularize = (n: string) =>
      if n->String.endsWith("ies") {
        n->String.slice(~start=0, ~end=n->String.length - 3) ++ "y"
      } else if n->String.endsWith("s") {
        n->String.slice(~start=0, ~end=n->String.length - 1)
      } else { n }

    // Create DcbEventLog and StateChangeSlices if DcbSpec provided
    // Also captures handler and connect function for runtime setup
    let (
      dcbEventLogOutputs,
      stateChangeSlicesOutputs,
      stateViewSlicesOutputs,
      automationSlicesOutputs,
      outboundTranslationSlicesOutputs,
      inboundTranslationSlicesOutputs,
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

        // Register DCB mutation resolvers via platform hook (e.g. GraphQL in-memory)
        switch dcbMutationResolverHook.contents {
        | Some(registerResolver) =>
          DcbSpec.stateChangeSlices->Array.forEach((
            module(S: StateChangeSlice.T with type dcbEvent = DcbSpec.event),
          ) => {
            registerResolver(
              ~fieldName=`${name}_${S.Spec.name}`,
              ~commandSchema=S.Spec.commandSchema->Reventless.DcbTag.toUnknownSchema,
            )
          })
        | None => ()
        }

        // Populate query field names registry for StateViewSlices BEFORE creating them,
        // so QueryDbResolvers can read the registry during component construction.
        DcbSpec.stateViewSlices->Array.forEach((
          module(V: StateViewSlice.T with type dcbEvent = DcbSpec.event),
        ) => {
          let entity = V.Spec.name->stripViewSuffix
          let singular = singularize(entity)
          Plugin_Helpers.queryFieldNamesRegistry.contents->Dict.set(
            V.Spec.name,
            {
              Plugin_Helpers.singleFieldName: `${name}_${singular}`,
              listFieldName: Some(`${name}_${pluralize(entity)}`),
              returnTypeName: `${name}_${singular}`,
              pluralTypeName: Some(`${name}_${pluralize(entity)}`),
            },
          )
        })

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

        // Create AutomationSlices — each gets its own QueryDb and subscribes to DcbEventLog events
        let automationSlicesOutputs =
          DcbSpec.automationSlices
          ->Array.map((
            module(AutoSlice: AutomationSlice.T with type dcbEvent = DcbSpec.event),
          ) => {
            let as_ = AutoSlice.make(~dcbEventLog, ~publishJsons, ~opts)
            (AutoSlice.Spec.name, as_->Component.outputs)
          })
          ->Dict.fromArray

        // Create OutboundTranslationSlices — each subscribes to events and translates to external calls
        let outboundTranslationSlicesOutputs =
          DcbSpec.outboundTranslationSlices
          ->Array.map((
            module(OTS: OutboundTranslationSlice.T with type dcbEvent = DcbSpec.event),
          ) => {
            let ots = OTS.make(~dcbEventLog, ~publishJsons, ~opts)
            (OTS.Spec.name, ots->Component.outputs)
          })
          ->Dict.fromArray

        // Create InboundTranslationSlices — each receives external input and publishes commands.
        // Capture both outputs (for plugin result) and components (for operations access).
        let inboundTranslationSliceData =
          DcbSpec.inboundTranslationSlices
          ->Array.map((
            module(ITS: InboundTranslationSlice.T with type dcbEvent = DcbSpec.event),
          ) => {
            let its = ITS.make(~publishJsons, ~opts)
            let fieldName = `${name}_${ITS.Spec.name}`

            // Phase 1: Register SDL + resolver stub synchronously (before server starts).
            switch inboundMutationResolverHook.contents {
            | Some(registerResolver) =>
              registerResolver(
                ~fieldName,
                ~externalInputSchema=ITS.Spec.externalInputSchema->S.castToUnknown,
              )
            | None => ()
            }

            // Phase 2: Bind `receive` when Output.apply resolves.
            switch inboundMutationBindReceiveHook.contents {
            | Some(bindReceive) =>
              let _ =
                its
                ->Component.operations
                ->Pulumi.Output.apply(ops => bindReceive(~fieldName, ~receive=ops.receive))
            | None => ()
            }

            (
              ITS.Spec.name,
              fieldName,
              its,
              ITS.Spec.externalInputSchema->S.castToUnknown,
            )
          })

        let inboundTranslationSlicesOutputs =
          inboundTranslationSliceData
          ->Array.map(((specName, _, its, _)) => (specName, its->Component.outputs))
          ->Dict.fromArray

        // Collect InboundTranslationSlice receive functions from Component.operations.
        // These are Output.t values — we resolve them and build a dict for the composite
        // DCB handler to route direct invocations (AppSync on AWS).
        let inboundReceiversOutput =
          inboundTranslationSliceData
          ->Array.map(((_, fieldName, its, _)) =>
            its
            ->Component.operations
            ->Pulumi.Output.apply(ops => (fieldName, ops.receive))
          )
          ->Pulumi.Output.all
          ->Pulumi.Output.apply(pairs => pairs->Dict.fromArray)

        // Filtering handler for the shared DCB command topic Lambda.
        // Wrap with InboundTranslation routing so the same Lambda handles both
        // SQS commands (StateChangeSlice) and direct invocations (InboundTranslation).
        let dcbHandlerBase = DcbCommandTopic.makeFilteringHandler(dcbCommandTopic)

        let dcbHandler =
          (dcbHandlerBase, inboundReceiversOutput)
          ->Pulumi.Output.all2
          ->Pulumi.Output.apply(((baseHandler, receivers)) => {
            let composite = (event, ctx) => {
              // At runtime: check if this is a direct AppSync invocation
              // for an InboundTranslationSlice mutation.
              let raw: dict<JSON.t> = event->Obj.magic
              switch raw->Dict.get("__inboundTranslation") {
              | Some(_) =>
                let fieldName =
                  raw
                  ->Dict.get("fieldName")
                  ->Option.flatMap(JSON.Decode.string)
                  ->Option.getOr("")
                let args = raw->Dict.get("arguments")->Option.getOr(JSON.Encode.null)
                switch receivers->Dict.get(fieldName) {
                | Some(receiveFn) =>
                  Effect.promise(async () => {
                    let result = await receiveFn(args)
                    let response = switch result {
                    | Ok(id) => id
                    | Error(msg) => msg
                    }
                    response->Obj.magic
                  })
                | None => baseHandler(event, ctx)
                }
              | None => baseHandler(event, ctx)
              }
            }
            composite->Obj.magic
          })

        // Resources the Lambda needs access to (DcbEventLog + InboundTranslation audit logs)
        let dcbResources = Array.concat(
          stateChangeSlicesOutputs->Dict.valuesToArray->Array.flatMap(outputs => outputs.resources),
          inboundTranslationSlicesOutputs
          ->Dict.valuesToArray
          ->Array.flatMap(outputs => outputs.resources),
        )

        // Collect InboundTranslation field names and schemas for AppSync resolver hook
        let inboundFieldNames =
          inboundTranslationSliceData->Array.map(((_, fieldName, _, _)) => fieldName)
        let inboundSchemas =
          inboundTranslationSliceData->Array.map(((_, _, _, schema)) => schema)

        let dcbConnectFn = (~runtime) => {
          DcbCommandTopic.connect(~runtime, ~resources=dcbResources, dcbCommandTopic)

          // Create AppSync resolvers for InboundTranslationSlice mutations
          // pointing to the shared DCB CommandTopic Lambda (Option A).
          if inboundFieldNames->Array.length > 0 {
            switch inboundAppSyncResolverHook.contents {
            | Some(hook) =>
              hook({
                runtime: runtime->Obj.magic,
                fieldNames: inboundFieldNames,
                externalInputSchemas: inboundSchemas,
                opts,
              })
            | None => ()
            }
          }
        }

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
          automationSlicesOutputs,
          outboundTranslationSlicesOutputs,
          inboundTranslationSlicesOutputs,
          Some(dcbRuntimeSetup),
        )
      }
    | None => (None, Dict.make(), Dict.make(), Dict.make(), Dict.make(), Dict.make(), None)
    }

    // Derive GraphQL schema fragment for this plugin
    let mutationEntriesFromAggregates =
      aggregates->Array.flatMap((module(M: ReventlessInfra.Aggregate.T with type api = api)) => {
        let commandSchema = M.Spec.commandSchema->S.castToUnknown
        let constructorNames = Reventless.DcbTag.extractEventTypes(M.Spec.commandSchema)
        let fieldNames = constructorNames->Array.map(cname => `${name}_${M.Spec.name}_${cname}`)
        // Register plugin-prefixed field names so CommandGenerator_Builder can use them
        // instead of the empty Behavior.resolverConfig.fields.
        Plugin_Helpers.aggregateMutationFieldsRegistry.contents->Dict.set(M.Spec.name, fieldNames)
        // Register aggregate mutation SDL + resolver stubs synchronously via hook
        // (before Output.apply chains fire).
        switch Plugin_Helpers.aggregateMutationResolverHook.contents {
        | Some(registerResolver) => registerResolver(~fields=fieldNames, ~commandSchema)
        | None => ()
        }
        [{ReventlessInfra.Api.fieldNames, commandSchema}]
      })

    let mutationEntriesFromSlices = switch dcbSpec {
    | Some(module(DcbSpec)) =>
      DcbSpec.stateChangeSlices->Array.map((module(S: StateChangeSlice.T with type dcbEvent = DcbSpec.event)) =>
        {ReventlessInfra.Api.fieldNames: [`${name}_${S.Spec.name}`], commandSchema: S.Spec.commandSchema->Reventless.DcbTag.toUnknownSchema}
      )
    | None => []
    }

    let mutationEntriesFromInboundSlices = switch dcbSpec {
    | Some(module(DcbSpec)) =>
      DcbSpec.inboundTranslationSlices->Array.map((
        module(ITS: InboundTranslationSlice.T with type dcbEvent = DcbSpec.event),
      ) =>
        {
          ReventlessInfra.Api.fieldNames: [`${name}_${ITS.Spec.name}`],
          commandSchema: ITS.Spec.externalInputSchema->S.castToUnknown,
        }
      )
    | None => []
    }

    let mutationEntries =
      Array.concat(mutationEntriesFromAggregates, mutationEntriesFromSlices)->Array.concat(
        mutationEntriesFromInboundSlices,
      )

    let queryEntriesFromReadModels =
      readModels->Array.map((module(R: ReventlessInfra.ReadModel.T with type api = api and type role = role)) =>
        {
          ReventlessInfra.Api.singleFieldName: `${name}_${singularize(R.Spec.name)}`,
          listFieldName: Some(`${name}_${pluralize(R.Spec.name)}`),
          returnTypeName: `${name}_${singularize(R.Spec.name)}`,
          stateSchema: R.Spec.stateSchema->S.castToUnknown,
          authorization: None,
        }
      )

    let queryEntriesFromSlices = switch dcbSpec {
    | Some(module(DcbSpec)) =>
      DcbSpec.stateViewSlices->Array.map((module(V: StateViewSlice.T with type dcbEvent = DcbSpec.event)) => {
        let entity = V.Spec.name->stripViewSuffix
        let singular = singularize(entity)
        {
          ReventlessInfra.Api.singleFieldName: `${name}_${singular}`,
          listFieldName: Some(`${name}_${pluralize(entity)}`),
          returnTypeName: `${name}_${singular}`,
          stateSchema: V.Spec.stateSchema->Reventless.DcbTag.toUnknownSchema,
          authorization: None,
        }
      })
    | None => []
    }

    let queryEntries = Array.concat(queryEntriesFromReadModels, queryEntriesFromSlices)

    let eventLogEntriesFromAggregates =
      aggregates->Array.map((module(M: ReventlessInfra.Aggregate.T with type api = api)) => {
        ReventlessInfra.Api.busKey: M.Spec.name ++ "Aggr" ++ "EventLog",
        displayName: M.Spec.name,
        eventSchema: M.Spec.eventSchema->S.castToUnknown,
      })

    let eventLogEntriesFromDcb = switch dcbSpec {
    | Some(module(DcbSpec)) => [
        {
          ReventlessInfra.Api.busKey: name ++ "DcbEventLog",
          displayName: name,
          eventSchema: DcbSpec.eventSchema->S.castToUnknown,
        },
      ]
    | None => []
    }

    let eventLogEntries = Array.concat(eventLogEntriesFromAggregates, eventLogEntriesFromDcb)

    // Populate query field names registry so resolvers align with fragment SDL.
    // Keyed by the Spec.name that each component uses for its QueryDb.
    // (StateViewSlice registry is populated earlier, inside the dcbSpec match block,
    // before StateViewSlice.make calls — see above.)
    readModels->Array.forEach((module(R: ReventlessInfra.ReadModel.T with type api = api and type role = role)) =>
      Plugin_Helpers.queryFieldNamesRegistry.contents->Dict.set(
        R.Spec.name,
        {
          Plugin_Helpers.singleFieldName: `${name}_${singularize(R.Spec.name)}`,
          listFieldName: Some(`${name}_${pluralize(R.Spec.name)}`),
          returnTypeName: `${name}_${singularize(R.Spec.name)}`,
          pluralTypeName: Some(`${name}_${pluralize(R.Spec.name)}`),
        },
      )
    )

    let apiSchemaFragment = FragmentProvider.generateFragment(~mutationEntries, ~queryEntries)

    // Register type definitions via platform hook (e.g. GraphQL in-memory)
    switch schemaTypeRegistrationHook.contents {
    | Some(registerTypes) =>
      let parts = GraphQL_Stitcher.decode(apiSchemaFragment)
      registerTypes(parts.types)
    | None => ()
    }

    // Register MCP tools and resources via platform hook (e.g. MCP in-memory)
    switch mcpSchemaRegistrationHook.contents {
    | Some(registerMcp) =>
      registerMcp({
        pluginName: name,
        mutationEntries,
        queryEntries,
        eventLogEntries,
      })
    | None => ()
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

        // Resolve Core stack reference (None when running without a Core stack, e.g. in-memory)
        let coreSetup = switch coreExtensionPoints {
        | Some(coreExtensionPoints) => {
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
            Some((corePluginExtensionPointUnwrapped, corePluginExtensionPointCommandTopicRemoteChannel))
          }
        | None => None
        }

        let publishToCorePluginExtensionPoint: ReventlessInfra.CommandTopic.publishJsons = switch coreSetup {
        | Some((_, remoteChannel)) => remoteChannel.remotePublish
        | None => async _ => ()
        }

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
        switch coreSetup {
        | Some((corePluginExtensionPointUnwrapped, _)) =>
          eventTopics->Dict.set(
            PluginExtensionPointSpec.name,
            {
              resources: corePluginExtensionPointUnwrapped.eventTopic.resources->Array.map(
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
        | Some((corePluginExtensionPointUnwrapped, _)) => {
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
          }
        | None =>
          let _ = EventCollectorHelper.connectWithoutCore(
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
          ~publishToCorePluginExtensionPoint,
        )
        switch coreSetup {
        | Some((_, corePluginExtensionPointCommandTopicRemoteChannel)) =>
          heartbeat->PluginRuntimeBuilder.forPluginHeartbeat(
            ~handler,
            ~connect=SpecificHeartbeat.connect(
              heartbeat,
              ~remoteChannel=corePluginExtensionPointCommandTopicRemoteChannel,
              ~timeout=heartbeatInterval,
              ...
            ),
          )
        | None =>
          heartbeat->PluginRuntimeBuilder.forPluginHeartbeat(
            ~handler,
            ~connect=(~runtime as _) => (),
          )
        }

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
          automationSlices: automationSlicesOutputs,
          outboundTranslationSlices: outboundTranslationSlicesOutputs,
          inboundTranslationSlices: inboundTranslationSlicesOutputs,
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
      automationSlices: builderOutputs->Pulumi.Output.apply(outputs => outputs.automationSlices),
      outboundTranslationSlices: builderOutputs->Pulumi.Output.apply(outputs => outputs.outboundTranslationSlices),
      inboundTranslationSlices: builderOutputs->Pulumi.Output.apply(outputs => outputs.inboundTranslationSlices),
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
